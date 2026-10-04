<!-- SPDX-License-Identifier: GPL-2.0-only -->
# The kexec loader

The loader gives a phone its own A/B-style kernel slots on top of the
bootloader, without writing boot partitions for every kernel update. The
bootloader always boots one fixed kernel, the *loader kernel*. It is changed
rarely and by hand, and no package install touches it. Early in that boot the
loader kexecs a packaged kernel from `/boot`. If a packaged kernel is bad, the
worst case is two resets, after which the phone stays on the loader kernel.

## Boot flow

1. The bootloader boots the loader kernel.
2. `phone-kexec-loader.service` runs very early: after the root filesystem is
   remounted, before the firmware loader, udev, the network and any cluster
   agent. At this point no DSP, modem or USB-PD activity has started, and there
   is less to quiesce before the jump.
3. The loader checks whether this is a bootloader boot by looking for a marker
   word on the kernel command line. The default is `earlycon`, which negroni's
   bootloader passes. Set `PHONE_BOOT_LOADER_MARK` in `/etc/default/phone-boot`
   for other devices; rhodep's boot image carries its own `phone.loader`.
   `phone-kexec-test` strips the marker from every kexec'd kernel's command
   line, so the kexec'd boot is told apart.
4. On a bootloader boot it picks a kernel: the trial while it has tries left,
   otherwise the good kernel, otherwise none. Then it stages it
   (`phone-kexec-test load`) and hands over (`phone-kexec-test go`).
5. In the kexec'd kernel, the loader only leaves a marker in `/run/phone-boot`
   for bless and exits.
6. `phone-kexec-bless.service` runs once the system is up and decides whether
   the launch counts (see [Bless](#bless)).

Staging or handover failures that happen before the jump are refunded: the
trial keeps its try, and the boot carries on on the loader kernel.

## State

`/var/lib/phone-boot/state` is a small shell-sourced file:

| Field | Meaning |
|---|---|
| `good` | the last kernel that passed the health check |
| `trial` | a newly installed kernel to try first |
| `tries` | boots left for the trial before it is given up (2 by default) |
| `launched` | the kernel the loader last kexec'd; bless clears it |
| `strikes` | launches of `good` in a row that were never blessed |

A launch that was never blessed charges the kernel it launched on the next
bootloader boot. That covers a hang, a crash, or failing the health check,
after which a reset or bless's reboot brings the phone back to the bootloader.
A trial loses a try; the good kernel takes a strike. After two strikes
(`PHONE_BOOT_MAX_STRIKES`) the loader stays on the loader kernel until
`phone-kexec-loader reset` or a new trial. This is the escape hatch: a good
kernel that breaks later, for example through a changed device tree, cannot
trap the phone in a loop.

```
phone-kexec-loader status   # show the state
phone-kexec-loader reset    # clear the strikes and the pending launch
```

The loader also appends every decision to `/var/lib/phone-boot/log`, synced
after each line. It runs before the journal is flushed to disk, so its
journal messages would not survive the jump.

## Bless

`phone-kexec-bless` runs only in a kexec'd kernel. It waits (up to
`PHONE_BOOT_HEALTH_DEADLINE`, 600 s) for the node to be healthy. By default
that means a default route, `k3s-agent` active and the kubelet's
`127.0.0.1:10248/healthz` answering. Replace the whole check with
`PHONE_BOOT_HEALTH_CMD` for other workloads. When the node is healthy:

- a trial becomes `good`, and the trial, tries, strikes and launch are cleared;
- a launch of `good` clears its strike count.

If the deadline passes, bless reboots, but only when the running kernel is the
one the loader launched. A kernel that was kexec'd by hand is never rebooted.

## Kernel hooks

- `zz-phone-kexec-trial` (`/etc/kernel/postinst.d`) makes a newly installed
  kernel package the trial with two tries. Installing a kernel deb and
  rebooting is all it takes to try it.
- `zz-phone-kexec-trial.postrm` (`/etc/kernel/postrm.d`) clears a trial, good
  or pending launch that names a removed kernel.

## Only this device's kernels

`/etc/default/phone-kexec` sets `FLAVOUR`, the device codename in the kernel
release (`<version>-<FLAVOUR>-<build>`, for example `7.3.0-rc5-negroni-ci86`).
The trial hook ignores any other kernel. The loader drops a trial or good
kernel of another flavour instead of launching it. Distribution kernels cannot
boot these phones, and apt will install one to satisfy a Recommends. A
`wireguard-tools` install pulled in Debian's `linux-image-rt-arm64` this way.
`loader/examples/no-debian-kernels` is an apt preferences file that keeps Debian's
`linux-image-*` off entirely.

While a device's builds change name, `FLAVOUR` can list several,
space-separated (`FLAVOUR="negroni sm8450"`), so the old good kernel stays a
valid fallback until a kernel with the new name is blessed. `phone-bootimg`
uses only the first name.

## Settings

`/etc/default/phone-kexec` is read by the loader and the trial hook:

| Setting | Default | Meaning |
|---|---|---|
| `FLAVOUR` | empty (any kernel) | the device's kernel flavour or flavours, see above |

`/etc/default/phone-boot` is read by `phone-kexec-loader` and
`phone-kexec-test`. `loader/examples/phone-boot` is a commented copy.

| Setting | Default | Meaning |
|---|---|---|
| `PHONE_BOOT_LOADER_MARK` | `earlycon` | the word on the bootloader's command line that marks a bootloader boot; stripped from every kexec'd kernel's command line, along with `earlycon` and `bootconfig` |
| `PHONE_KEXEC_ARGS` | empty | words added to every kexec'd kernel's command line; a word already there is not added twice, and arguments given to `phone-kexec-test load` come after them |
| `PHONE_KEXEC_RMTFS_HANDBACK` | `0` | `1` unbinds `qcom_rmtfs_mem` before the jump, which hands the rmtfs memory back; on negroni every kexec that did this ended in EDL, and rhodep's secure world refuses the reassignment |
| `PHONE_KEXEC_REBOOT_MODE` | empty | written to `/sys/kernel/reboot/mode` just before the jump, so it decides how the kexec'd kernel's crash or watchdog bite resets the SoC; `warm` keeps RAM and with it the pstore record; empty leaves the kernel's default (cold); `warm` is not safe everywhere: it took a negroni down |
| `PHONE_KEXEC_OFFLINE_CPUS` | `0` | `1` takes the secondary CPUs offline a moment before the jump and logs how each powered off; a diagnostic; never on negroni, where CPU hotplug stalls storage I/O |
| `PHONE_KEXEC_OFFLINE_SETTLE` | `1` | seconds to wait after taking the CPUs offline |
| `PHONE_KEXEC_DTB_BASE` | `running` | the kexec'd kernel's device tree: `running` is the tree the bootloader passed, as booted; `package` is the kernel package's DTB with the running tree's memory nodes copied in, for a loader kernel whose tree is older than the kexec'd kernels' (apollo) |
| `PHONE_KEXEC_DISPLAY_OFF` | `0` | `1` blanks the framebuffers before the jump, turning the display off through DRM; needed where the loader kernel drives the panel (apollo) |
| `PHONE_KEXEC_CONSOLE_LOGLEVEL` | empty | console log level (`dmesg -n`) for this kernel's last steps, so its CPU shutdown messages reach the pstore console; empty leaves it alone |
| `PHONE_BOOT_MAX_STRIKES` | `2` | unblessed launches of the good kernel in a row before the loader stays on the loader kernel |
| `PHONE_BOOT_PSTORE_KEEP` | `10` | pstore captures to keep |

Read elsewhere:

- `phone-kexec-test` takes `DTB`, the path of the device's DTB inside a kernel
  package, from `/etc/default/phone-bootimg` (see
  `loader/examples/phone-bootimg.negroni`). Without it, it uses negroni's.
- `phone-kexec-dtb` reads `PHONE_KEXEC_DTB_WATCHDOG` (default `0`) from its
  environment. `1` carries the APSS watchdog node over from the package DTB
  into the kexec'd kernel's tree. It is not passed on from
  `/etc/default/phone-boot` unless it is exported there. Leave it off on
  negroni ([kexec-on-qualcomm.md](kexec-on-qualcomm.md#watchdogs)).
- `phone-kexec-bless` reads its settings from its environment, for example
  from `Environment=` lines in a drop-in for its unit:
  `PHONE_BOOT_HEALTH_DEADLINE` (600 s), `PHONE_BOOT_HEALTH_INTERVAL` (15 s
  between checks) and `PHONE_BOOT_HEALTH_CMD` (empty: the default check).
- The trial hook gives a new trial `PHONE_BOOT_TRIES` tries (2).

What rhodep and apollo set, and why, is in
[rhodep.md](rhodep.md#loader-settings) and [apollo.md](apollo.md#loader-settings).

## Crash reports

A crashed kernel's console survives the reset only in the ramoops zone, and
only in part (see [kexec-on-qualcomm.md](kexec-on-qualcomm.md#pstore)).
`systemd-pstore` moves that record away within milliseconds of boot, and every
boot archives its console under the same name. So the loader unit is ordered
`Before=systemd-pstore.service`. On each bootloader boot it copies
`/sys/fs/pstore` to `/var/lib/phone-boot/pstore/<time>-<random>/`, keeps the
newest 10 (`PHONE_BOOT_PSTORE_KEEP`), and logs the first panic, oops, lockup or
hung-task line it can match.

## Panics must reboot

Nothing else resets a hung phone. There is no usable hardware watchdog on
negroni, and there is no UART. A hang only gets back to the loader by
panicking. (rhodep's APSS watchdog works and resets a hung kernel too; see
[rhodep.md](rhodep.md#loader-settings).) `loader/examples/90-phone-panic.conf`
sets:

```
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.panic_on_rcu_stall = 1
-kernel.hung_task_panic = 1
```

These apply from early boot, on the loader kernel too. The kubelet sets the
first two itself, but only once it runs. The kernels here also build them in
(`PANIC_TIMEOUT=10`, `PANIC_ON_OOPS`, soft and hard lockup panic). A task stuck
in D state for 120 s reboots the phone, and so does I/O on a stalled network
block device. Set `hung_task_panic` to 0 if that is not what you want.

## Tests

`loader/tests/phone-kexec-loader.sh` runs the loader, bless and both hooks
against a stubbed kexec, a fake `/boot`, fake command lines and a temporary
state directory. It covers trials, fallbacks, strikes, reset, refunds, the
flavour guard, pstore capture and the loader marker. It needs no phone and no
root:

```
bash loader/tests/phone-kexec-loader.sh
```

The other `PHONE_BOOT_*` variables and `PHONE_KEXEC_TEST` that the scripts
read exist for this harness: the state, run and log paths, the two settings
files, the command line, `/boot`, the modules directory, the kexec helper, the
pstore directory, the running release and the reboot command. On a phone they
are left unset.
