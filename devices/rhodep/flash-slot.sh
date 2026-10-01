#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# flash-slot.sh: put the images from pack-bootimg.sh on one slot of a
# Motorola moto g82 5G (rhodep) and switch to it. The other slot keeps stock
# Android and is never written.
#
#   flash-slot.sh check      # right phone, unlocked, images match SHA256SUMS
#   flash-slot.sh flash      # boot, vendor_boot, dtbo, vbmeta (and userdata)
#   flash-slot.sh activate   # make the slot active (flash leaves it active)
#   flash-slot.sh reboot
#   flash-slot.sh try <boot.img> [<vendor_boot.img>]   # reflash, fresh tries, boot
#   flash-slot.sh back       # make the other slot (stock Android) active again
#
# Environment:
#   SLOT             a or b (default b): the slot Linux goes on
#   FASTBOOT_SERIAL  the phone's serial; needed only with several devices
#   ROOT_IMAGE       a sparse root filesystem image to write to userdata
#                    (optional; flash then goes through fastbootd, see below)
#
# Run from the directory holding the images. The phone must be in fastboot:
# Volume down + Power, which works whatever Linux does. From Linux,
# `systemctl reboot --reboot-argument=bootloader` gets there too.
#
# Back up the slot's stock boot, vendor_boot, dtbo and vbmeta first; this
# script does not.
#
# userdata is shared by both slots: with ROOT_IMAGE, stock Android on the
# other slot will find a Linux filesystem there and offer a factory reset.
# Declining keeps the Linux root; accepting wipes it.
#
# Two fastboot quirks of this phone: a `fastboot boot` straight after
# `--set-active` drops the USB link, and cutting the output of a
# `fastboot oem` command short (piping it into head) wedged the link until
# the cable was replugged.
set -euo pipefail
slot=${SLOT:-b}
case $slot in a) other=b ;; b) other=a ;; *) echo "SLOT must be a or b" >&2; exit 2 ;; esac
fb() { fastboot ${FASTBOOT_SERIAL:+-s "$FASTBOOT_SERIAL"} "$@"; }
var() { fb getvar "$1" 2>&1 | sed -n "s/^$1: //p" | head -n1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

present() {
    if [[ -n ${FASTBOOT_SERIAL:-} ]]; then
        fastboot devices | grep -q "^$FASTBOOT_SERIAL" || { echo "phone $FASTBOOT_SERIAL not in fastboot" >&2; exit 1; }
    else
        [[ $(fastboot devices | grep -c .) == 1 ]] || { echo "need exactly one device in fastboot (or set FASTBOOT_SERIAL)" >&2; exit 1; }
    fi
}

check() {
    present
    [[ $(var product) == rhodep ]] || { echo "not a rhodep" >&2; exit 1; }
    [[ $(var securestate) == flashing_unlocked ]] || { echo "bootloader not unlocked" >&2; exit 1; }
    sha256 -c SHA256SUMS
    echo "current slot: $(var current-slot)"
    for s in a b; do
        echo "slot $s: successful=$(var slot-successful:_$s) unbootable=$(var slot-unbootable:_$s) retry=$(var slot-retry-count:_$s)"
    done
}

case ${1:-} in
check) check ;;
flash)
    check
    fb flash "boot_$slot" boot.img
    fb flash "vendor_boot_$slot" vendor_boot.img
    # The overlay that changes nothing: the bootloader refuses to boot
    # without a dtbo entry matching the board (pack-bootimg.sh explains).
    fb flash "dtbo_$slot" dtbo.img
    fb flash "vbmeta_$slot" vbmeta.img
    if [[ -n ${ROOT_IMAGE:-} ]]; then
        # The bootloader refuses to flash userdata ("flash permission
        # denied"); fastbootd writes it. fastbootd is the recovery of the
        # active slot, so make that stock Android's slot first, and ours
        # again afterwards.
        fb --set-active="$other"
        fb reboot fastboot
        for _ in $(seq 1 60); do [[ $(var is-userspace) == yes ]] && break; sleep 2; done
        [[ $(var is-userspace) == yes ]] || { echo "fastbootd did not come up" >&2; exit 1; }
        fb flash userdata "$ROOT_IMAGE"
        fb reboot bootloader
        for _ in $(seq 1 60); do [[ $(var is-userspace) == no ]] && break; sleep 1; done
    fi
    fb --set-active="$slot"
    echo "slot $slot written and active (retry $(var slot-retry-count:_$slot)); now: $0 reboot"
    ;;
activate) fb --set-active="$slot"; echo "current slot: $(var current-slot)" ;;
try)
    # Flash a boot image (and optionally a vendor_boot) and boot it.
    # set-active gives the slot fresh tries (7) and marks it not successful;
    # flashing alone does not always, and a slot with none left is marked
    # unbootable on the next boot. Linux has to mark the slot successful
    # once it is up (loader/qcom-slot-successful).
    boot=${2:?boot image}
    present
    fb flash "boot_$slot" "$boot"
    [[ -n ${3:-} ]] && fb flash "vendor_boot_$slot" "$3"
    fb --set-active="$slot"
    echo "slot $slot: retry=$(var slot-retry-count:_$slot) unbootable=$(var slot-unbootable:_$slot)"
    fb reboot
    ;;
reboot) fb reboot ;;
back) fb --set-active="$other"; echo "current slot: $(var current-slot)" ;;
*) sed -n '4,14p' "$0"; exit 2 ;;
esac
