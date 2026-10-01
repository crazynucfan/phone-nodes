#!/usr/bin/env bash
# Check a device's build artifacts before they can be published.
#
#   scripts/check-artifacts.sh <device> <outdir>
#
# <outdir> is what scripts/build.sh wrote (out/<device> in CI): Image.gz, the
# DTB, config, kernel.release and debs/. The checks encode what the phones need
# to boot a package with kexec and fall back safely (see the negroni bring-up
# notes): required config options (<device>/required-config), a sane arm64
# Image header whose size fits the kexec placement window, a package with the
# files the kexec tooling reads from /boot, and a DTB hash against
# <device>/dtb.sha256, because a changed DTB means the kexec loader must carry
# the bootloader's fixups over instead of reusing the running device tree.
# Everything but the DTB comparison is fatal.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dev=${1:?device}
out=${2:?artifact directory}
# shellcheck source=/dev/null
. "$here/$dev/build.env"

fail=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*" >&2; fail=1; }
warn() { echo "WARN  $*" >&2; }

rel=$(cat "$out/kernel.release")
dtb_name=$(basename "$DTB")
echo "checking $dev artifacts for $rel in $out"

for f in Image.gz "$dtb_name" config System.map; do
    [ -s "$out/$f" ] && ok "$f present" || bad "$f missing from $out"
done

# --- kernel config ---------------------------------------------------------
# <device>/required-config: one CONFIG line per entry, as .config writes it;
# "CONFIG_X=m|y" accepts either, "# CONFIG_X is not set" requires it off.
if [ -f "$here/$dev/required-config" ]; then
    while IFS= read -r want; do
        case $want in ''|'#!'*) continue ;; esac
        if [[ $want =~ ^(CONFIG_[A-Z0-9_]+)=m\|y$ ]]; then
            sym=${BASH_REMATCH[1]}
            grep -Eq "^$sym=(m|y)$" "$out/config" && ok "$sym is m or y" || bad "$sym: wanted m or y, have: $(grep -E "^(# )?$sym( |=)" "$out/config" || echo unset)"
        elif [[ $want =~ ^\#\ (CONFIG_[A-Z0-9_]+)\ is\ not\ set$ ]]; then
            sym=${BASH_REMATCH[1]}
            grep -Eq "^$sym=" "$out/config" && bad "$sym: wanted off, have: $(grep -E "^$sym=" "$out/config")" || ok "$sym is off"
        else
            grep -Fxq "$want" "$out/config" && ok "$want" || bad "$want: have: $(grep -E "^(# )?${want%%=*}( |=)" "$out/config" || echo unset)"
        fi
    done < "$here/$dev/required-config"
else
    warn "no $dev/required-config, config not checked"
fi

# --- arm64 Image header ------------------------------------------------------
# The kexec loader keeps every segment in one hole low in RAM (74 MiB at
# 0x80d00000 on negroni): kernel image_size + initramfs + dtb must fit, so
# each device's build.env budgets the kernel (KEXEC_KERNEL_MAX_MIB) and the
# initramfs gets the rest.
max_mib=${KEXEC_KERNEL_MAX_MIB:-44}
img=$(mktemp); trap 'rm -f "$img"' EXIT
if gzip -dc "$out/Image.gz" > "$img" 2>/dev/null; then
    magic=$(od -An -tx1 -j 56 -N 4 "$img" | tr -d ' ')
    text_offset=$(od -An -tx8 -j 8 -N 8 "$img" | tr -d ' ')
    image_size=$(( 16#$(od -An -tx8 -j 16 -N 8 "$img" | tr -d ' ') ))
    [ "$magic" = 41524d64 ] && ok "Image header magic ARM\\x64" || bad "Image header magic not ARM64: $magic"
    [ "$text_offset" = 0000000000000000 ] && ok "text_offset 0" || warn "text_offset $text_offset (kexec-tools handles it, but check)"
    echo "      Image.gz $(stat -c %s "$out/Image.gz") bytes, uncompressed $(stat -c %s "$img"), image_size (incl. bss) $image_size"
    if [ "$image_size" -le $(( max_mib * 1024 * 1024 )) ]; then ok "image_size within the ${max_mib} MiB kexec budget"; else bad "image_size $image_size exceeds ${max_mib} MiB (KEXEC_KERNEL_MAX_MIB): the kexec loader's low-memory hole cannot hold kernel + initramfs"; fi
else
    bad "Image.gz does not gunzip"
fi

# --- device tree -----------------------------------------------------------
if [ -s "$out/$dtb_name" ]; then
    dtb_magic=$(od -An -tx4 -N 4 "$out/$dtb_name" | tr -d ' ')
    [ "$dtb_magic" = edfe0dd0 ] && ok "DTB magic" || bad "DTB magic wrong: $dtb_magic"
    sum=$(sha256sum "$out/$dtb_name" | cut -c1-64)
    echo "      $dtb_name sha256 $sum"
    if [ -f "$here/$dev/dtb.sha256" ]; then
        if [ "$sum" = "$(cut -c1-64 "$here/$dev/dtb.sha256")" ]; then
            ok "DTB unchanged since $dev/dtb.sha256"
        else
            warn "DTB differs from $dev/dtb.sha256: a kexec of this kernel must use the package DTB with the bootloader fixups carried over (phone-kexec-test fdt-diff); update $dev/dtb.sha256 when this is intended"
        fi
    else
        warn "no $dev/dtb.sha256 recorded"
    fi
    # <device>/required-dtb: compatible strings that must be present in the DTB
    # (matched in the blob's strings block; the DT tooling is not needed).
    if [ -f "$here/$dev/required-dtb" ]; then
        while IFS= read -r compat; do
            case $compat in ''|'#!'*) continue ;; esac
            grep -a -q -F "$compat" "$out/$dtb_name" && ok "DTB describes $compat" || bad "DTB lacks a node compatible with $compat"
        done < "$here/$dev/required-dtb"
    fi
fi

# --- packages --------------------------------------------------------------
shopt -s nullglob
imgdebs=( "$out"/debs/linux-image-"$rel"_*.deb )
metadebs=( "$out"/debs/"$META_PACKAGE"_*.deb )
[ ${#imgdebs[@]} = 1 ] && ok "one kernel package: $(basename "${imgdebs[0]}")" || bad "expected one linux-image-$rel package, found ${#imgdebs[@]}"
[ ${#metadebs[@]} = 1 ] && ok "one meta package: $(basename "${metadebs[0]}")" || bad "expected one $META_PACKAGE package, found ${#metadebs[@]}"
if [ ${#imgdebs[@]} = 1 ]; then
    listing=$(dpkg-deb -c "${imgdebs[0]}")
    for path in "boot/vmlinuz-$rel" "boot/config-$rel" "boot/System.map-$rel" "usr/lib/linux-image-$rel/$DTB" "lib/modules/$rel/modules.order"; do
        grep -q " \./$path$" <<< "$listing" && ok "package ships /$path" || bad "package lacks /$path"
    done
    ctrl=$(mktemp -d); dpkg-deb -e "${imgdebs[0]}" "$ctrl"
    grep -q 'postinst.d' "$ctrl/postinst" 2>/dev/null && ok "postinst runs /etc/kernel/postinst.d (initramfs-tools builds the initrd)" || bad "postinst does not run /etc/kernel/postinst.d"
    rm -rf "$ctrl"
fi
if [ ${#metadebs[@]} = 1 ]; then
    dpkg-deb -f "${metadebs[0]}" Depends | grep -q "linux-image-$rel" && ok "$META_PACKAGE depends on linux-image-$rel" || bad "$META_PACKAGE does not depend on linux-image-$rel"
fi

[ "$fail" = 0 ] && echo "all checks passed for $rel" || { echo "checks FAILED for $rel" >&2; exit 1; }
