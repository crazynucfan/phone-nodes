<!-- SPDX-License-Identifier: GPL-2.0-only -->
# negroni: OnePlus 10 Pro (NE2213, SM8450)

The series in `kernel/negroni/` applies to v7.3-rc5. It builds
`qcom/sm8450-oneplus-negroni.dtb` with `negroni_defconfig`, and kernels are
released as `<version>-negroni-<build>`. Patch 1 is the device support,
reduced from the withsalt/linux fork (see CREDITS.md). The others:

| Patch | What |
|---|---|
| 0002 | TEMPORARY: reverts the verifier's `bpf_set_retval` argument check, which makes Cilium's helper probe exit |
| 0003 | `negroni_defconfig`: watchdog driver built in, hung task detector on |
| 0004 | `qcom_battmgr`: translate the firmware's USB adapter types |
| 0005 | `negroni_defconfig`: soft and hard lockup panic, panic on oops, 10 s reboot, `test_lockup` |
| 0006 | `negroni_defconfig`: kernel BTF |

An earlier version of the series also described the APSS watchdog in the
device tree. That patch was dropped. Carried into a kexec'd kernel's tree, the
node sent that kernel to EDL
([kexec-on-qualcomm.md](kexec-on-qualcomm.md#watchdogs)), and a boot image
built from a DTB with the node would hit the same.

## Firmware and bootloader

- **Stay on OxygenOS 14 firmware.** This setup has run on 14.0.0.940 (slot b)
  and 14.0.0.202 (slot a). Do not install OxygenOS 15.0.0.1302 or later: it is
  known to break this setup, so treat it as a one-way door.
- The bootloader refuses `fastboot boot` (RAM boot). Every test kernel has to
  be flashed, which is why the kexec loader exists.
- No firmware is included here. The DSP and Wi-Fi firmware is loaded from the
  phone's own partitions at boot, by the scripts in
  `third-party/msm-firmware-loader/`.

## Keep the boot slot marked successful

Android marks the booted A/B slot successful on every boot; Linux does not.
After a flash, every boot of the unsuccessful slot uses one of its retries (7
after `fastboot --set-active`). At 0 the bootloader marks the slot unbootable
and falls back to the other slot, which holds stock OxygenOS. From the outside
it looks like a brick: an orange-state reset loop with no Linux output and dead
fastboot keys. Recovering from that state needs low-level access, so prevent
it. `loader/qcom-slot-successful` sets the "successful" bit (and clears
"unbootable") in the boot partition's GPT attributes, in both the primary and
the backup table. `loader/systemd/mark-slot-successful.service` runs it for
slot b, where Linux lives, on every boot. After any flash, check `fastboot
getvar all`: `slot-successful:b` should be `yes`.

## Things not to do

- **No warm reboot mode.** `echo warm > /sys/kernel/reboot/mode` followed by a
  reboot left the phone black until a forced power-on (Power + Volume Up).
  Cold reboots are fine.
- **No CPU hotplug.** Taking CPUs offline and back online stalled all storage
  I/O seconds later (jbd2, writeback and UFS devfreq all blocked).
- **No APSS watchdog.** The bootloader's tree does not describe it, and the
  series no longer does either (see above). A hung kernel recovers by
  panicking instead: the lockup detectors, `panic_on_rcu_stall` and
  `hung_task_panic`, all with a 10 s reboot.

## Kernel BTF and the bpf revert (patches 0006 and 0002)

The nodes run Cilium. Patch 0006 builds the kernel with BTF
(`CONFIG_DEBUG_INFO_BTF=y`, which takes full DWARF instead of reduced debug
info), for the kernel and its modules (`/sys/kernel/btf/vmlinux`). Without
kernel BTF the verifier rejects Cilium's BPF masquerade program
(`tail_handle_snat_fwd_ipv4`). Cilium 1.19.8, and 1.20.2 onwards, need BTF for
their socket-LB programs as well.

Patch 0002 is temporary. Recent kernels fail a non-scalar `bpf_set_retval()`
argument with -EINVAL. Cilium's helper probe reads that as "no such helper",
and the agent of the Cilium release in use exits at startup. The patch reverts
the check. It stays only until the cluster can run a Cilium release with the
probe fix, and those releases need kernel BTF on every node of the cluster.
rhodep's series carries a narrower change for the same problem
([rhodep.md](rhodep.md)).

## Battery manager USB types (patch 0004)

7.x inserted two USB types into the power-supply core's enum
(`PD_SPR_AVS` = 9, `PD_PPS_SPR_AVS` = 10) and moved `APPLE_BRICK_ID` to 11.
`qcom_battmgr` passed the ADSP firmware's raw value through, and the firmware
still uses the old numbering. With a PD Ethernet adapter attached, the firmware
reports 9. The core rejected it on every read with "driver reporting
unavailable enum value 9", about 200 lines a second. That drowned journald,
and SSH, sudo and anything else that logs stalled until the phone was
power-cycled. Patch 0004 translates the firmware's types to the core's
numbering.

## USB Ethernet while charging

A PD Ethernet adapter with a charger behind it gives one cable for power and
network. If the adapter is already powered when the phone boots, or is plugged
in with the charger attached, the ADSP never re-detects the cable and the
SuperSpeed link never trains. `devices/negroni/negroni-usb-recover` (with its
unit) recovers that unattended:

1. unbind and rebind the dwc3 controller (a fresh PHY init; a role bounce alone
   is not enough);
2. force the USB role switch to host;
3. set the Type-C mode to "disabled", wait 2 s, then set it to DRP.

It retries until the Ethernet interface appears. The order matters: a Type-C
reset before the controller re-init fails. It needs the `usb_prop` debugfs knob
that patch 1 adds to `qcom_battmgr`.

## Charge limit

A phone on a charger around the clock should not sit at 100%.
`devices/negroni/negroni-charge-limit` stops charging at `END_THRESHOLD` and
resumes at `START_THRESHOLD` (80/75 by default, in
`/etc/negroni-charge-limit.conf`). It restores normal charging when it exits.

## CPU frequency metrics from node_exporter

node_exporter's cpufreq collector reads `stats/trans_table` for every CPU, and
one failed read fails the collector for all of them. The prime core's cpufreq
policy has 20 frequencies. Its table is larger than a page, and the kernel
answers the read with EFBIG. The other two policies have 15 and 18 frequencies
and fit. The result is no CPU frequency metrics at all.

The collector tolerates "permission denied" on that file, and the exporter
does not run as root. So
`devices/negroni/tmpfiles/negroni-cpufreq-trans-table.conf` (for
`/etc/tmpfiles.d/`) makes the table readable by root only:

```
z /sys/devices/system/cpu/cpufreq/policy*/stats/trans_table 0400 root root - -
```

sysfs modes do not survive a reboot, so tmpfiles sets them at every boot. A
fix is pending upstream in
[prometheus/procfs PR 852](https://github.com/prometheus/procfs/pull/852).

## UFS clock scaling off

`devices/negroni/tmpfiles/phone-ufs-clkscale.conf` turns UFS clock scaling off
at every boot:

```
w /sys/bus/platform/devices/1d84000.ufshc/clkscale_enable - - - - 0
```

The reason is a deadlock in ufshcd, seen on rhodep ([rhodep.md](rhodep.md)).
`ufshcd_clock_scaling_prepare()` quiesces the tag set and then takes
`clk_scaling_lock` for write. Meanwhile the query from `ufshcd_rtc_work` holds
the read lock and waits on the quiesced queue. Neither can go on, and all
storage I/O stops. negroni runs the same code, so clock scaling is off here
too.
