<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Mainline Linux on Qualcomm phones, as headless nodes

This repo holds kernel patch series and a kexec-based boot loader for running
mainline Linux (Debian userspace) on retired Qualcomm phones as always-on,
headless nodes: USB Ethernet, charging, no display needed. Each device is a
small patch series against an upstream tag, so moving to a newer kernel means
rebasing a series rather than maintaining a fork. The loader lets a phone try
new kernels from `/boot` and fall back by itself, without reflashing and
without anyone at the phone.

| Codename | Phone | Model | SoC | Base | Status |
|---|---|---|---|---|---|
| negroni | OnePlus 10 Pro | NE2213 | SM8450 | v7.3-rc5 | runs as a node; kernels via the kexec loader |
| apollo | Xiaomi Mi 10T Pro | M2007J3SG | SM8250 | v7.2.8 | series builds; not yet booted from these builds |
| rhodep | Motorola moto g82 5G | XT2225 | SM6375 | v7.2.8 | runs as a node; kernels via the kexec loader |

## Layout

```
kernel/<device>/     BASE, series, patches/, build.env, required-config,
                     dtb.sha256
kernel/scripts/      fetch.sh, apply.sh, build.sh, check-artifacts.sh,
                     distcc-pool.sh, export.sh
kernel/Dockerfile    the cross toolchain and the build as Docker stages
loader/              the kexec loader, its helpers, hooks and tests
loader/systemd/      the units
loader/examples/     config files: /etc/default/*, sysctl, apt pin
devices/negroni/     negroni's USB Ethernet recovery and charge limit
devices/negroni/tmpfiles/
                     tmpfiles.d rules: UFS clock scaling off, and a fix for
                     node_exporter's CPU frequency metrics
devices/rhodep/      rhodep's boot image packing and flashing scripts, modem
                     file system overlay, USB host role unit and watchdog
                     timeout cap
devices/rhodep/tmpfiles/
                     tmpfiles.d rule: UFS clock scaling off
devices/rhodep/examples/
                     rhodep's /etc/default/* files
third-party/msm-firmware-loader/
                     postmarketOS's firmware loader as these phones run it
                     (MIT and Apache-2.0, not GPL; see its README)
docs/                how it works and what we learned
```

## Building a kernel

With Docker, run from `kernel/`; no local toolchain is needed:

```sh
docker buildx build --target artifacts --build-arg DEVICE=negroni \
    --build-arg BUILD_ID=local1 --output type=local,dest=out/negroni .
```

Or with an aarch64 cross toolchain installed:

```sh
kernel/scripts/build.sh negroni local1 out/negroni
```

The output holds the kernel, the DTB, the modules and Debian packages:
`linux-image-<release>` plus the meta package `linux-image-<device>`.
`kernel/scripts/check-artifacts.sh` checks a build against the device's
`required-config`, the DTB hash and the kexec size budget. The build id
becomes part of the kernel release, so every build needs its own.

## Running kernels through the loader

1. The phone boots a *loader kernel* from its boot partition, flashed once. It
   stays the way back and is never touched by package installs.
2. Install the loader with `loader/install.sh` (read it first). Set the
   device's flavour in `/etc/default/phone-kexec` and, if the bootloader does
   not pass `earlycon`, a marker in `/etc/default/phone-boot` (see
   `loader/examples/`).
3. Install a kernel package. The postinst hook makes it the *trial*.
4. Reboot. The loader kexecs the trial, and once the system is healthy bless
   promotes it to *good*. A trial that hangs, crashes or stays unhealthy falls
   back after two tries. After two failed launches of the good kernel, the
   loader stays on the loader kernel.

The design is in [docs/kexec-loader.md](docs/kexec-loader.md), and what it took
to make kexec work on these SoCs is in
[docs/kexec-on-qualcomm.md](docs/kexec-on-qualcomm.md). Device notes:
[negroni](docs/negroni.md), [apollo](docs/apollo.md), [rhodep](docs/rhodep.md).

## Before you try this

- You need an unlocked bootloader, and you should know how to get back to
  stock on your device. Mistakes here can leave a phone in a boot loop or in
  the Qualcomm download mode (EDL).
- Keep the vendor's boot slot (or boot partition backup) as the way back.
  Read the device notes first: negroni's A/B slot retry trap looks like a
  brick.
- No firmware is included. DSP, modem and Wi-Fi firmware stays the vendor's
  and is loaded from the phone's own partitions at runtime.
- Check your device's reboot quirks: negroni must never warm-reboot, while
  apollo must.

## Naming

Builds are named after the device codename, never the SoC (two devices can
share one) or a host name: `<device>_defconfig`,
`CONFIG_LOCALVERSION="-<device>"` (releases like `7.3.0-rc5-negroni-local1`) and
the meta package `linux-image-<device>`. The loader only ever kexecs kernels of
its device's flavour.

## Licence

GPL-2.0-only; see [LICENSE](LICENSE). The kernel patches are derived from the
Linux kernel and from the community forks named in [CREDITS.md](CREDITS.md),
and every file keeps its original copyright and licence notices. The tooling in
`loader/`, `devices/` and `kernel/scripts/` is GPL-2.0-only as well.

The exception is `third-party/msm-firmware-loader/`, a modified copy of an
MIT-licensed project. Its README says where each file comes from and what was
changed, and its two licence files apply to it.
