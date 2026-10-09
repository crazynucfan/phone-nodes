<!-- SPDX-License-Identifier: GPL-2.0-only -->
# apollo: Xiaomi Mi 10T Pro (M2007J3SG, SM8250)

The series in `kernel/apollo/` applies to v7.2.9. It builds
`qcom/sm8250-xiaomi-apollo.dtb` with `apollo_defconfig`, and kernels are
released as `<version>-apollo-<build>`. See CREDITS.md for where the patches
come from.

**State:** runs as a node (since 2026-10-04). The boot partition holds a loader
kernel, and the loader kexecs packaged kernels from `/boot` and blesses them,
as on negroni and rhodep.

## What the series covers

| Patch | What |
|---|---|
| 0001 | the device support, reduced from royka1's postmarketOS port to what a headless node needs |
| 0002 | `apollo_defconfig`: the Realtek RTL8152 USB Ethernet driver |
| 0003 | bpf: a non-scalar `bpf_set_retval()` argument fails with -EACCES instead of -EINVAL (rhodep's 0012) |
| 0004 | `apollo_defconfig`: soft and hard lockup panic, panic on oops, 10 s reboot, `test_lockup` |
| 0005 | `apollo_defconfig`: nftables `fib` for the inet family |
| 0006 | `qcom_pm8150b` charger: follow the USB-C (TCPM) input current limit |

- **0001.** The modem is left out: it is an external SDX55 on PCIe, and the
  port's PCIe changes that only served it were dropped. The panel driver uses
  `devm_drm_panel_alloc()` (7.2 removed `drm_panel_init()`), and the USB-C
  connector has `vbus-supply` (7.2 moved it off the Type-C node; without it
  the regulator is a dummy and host mode breaks).
- **0002.** Without `r8152`, an RTL8153 adapter binds to `r8153_ecm`, its CDC
  ECM configuration, which cannot take another MAC (see below).
- **0003.** As in rhodep.md: Cilium 1.20.1's agent exits on its helper probe
  without it.
- **0004.** As on negroni and rhodep: a kernel that hangs only comes back if it
  panics or the watchdog bites.
- **0005.** Podman's netavark builds container networks from inet-family
  nftables rules with `fib` expressions. Without `NFT_FIB_INET` the kernel
  rejects them ("Could not process rule: No such file or directory") and no
  container with a network starts. negroni and rhodep build it already.

The CPUs: cpu0-3 are Cortex-A55 (1.80 GHz, capacity 284), cpu4-6 Cortex-A77
(2.42 GHz, 871), cpu7 the prime Cortex-A77 (2.84 GHz, 1024), with an energy
model for all three policies. Their temperatures are thermal zones named
`cpu0-thermal` to `cpu3-thermal`, and `cpu4-top-thermal`/`cpu4-bottom-thermal`
to `cpu7-…` for the big cores.

- **0006.** The charger drew 500 mA whatever the adapter offered. See
  [USB-C input current](#usb-c-input-current).

`kernel/apollo/tests/check-pd-policy.py` tests 0006's policy off the phone
(below).

## Boot and the loader kernel

- **Boot image:** not A/B. A header v2 boot image with the DTB appended, and
  the root filesystem on userdata. The dtbo partition has to be erased once.
- **The loader kernel** in the boot partition is a build of royka1's own branch
  with postmarketOS's configuration (its DSP and touch firmware built in) and
  `reboot=warm` on the command line. It is changed rarely, by hand; packaged
  kernels never write the boot partition.
- **Reboots must be warm (`reboot=warm`).** The secure firmware turns a PSCI
  reset into a power-off. The device tree reboots through PS_HOLD (a
  `qcom,pshold` restart node) instead. Without that, a reboot with the charger
  attached leaves the phone off. This is the opposite of negroni, where warm
  reboots are fatal: check per device.
- **No usable EDL.** Xiaomi's needs an authorised account. Fastboot (Volume
  Down + Power) always works, since nothing here touches the bootloader, but
  the partitions only the phone has (`persist`, `modemst1`, `modemst2`, `fsg`,
  `fsc`) should be backed up right after the first boot.

## Loader settings

apollo's `/etc/default/phone-kexec` sets `FLAVOUR="apollo"`. Its
`/etc/default/phone-boot` (see [kexec-loader.md](kexec-loader.md#settings));
the files are in `devices/apollo/examples/`:

```
PHONE_BOOT_LOADER_MARK=androidboot.keymaster=1
PHONE_KEXEC_ARGS="watchdog.open_timeout=180"
PHONE_KEXEC_REBOOT_MODE=warm
PHONE_KEXEC_DTB_BASE=package
PHONE_KEXEC_DISPLAY_OFF=1
```

- **The marker.** Xiaomi's bootloader adds `androidboot.keymaster=1`; it means
  nothing to a mainline kernel, so it marks a bootloader boot.
- **Warm reset**, for the reason above.
- **The package's device tree.** The bootloader passes the loader kernel's
  7.1 tree. `phone-kexec-test fdt-diff` showed the 7.2 kernels' own tree
  differing in more than the bootloader's fixups: the PCIe `iommu-map` cells,
  the USB-C VBUS supply, the video decoder's power domains. So the kexec'd
  kernel gets the package DTB, with the running tree's memory node copied in
  (the only fixup it needs; kexec writes `/chosen`). SM8250 has no GIC ITS,
  so there are no LPI tables to reserve.
- **The display off.** The loader kernel drives the panel (msm display built
  in, the console on it). Every jump with the panel on reset the phone, with
  nothing in pstore; every jump with it off (console blanking, or blanking the
  framebuffer) worked. `phone-kexec-test go` blanks the framebuffers first.
- **No DSP.** `devices/apollo/apollo-no-dsp.conf` keeps `qcom_q6v5_pas` from
  loading, on the loader kernel and the series' kernels alike. A node needs
  none of the DSPs (charging, the fuel gauge and USB-C are kernel drivers),
  the series' kernels have no DSP firmware, and on the loader kernel the
  sensor DSP crash-looped.
- **The watchdog does not reset this phone.** `qcom_wdt` starts at a 30 s
  timeout, and systemd arms it (`devices/apollo/21-phone-watchdog-cap.conf`
  caps the reboot and kexec timeouts at 30 s, as on rhodep). But in a drill
  with every CPU locked by `test_lockup` (`all_cpus=1 disable_irq=1`, lockup
  panics off), nothing petted it for about 15 minutes and nothing reset the
  SoC. What brings a hung apollo back is the series' lockup detectors: they
  panic, and the panic reboots warm into the loader. The watchdog settings
  are harmless, not a safety net.

A kexec by hand from one of the series' kernels straight into another left the
USB adapter unenumerated and Wi-Fi unreachable. The loader never does that: it
always starts from the loader kernel after a reset. Test kernels the same way:
reboot first.

## USB Ethernet and USB-C

- **Type-C** is the in-kernel TCPM on the PM8150B: PD sink, and the adapter
  asks for a data role swap, which makes the phone the USB host. On a cold boot
  the adapter asks for none, the port stays a peripheral and the adapter never
  appears. `devices/apollo/phone-usb-role.service` writes `host` to
  `/sys/class/usb_role/*/role` at boot, as on rhodep; that is enough, no
  re-plug needed.
- **The port is high speed only**: about 480 Mb/s through a gigabit adapter.
- **`r8153_ecm` cannot take another MAC.** The loader kernel has no `r8152`,
  so an RTL8153 adapter runs in its ECM configuration. Its chip keeps
  filtering on its own MAC: with a MAC set from Linux (a systemd `.link`
  `MACAddress=`), DHCP and ARP replies to broadcasts still work, everything
  else is dropped, promiscuous mode or not, which looks like a routing problem.
  Keep the adapter's own MAC when it is unique (not Realtek's shared default),
  or run a kernel with `r8152` (0002) everywhere the node must be reachable.
- **Do not unbind and rebind `dwc3`.** TCPM keeps a stale handle to the old
  role switch; every attach then fails at "set USB role" and drops back to
  unattached, power delivery never completes, and charging falls to about
  0.1 A until a reboot.

## Wi-Fi

The QCA6390 (ath11k on PCIe) gets its firmware from linux-firmware. Its MAC is
a placeholder (`00:03:7f:12:xx:xx`) that changes at every boot, so each boot
gets a new lease unless a stable, locally administered MAC is set
(`MACAddress=` in a `.link` or the `.network` file).

## USB-C input current

Through the Ethernet adapter the phone negotiated 9 V / 2.21 A, but the
charger's effective input current limit and its AICL result both stayed at
500 mA. The driver wrote its limit to the current configuration register and
left the APSD current override off, and it kept retrying legacy (BC1.2)
detection, which never gets a result during PD.

Patch 0006 links the charger to the PM8150B's TCPM power supply
(`power-supplies = <&pm8150b_typec>` in `pm8150b.dtsi`) and follows it:

- It uses TCPM's `CURRENT_NOW`, the draw that is permitted right now (standby
  during a transition included), not an advertised maximum. It rounds down to
  the 50 mA step and selects software high-current control after programming
  the limit.
- It stops BC1.2/HVDCP detection while Type-C or PD decides the limit, and
  suspends the input on detach or when the port turns source.
- Writes to the sysfs current limit are bounded by the live allowance. Unknown
  USB sources stay at 500 mA, and BC1.2-only CDP/DCP sources at 1.5 A.
- AICL, collapse protection and the battery temperature and charge controls
  are kept. The 75–80% charge limit below still works through
  `charging_enabled`, independently.

The register sequence follows Qualcomm's downstream `smb5-lib.c` (CREDITS.md).

The patch changes the DTB, and `kernel/apollo/dtb.sha256` has the new hash. A
kexec'd kernel gets the package's DTB on this phone (`PHONE_KEXEC_DTB_BASE`
above), so the change takes effect without touching the boot partition.

**Trial (2026-10-09), a local build `7.2.9-apollo-pd-local1`:** kexec'd by the
loader's helper, with Ethernet and k3s healthy. After a power cycle of the
charger, the phone negotiated 9 V / 2.21 A, the effective input limit became
2.20 A and the battery charged at about 2.93 A. See
[Not proven yet](#not-proven-yet) for what the trial did not show.

The policy can be tested off the phone, against a Linux tree with the series
applied. It needs a host C compiler:

```sh
python3 kernel/apollo/tests/check-pd-policy.py /path/to/patched/linux
```

The script compiles the driver's own policy and register routines with fake
TCPM and PMIC interfaces. It covers the 500 mA and 2.21 A offers seen on the
phone, standby, Type-C Rp levels, detach and source role, the current step
boundaries, read and write failures, the sysfs bounds, and that the charge
limit keeps input power. It complements a build and a trial on the phone; it
does not replace them.

## Charge limit

The PM8150B charger exposes only `charging_enabled`, with no thresholds.
`devices/apollo/apollo-charge-limit` (with its `.conf` and `.service`) switches
it off at 80% and back on at 75%, and back on whenever the service stops. With
charging off the phone runs from USB: the battery current is about -3 mA. The
fuel gauge's status still says "Charging" then, and the charger reports 0 V,
because it stops measuring.

`devices/apollo/tmpfiles/` has negroni's two rules for this SoC family: UFS
clock scaling off (`1d84000.ufshc`), and the cpufreq transition tables hidden
from node_exporter (the prime core's policy has 20 frequencies, its table is
over a page, and the kernel answers EFBIG).

## Unlocking and flashing

- **Mi Unlock.** The 168 h wait belongs to the account and the phone. The
  token the server signs is the phone's current one, and it changes whenever
  fastboot restarts: a saved signed token is then refused ("Token Verify
  Failed, Reboot the device"). Run the unlock tool again instead; the server's
  approval stands. Unlocking reboots into MIUI recovery for the data wipe.
- **Fastboot over USB/IP** (usbipd on Windows): after a run of separate
  fastboot calls the bootloader starts answering garbage (getvars read 0) and
  the next transfer hangs until the device is detached. Restart fastboot, then
  flash everything in one fastboot invocation with nothing before it.
  `fastboot reboot` is ignored there; hold Power for ~10 s. An older Debian
  fastboot (34.0.5) also hung on `stage`; Google's platform-tools did not.

## Not proven yet

- **USB-PD after a kexec.** In the 0006 trial the adapter kept its old 9 V
  output across the jump, while TCPM in the new kernel received no PD messages
  and fell back to Type-C 5 V / 3 A. A software Type-C reset did not restore
  PD; a power cycle of the charger did. So an unattended reboot may leave the
  phone charging at the Type-C level until the charger is power-cycled.
- **0006 as published has not been booted.** The trial build (`local1`) used
  `system_wq` and logged a deprecation warning. The patch now uses
  `system_percpu_wq`; that version (`local2`) builds and passes the artifact
  checks only.
- A hang that also stops the lockup detectors (every CPU stuck with
  interrupts off, and no other CPU left to notice) has nothing to reset it:
  the watchdog does not (above), so the phone stays hung until Power is held.
- The loader kernel's own lockup handling: it is postmarketOS's configuration,
  without the series' panic options.
