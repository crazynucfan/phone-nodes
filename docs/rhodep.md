<!-- SPDX-License-Identifier: GPL-2.0-only -->
# rhodep: Motorola moto g82 5G (SM6375)

The series in `kernel/rhodep/` applies to v7.2.9. It builds
`qcom/sm6375-motorola-rhodep.dtb` with `rhodep_defconfig`, and kernels are
released as `<version>-rhodep-<build>`. See CREDITS.md for where the patches
come from.

**State:** runs as a node. The phone boots a loader kernel from its boot
partition, and the loader kexecs packaged kernels from `/boot` and blesses
them, as on negroni. The modem and Wi-Fi come up in the kexec'd kernel.

## What the series covers

Patches 0001–0011 are the device support:

- **Storage:** the UFS PHY and host (SM6375 support, UFS without inline
  crypto).
- **Device tree and config:** the device tree, CPU capacities and power
  coefficients, the APSS watchdog, and `rhodep_defconfig`.
- **Charging and remoteprocs:** the discrete SG Micro SGM41542 charger (a
  bq256xx variant, with charging enabled at probe), and the pd-mapper entry
  for the remoteprocs. The charge cap is in the device tree (4.1 V, 1 A), so
  no charge limit service is needed.
- **Console:** the null TTY driver built in. Motorola's bootloader rewrites
  every `console=` on the command line to `console=null`. Without `NULL_TTY`
  there is no console at all, `/dev/console` cannot be opened, and the
  initramfs's final `exec` kills PID 1.

There is no driver for the Type-C CC logic (SGM7220). The fuel gauge (CW2217)
has a read-only driver since patches 0018–0020, described
[below](#the-fuel-gauge-0018-to-0020).

Patches 0012–0017 are what a node and the kexec loader needed on top:

| Patch | What |
|---|---|
| 0012 | bpf: a non-scalar `bpf_set_retval()` argument fails with -EACCES instead of -EINVAL |
| 0013 | `qcom_glink_rpm`: resume the FIFOs where the RPM left them |
| 0014 | `qcom_glink`: take over the RPM's open channel after a kexec |
| 0015 | `rhodep_defconfig`: soft and hard lockup panic, panic on oops, 10 s reboot, `test_lockup` |
| 0016 | `qcom_rmtfs_mem`: use a region a previous kernel already assigned |
| 0017 | `rhodep_defconfig`: pseudo-NMI |

- **0012.** v7.2.8 gained a verifier check that fails a non-scalar
  `bpf_set_retval()` argument with -EINVAL. Every other type mismatch is
  -EACCES. cilium/ebpf reads -EACCES as "the helper exists, the arguments are
  wrong" and -EINVAL as "no such helper" or an unknown failure, and Cilium
  1.20.1's agent exits on its helper probe. The patch makes the check fail
  with -EACCES. Programs that pass a non-scalar are rejected as before.
- **0013.** `glink_rpm_probe()` zeroes the TX head and RX tail. After a kexec
  the RPM's own indices are wherever the previous kernel left them, so the RPM
  parsed stale FIFO contents as commands and took the SoC down about 0.13 s
  into the new kernel. The patch sets the TX head to the RPM's TX tail and the
  RX tail to the RPM's RX head.
- **0014.** After a kexec the RPM's glink link is still up. The RPM keeps
  `rpm_requests` open under the previous kernel's channel id. It does not
  answer a new version handshake and does not announce the channel again, so
  the new kernel never got an `rpm_requests` device, and every consumer of an
  RPM clock, power domain or regulator deferred forever. When the FIFO indices
  show a previous user, the patch skips the handshake and registers
  `rpm_requests` as already open. `qcom_glink_rpm.handover=` forces the choice
  (-1 auto, 0 no, 1 yes).
- **0015.** As on negroni: a kernel that hangs only comes back if it panics or
  the watchdog bites. The hard lockup detector runs in buddy mode.
- **0016.** The secure world on SM6375 refuses every further assignment of
  the rmtfs region (-EINVAL), even back to Linux. After a kexec the next
  kernel's probe failed, rmtfs had no memory, the modem crashed reading its
  file system, and the recovery hung the SoC. When the assignment is refused,
  the patch warns and uses the region as it is, and does not try to give it
  back on remove.
- **0017.** About 1 in 5 kexec'd kernels hung in their first 50 ms: CPU 6 (the
  first Cortex-A78) came up and then took no interrupt at all, so the first
  cross-CPU call waited forever. With pseudo-NMI the hang did not occur in 36
  launches. The option only takes effect with `irqchip.gicv3_pseudo_nmi=1` on
  the command line. It also gives the lockup detector NMI backtraces.

How 0013, 0014, 0016 and 0017 were found is in
[kexec-on-qualcomm.md](kexec-on-qualcomm.md).

### The fuel gauge (0018 to 0020)

| Patch | What |
|---|---|
| 0018 | the device tree binding for the CellWise CW2217 |
| 0019 | `cw2217_battery`: a read-only driver for it |
| 0020 | the gauge in rhodep's device tree (I2C8, address 0x64), and the driver as a module in `rhodep_defconfig` |

The driver reports the charge percentage, voltage, signed current,
temperature, cycle count and the gauge's health estimate through
`power_supply`. It only reads:

- Motorola's bootloader has already loaded the battery's own profile into the
  gauge. The driver never resets the chip and never loads a profile, and its
  regmap refuses every register write.
- Before reporting anything it checks the chip identity, the firmware family,
  the active mode, the profile-loaded flag and the ready state. A gauge that is
  asleep or has no profile gives an error, not an invented reading.
- The current needs the board's sense resistor: 5 mΩ on rhodep, from
  Motorola's stock device tree (`shunt-resistor-micro-ohms = <5000>`).

**Trial (2026-10-09):** the driver, built as a module for the running
`7.2.9-rhodep-ci158` kernel and loaded without a reboot, reported about 76%,
4.11 V and 38 °C. The percentage is the gauge's raw value, without Android's
rescaling for its UI. The cycle count and health are the gauge's own
estimates, not checked against anything.

**With the kexec loader, the new device tree alone does not bring the gauge
up.** rhodep's kexec'd kernels get the running device tree, the one the
bootloader passed from `vendor_boot`. The node from 0020 only appears once the
boot images are packed again with a DTB from this series. Until then the gauge
can be created by hand. The driver takes the sense resistor as a module
parameter for that case (`<N>` is Linux's number for the bus the device tree
calls I2C8):

```sh
modprobe cw2217_battery shunt_resistor_micro_ohms=5000
echo cw2217 0x64 > /sys/bus/i2c/devices/i2c-<N>/new_device
```

The driver's routines can be tested off the phone, against a Linux tree with
the series applied (it needs a host C compiler):

```sh
python3 kernel/rhodep/tests/check-gauge.py /path/to/patched/linux
```

The script compiles the driver's own C routines with a fake read-only
transport. It covers every signed current value, the unit conversions, the
retry of a word whose high byte rolled over, readiness and I2C errors, and the
ban on register writes.

## Loader settings

rhodep's `/etc/default/phone-kexec` sets `FLAVOUR="rhodep"`. Its
`/etc/default/phone-boot` (see [kexec-loader.md](kexec-loader.md#settings));
both files are in `devices/rhodep/examples/`:

```
PHONE_BOOT_LOADER_MARK=phone.loader
PHONE_KEXEC_ARGS="panic=10 softlockup_panic=1 watchdog.open_timeout=180 irqchip.gicv3_pseudo_nmi=1"
PHONE_KEXEC_REBOOT_MODE=warm
PHONE_KEXEC_RMTFS_HANDBACK=0
```

- **The marker.** The bootloader rewrites the command line it is given and
  passes nothing like `earlycon`, so the boot image's command line carries its
  own marker word, `phone.loader`.
- **`panic=10 softlockup_panic=1`.** A kexec'd kernel that hangs must come
  back by itself. The boot image's command line has no panic timeout, and an
  initramfs that cannot find the root filesystem waits forever without one.
- **`watchdog.open_timeout=180`.** The APSS watchdog is still running across
  the kexec. The kernel pets it until userspace takes it over, and stops after
  180 s if that has not happened. A kernel stuck before userspace is then
  reset as well.
- **`irqchip.gicv3_pseudo_nmi=1`.** Turns on the pseudo-NMI that patch 0017
  builds in.
- **Warm reset.** A warm reset keeps RAM through a watchdog bite, so a failed
  launch still leaves its pstore record. This is the opposite of negroni,
  where the warm mode must not be used.
- **No rmtfs hand-back.** The secure world refuses the reassignment; patch
  0016 handles the region in the kernel instead.
- **No LPI tables.** SM6375 has no GIC ITS, so there are no tables to reserve,
  and `phone-kexec-dtb` passes the running device tree through unchanged.

Unlike negroni's, rhodep's APSS watchdog is usable. systemd on the loader
kernel arms it and keeps it armed for the jump, and the driver does not stop it
on a kexec, so the next kernel's `qcom_wdt` takes over the watchdog the loader
left armed and pets it until userspace opens it. A failed launch is reset by
the watchdog or by a panic. The watchdog counts to 31 s at most.
`loader/systemd/20-phone-watchdog.conf` sets `RebootWatchdogSec` and
`KExecWatchdogSec` to 2 min, which this watchdog refuses, and it is then left
disarmed. On rhodep a later drop-in, `devices/rhodep/21-phone-watchdog-cap.conf`
(for `/etc/systemd/system.conf.d/`), sets both to 30 s. Without it a launch
that hangs waits for the power button.

The boot image hook (`loader/zz-phone-bootimg`) is not used on rhodep, because
its boot images need the fixups described below. `/etc/default/phone-bootimg`
holds only `DTB=`, which `phone-kexec-test` reads to find the kernel package's
device tree (`devices/rhodep/examples/phone-bootimg`).

## Bootloader

Motorola's bootloader (MBM-3.0, Qualcomm's ABL with additions) checks more
than upstream's does. A missing piece gives a boot loop or a `DXE_ASSERT`. The
bootloader writes a log of each failed boot to the `logfs` partition, one
`LogNN.txt` per boot. The partition is FAT16 with 4 KiB sectors and is
readable with root on stock Android. Its FAT chains are not maintained, so the
files have to be read as contiguous runs. This list comes from those logs:

- **Header v3, DTB in `vendor_boot`.** That is what this series uses, with the
  kernel, ramdisk and command line in `boot`. Other ports of this phone boot
  header v2 images with a flat `Image` and the DTB appended. A v2 image with a
  gzip'd kernel reset the phone here, and v2 was not pursued. The rest of the
  list is about the v3 path.
- **The DTB is matched on `qcom,msm-id` and on its root `model`.** The model
  has to be the stock `"Qualcomm Technologies, Inc. Blair "`, with the trailing
  space. The kernel's device tree keeps its own values, so the image is packed
  with a copy that has the stock model, both stock msm-ids
  (`<0x1fb 0x10000 0x242 0x10000>`), `qcom,blair` added to the compatible and
  an empty `channel-id-map` property, as the stock DTB has. The stock
  `vendor_boot` carries a second, small DTB after the SoC one; it is appended
  again.
- **A `dtbo` entry must match the board.** A zeroed `dtbo` is refused ("Board
  Dtbo blob not found"). The bootloader's overlay code wants `__symbols__` in
  the base DTB (the series builds the device tree with `-@`) and `__fixups__`
  in the overlay. A no-op overlay per stock entry, with the stock entry's
  matching properties copied, is enough.
- **The matching entry's root properties replace the DTB's.** The bootloader
  copies the entry's `model` and `compatible` over the SoC DTB's. The no-op
  overlays therefore put `motorola,rhodep` and `qcom,sm6375` in front of the
  stock compatibles. Drivers that match device nodes are not affected, but
  code that matches the machine compatible is: without `qcom,sm6375` the
  in-kernel pd-mapper does not start the WLAN protection domain, and there is
  no `wlan0`.
- **The vendor command line must contain `console=` and
  `androidboot.console=`.** Without `console=` the bootloader asserts
  (`DXE_ASSERT` at `boota:786`). It rewrites them to `console=null`, which is
  why the series builds in the null TTY.
- **The vendor ramdisk must be an empty cpio.** With the stock one in front,
  the initramfs fails to unpack.
- **`vbmeta` is built with flags 2** (verification disabled). Give it a
  rollback index no lower than the one the installed firmware stored, or
  flashing warns of an anti-rollback downgrade. `avbtool info_image` on the
  stock `vbmeta` shows it; it was 29 on firmware T1SUS33.1-124-6-16.

`devices/rhodep/pack-bootimg.sh` packs `boot.img`, `vendor_boot.img`,
`dtbo.img` and `vbmeta.img` this way from a kernel, its DTB and an initramfs.
It needs the stock `vendor_boot` and `dtbo` images read from your own phone
(they are only read, and are not in this repository), and AOSP's `mkbootimg`
and `avbtool`. `devices/rhodep/flash-slot.sh` writes the result to one slot
with fastboot and switches to it. The other slot keeps stock Android. Back up
the slot's stock partitions first; the script does not.

Other things to know:

- `fastboot boot` works, so a kernel can be tried from RAM before anything is
  flashed. Fastboot is Volume Down + Power. From Linux,
  `systemctl reboot --reboot-argument=bootloader` gets there without buttons:
  the bootloader reads the reboot reason from the PM6125 PON register, which
  upstream's `qcom-pon` writes.
- The phone is A/B. Stock Android stays on slot a and Linux goes on slot b.
  The slot state is in the GPT attribute bits of `boot_b` (priority 48–49,
  active 50, retry count 51–53, successful 54, unbootable 55).
  `fastboot --set-active` resets the slot to 7 tries, not successful. At 0 the
  bootloader is expected to fall back to slot a; that was never allowed to
  happen here. `loader/qcom-slot-successful` and
  `loader/systemd/mark-slot-successful.service` set the successful bit on
  every boot. They change only that bit, in the primary and backup tables.
- The panel keeps showing the simple framebuffer (the kernel log) only with
  `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` on the command
  line. Without `regulator_ignore_unused` the image froze when REFGEN was
  turned off.

## USB

With no Type-C driver, nothing picks the port's role, and the USB controller
comes up as a peripheral. That is what bring-up wants: a USB gadget to log in
over. To run on a USB Ethernet adapter instead,
`devices/rhodep/phone-usb-role.service` writes `host` to
`/sys/class/usb_role/*/role` at boot. An adapter with power pass-through and a
charger behind it then gives network and power on one cable, without PD.

## Modem file system

The modem writes to its remote file system through `tqftpserv`, which serves
`/tmp/tqftpserv`. The firmware loader (`third-party/msm-firmware-loader/`, a
modified copy of postmarketOS's) links that directory to the modem's area on
the read-only `persist` partition, and the modem then
retries one write every second, forever. `devices/rhodep/tqftpserv-rw` (with
its unit) mounts an overlay there: reads come from `persist`, writes stay in
`/var/lib/tqftpserv`, and `persist` is never written.

## node_exporter

The hwmon collector reads the Wi-Fi chip's temperature, which the WCN3990
firmware never answers, so ath10k waits out its 5 s timeout on every scrape.
`devices/rhodep/examples/prometheus-node-exporter` leaves that chip out. A
scrape went from 5.3 s to 0.44 s.

## UFS clock scaling off

All storage I/O stopped on a rhodep running as a node. The hung task detector
panicked and the phone rebooted. The cause is a deadlock in ufshcd's clock
scaling: `ufshcd_clock_scaling_prepare()` quiesces the tag set and then takes
`clk_scaling_lock` for write, while the query from `ufshcd_rtc_work` holds the
read lock and waits on the quiesced queue.

Clock scaling is now turned off at every boot with a tmpfiles rule,
`devices/rhodep/tmpfiles/phone-ufs-clkscale.conf`:

```
w /sys/bus/platform/devices/4804000.ufshc/clkscale_enable - - - - 0
```

The deadlock was seen once, on 2026-10-01, and scaling has been off since.
The rule has no long soak behind it yet.

## Not proven yet

- The loader kernel on the phone is still a build of patches 0001–0012. A
  cold boot of a kernel with 0013–0017 as the loader kernel is untested.
- Why pseudo-NMI stops the CPU 6 hang is a hypothesis. The result is what was
  measured: no hang in 36 launches.
- The fuel gauge driver (0018–0020) has only run as a module loaded into a
  running kernel built without it. A kernel built from the whole series, and
  the gauge probed from the device tree, have not been booted.
- `pack-bootimg.sh` reproduces the images running on the phone byte for byte,
  except `dtbo.img`: the flashed one was built with another name for the empty
  property its overlays add (`NOOP_PROPERTY`). The name is arbitrary, but a
  `dtbo.img` with the default name has not been flashed.
- `flash-slot.sh` runs the command sequence that flashed the phone. The script
  as published has not been run against a phone.
