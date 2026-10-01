#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# pack-bootimg.sh: pack a mainline kernel for a Motorola moto g82 5G (rhodep)
# into the images its bootloader accepts: boot.img, vendor_boot.img, dtbo.img
# and vbmeta.img, for one slot.
#
#   KERNEL=Image.gz DTB=sm6375-motorola-rhodep.dtb INITRAMFS=initramfs.img \
#   STOCK_VENDOR_BOOT=vendor_boot_b.img STOCK_DTBO=dtbo_b.img \
#   ROLLBACK_INDEX=<n> ./pack-bootimg.sh [outdir]
#
# Inputs (environment):
#   KERNEL             the kernel, Image.gz
#   DTB                the kernel's sm6375-motorola-rhodep.dtb (built with
#                      dtc -@, as the series does)
#   INITRAMFS          the initramfs for the root filesystem you boot
#   STOCK_VENDOR_BOOT  vendor_boot of the slot you will flash, read from YOUR
#   STOCK_DTBO         phone (and dtbo of the same slot). They are only read:
#                      the second DTB in vendor_boot and the matching
#                      properties of each dtbo entry are copied. Do not
#                      publish them.
#   ROLLBACK_INDEX     no lower than the one your firmware stored; read it
#                      from the stock vbmeta: avbtool info_image --image
#                      vbmeta_b.img. A lower one is flashed with an
#                      "anti rollback downgrade" warning.
# Optional:
#   CMDLINE            kernel command line (default below)
#   VENDOR_CMDLINE     what the bootloader wants to see (default below)
#   OS_VERSION, OS_PATCH_LEVEL  as in your stock boot image (unpack_bootimg)
#   MKBOOTIMG, AVBTOOL the AOSP tools (default: mkbootimg, avbtool in PATH;
#                      AVBTOOL may be "python3 /path/to/avbtool.py")
#   NOOP_PROPERTY      name of the empty property the generated overlays add
#
# Also needs dtc, fdtget, fdtput (device-tree-compiler), python3 and cpio.
#
# What Motorola's bootloader (MBM-3.0, Qualcomm's ABL with additions) insists
# on, learnt from its logs in the logfs partition:
# - Header v3 with the DTB in vendor_boot.
# - The SoC DTB is matched on qcom,msm-id AND on its root `model`, which must
#   be the stock "Qualcomm Technologies, Inc. Blair " (trailing space). This
#   script rewrites model, msm-id, compatible and channel-id-map on a copy of
#   the DTB, so the kernel source keeps its proper values.
# - dtbo must be valid and one entry must match the board (a zeroed dtbo is
#   "Board Dtbo blob not found"). The script generates, for each stock entry,
#   an overlay with that entry's matching properties that changes nothing.
#   The bootloader's overlay code wants __fixups__ in the overlay and
#   __symbols__ in the base DTB (dtc -@).
# - The bootloader copies the matching entry's model and compatible over the
#   base DTB's, so the overlays put motorola,rhodep and qcom,sm6375 in front
#   of the stock compatibles: code that matches the machine compatible (the
#   in-kernel PD mapper, which Wi-Fi needs) must still find qcom,sm6375.
# - The vendor command line must carry console= and androidboot.console=
#   (missing: DXE_ASSERT). The bootloader rewrites every console= on the
#   command line to console=null, so the kernel needs CONFIG_NULL_TTY for
#   /dev/console to exist at all.
# - The vendor ramdisk must be an empty cpio: with the stock one in front of
#   the initramfs, the initramfs does not unpack.
set -euo pipefail

: "${KERNEL:?KERNEL: the kernel Image.gz}"
: "${DTB:?DTB: sm6375-motorola-rhodep.dtb}"
: "${INITRAMFS:?INITRAMFS: the initramfs image}"
: "${STOCK_VENDOR_BOOT:?STOCK_VENDOR_BOOT: your phone's vendor_boot image}"
: "${STOCK_DTBO:?STOCK_DTBO: your phone's dtbo image}"
: "${ROLLBACK_INDEX:?ROLLBACK_INDEX: see the header}"

# Root is found by label. No console= (the bootloader turns it into
# console=null anyway). pstore records stay plain text: compressed ones came
# back corrupted after a reset. phone.loader marks a bootloader boot for the
# kexec loader; it is harmless without the loader. The panel keeps showing
# the simple framebuffer (the kernel log) only while nothing turns off what
# the bootloader left on for it, hence the three *_ignore_unused.
CMDLINE=${CMDLINE:-phone.loader consoleblank=30 root=LABEL=root rootwait rw clk_ignore_unused pd_ignore_unused regulator_ignore_unused pstore.compress=none pstore.kmsg_bytes=200000}
# The stock vendor command line minus earlycon.
VENDOR_CMDLINE=${VENDOR_CMDLINE:-console=ttyMSM0,115200n8 androidboot.hardware=qcom androidboot.console=ttyMSM0}
OS_VERSION=${OS_VERSION:-11.0.0}
OS_PATCH_LEVEL=${OS_PATCH_LEVEL:-2025-04}
MKBOOTIMG=${MKBOOTIMG:-mkbootimg}
AVBTOOL=${AVBTOOL:-avbtool}
NOOP_PROPERTY=${NOOP_PROPERTY:-linux,dtbo-noop}

abs() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")"); }
KERNEL=$(abs "$KERNEL"); DTB=$(abs "$DTB"); INITRAMFS=$(abs "$INITRAMFS")
STOCK_VENDOR_BOOT=$(abs "$STOCK_VENDOR_BOOT"); STOCK_DTBO=$(abs "$STOCK_DTBO")
out=${1:-out}; mkdir -p "$out"; cd "$out"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The DTB as the bootloader wants to see it: the stock root model, both stock
# msm-ids, qcom,blair and an empty channel-id-map.
cp "$DTB" "$work/abl.dtb"
fdtget -l "$work/abl.dtb" / | grep -qx __symbols__ \
    || { echo "$DTB has no __symbols__ (build it with dtc -@)" >&2; exit 1; }
fdtput -t s "$work/abl.dtb" / model "Qualcomm Technologies, Inc. Blair "
fdtput -t x "$work/abl.dtb" / qcom,msm-id 0x1fb 0x10000 0x242 0x10000
fdtput -t s "$work/abl.dtb" / compatible motorola,rhodep qcom,sm6375 qcom,blair
fdtput -t s "$work/abl.dtb" / channel-id-map ""

# Stock vendor_boot carries a second, tiny DTB (qcom,rtic-id) after the SoC
# one; keep the same shape.
python3 - "$STOCK_VENDOR_BOOT" "$work/second.dtb" <<'PY'
import struct, sys
s = open(sys.argv[1], 'rb').read(); al = lambda x: (x + 4095) // 4096 * 4096
rsize = struct.unpack('<I', s[24:28])[0]; hsz, dtb_size = struct.unpack('<II', s[2096:2104])
blob = s[al(hsz) + al(rsize):][:dtb_size]; soc_size = struct.unpack('>I', blob[4:8])[0]
open(sys.argv[2], 'wb').write(blob[soc_size:])
PY
cat "$work/abl.dtb" "$work/second.dtb" > "$work/vendor-dtbs.bin"

# Header v3 as in the stock images: kernel, ramdisk and command line in boot;
# the DTB in vendor_boot, with the stock load addresses.
(cd "$work" && cpio -o -H newc --quiet < /dev/null > vendor_ramdisk.cpio)
$MKBOOTIMG --header_version 3 --vendor_boot vendor_boot.img --vendor_ramdisk "$work/vendor_ramdisk.cpio" \
    --dtb "$work/vendor-dtbs.bin" --vendor_cmdline "$VENDOR_CMDLINE" --pagesize 4096 \
    --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 --dtb_offset 0x01f00000
$MKBOOTIMG --header_version 3 --kernel "$KERNEL" --ramdisk "$INITRAMFS" --cmdline "$CMDLINE" \
    --os_version "$OS_VERSION" --os_patch_level "$OS_PATCH_LEVEL" -o boot.img

# dtbo: for each stock entry an overlay with the same matching properties
# (channel-id-map, model, compatible, msm-id, board-id, copied verbatim, with
# our compatibles in front) whose one fragment adds an empty property to
# /soc. Same table layout as the stock image.
(cd "$work" && python3 - "$STOCK_DTBO" "$NOOP_PROPERTY" <<'PY'
import struct, subprocess, sys
stock = open(sys.argv[1], 'rb').read(); noop = sys.argv[2]
magic, total, hsz, esz, cnt, eoff, page, ver = struct.unpack('>8I', stock[:32])
def raw(prop):
    v = subprocess.run(['fdtget', '-t', 'bx', 'stock-entry.dtbo', '/', prop],
                       capture_output=True, text=True, check=True).stdout.split()
    return ' '.join(f'{int(x, 16):02x}' for x in v)
blobs = []
for i in range(cnt):
    size, off, *ids = struct.unpack('>8I', stock[eoff + i * esz:eoff + (i + 1) * esz])
    open('stock-entry.dtbo', 'wb').write(stock[off:off + size])
    ours = ' '.join(f'{b:02x}' for b in b'motorola,rhodep\0qcom,sm6375\0')
    props = ''.join(f'\t{p} = [{(ours + " " if p == "compatible" else "") + raw(p)}];\n'
                    for p in ['channel-id-map', 'model', 'compatible', 'qcom,msm-id', 'qcom,board-id'])
    open('noop.dts', 'w').write('/dts-v1/;\n/plugin/;\n/ {\n' + props +
        '\n\tfragment@0 {\n\t\ttarget = <&soc>;\n\t\t__overlay__ {\n\t\t\t' + noop + ';\n\t\t};\n\t};\n};\n')
    subprocess.run(['dtc', '-q', '-@', '-I', 'dts', '-O', 'dtb', '-o', 'noop.dtbo', 'noop.dts'], check=True)
    blobs.append((open('noop.dtbo', 'rb').read(), ids))
data_off = hsz + esz * len(blobs); entries = b''; data = b''
for blob, ids in blobs:
    entries += struct.pack('>8I', len(blob), data_off + len(data), *ids); data += blob
open('dtbo.img', 'wb').write(
    struct.pack('>8I', magic, data_off + len(data), hsz, esz, len(blobs), hsz, page, ver) + entries + data)
PY
)
mv "$work/dtbo.img" dtbo.img

# AVB verification off (flags 2): the bootloader is unlocked, and boot and
# vendor_boot are yours now.
$AVBTOOL make_vbmeta_image --output vbmeta.img --flags 2 --rollback_index "$ROLLBACK_INDEX"

sha256sum boot.img vendor_boot.img dtbo.img vbmeta.img > SHA256SUMS
ls -la boot.img vendor_boot.img dtbo.img vbmeta.img
echo "packed in $PWD: flash with flash-slot.sh"
