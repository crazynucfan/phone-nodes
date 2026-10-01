# msm-firmware-loader (modified copy)

This directory is not GPL. It is a modified copy of postmarketOS's
[msm-firmware-loader](https://gitlab.postmarketos.org/postmarketOS/msm-firmware-loader),
which mounts a Qualcomm phone's firmware partitions and links the firmware
files into one directory the kernel can load from. No firmware is included.

negroni and rhodep run this copy. `devices/rhodep/tqftpserv-rw` relies on
its paths: `/lib/firmware/msm-firmware-loader` and the `/tmp/tqftpserv` link.

Upstream has moved on since the version this copy is based on. It now supports
UFS itself and keeps its mounts in `/run`. For any other phone, use upstream.

## Where the files come from

| File | Origin |
|---|---|
| `msm-firmware-loader.sh` | upstream at `4626496` (2024-03-27), with the changes below |
| `msm-firmware-loader-unpack.sh` | upstream, unchanged (the file as of `fd796e7`, 2022-06-28) |
| `msm-firmware-loader.service`, `msm-firmware-loader-unpack.service` | upstream, with `ExecStart` moved from `/usr/sbin` to `/usr/local/sbin` (changed here) |

Changes to `msm-firmware-loader.sh` as found in
[withsalt/oneplus-negroni-arch-linux](https://github.com/withsalt/oneplus-negroni-arch-linux),
`tools/msm-firmware-loader/` at `3b428cf` (2026-09-16):

- Partitions on UFS (`/sys/block/sd*`) are scanned as well as eMMC ones,
  through a new function.
- The `bluetooth` partition gets the A/B slot suffix, and a `soccp` partition
  is added.
- Without `qbootctl`, the slot suffix is a fixed `_a`. Upstream reads it from
  the kernel command line.
- `/tmp/tqftpserv` is linked to the modem's area on the `persist` partition,
  and the sensor registry on `persist` is linked under `/usr/share/qcom`.

Changes made here, on top of that copy:

- The slot suffix is read from `/etc/msm-firmware-loader.slot` when that file
  exists (for example `_b`), so the slot whose firmware partitions are used is
  set by hand. The `qbootctl` branch is disabled.

## Licence

- Upstream is MIT: `LICENSE.MIT` is upstream's licence file, "Copyright © 2022
  Nikita Travkin". Both scripts keep their `SPDX-License-Identifier: MIT`
  line. The two units have no licence line, here or upstream.
- The oneplus-negroni-arch-linux project left that line in place, and the
  `LICENSE` file in its `tools/msm-firmware-loader/` directory is the Apache
  License 2.0. It does not say which of the two applies to its changes, so
  both are included: `LICENSE.Apache-2.0` is that file.
- The changes made here are offered under MIT.
