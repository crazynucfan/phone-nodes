#!/usr/bin/env bash
# Build a device's kernel from its patch series.
#
#   scripts/build.sh <device> <build-id> <out-dir>
#
# Fetches <device>/BASE from kernel.org, applies <device>/series, builds with
# <device>/build.env and writes the artifacts to <out-dir>:
#
#   Image.gz  <dtb>  lib/modules/<release>/  config  System.map
#   kernel.release  source.txt  debs/
#
# <build-id> becomes part of the kernel release (LOCALVERSION=-<build-id>).
# Every build must have its own: module versioning is off, so modules from
# another build with the same release would load and crash the kernel.
#
# Needs git, the aarch64-linux-gnu cross toolchain and the usual kernel build
# dependencies; ccache is used when present.
#
# SRC names an existing source tree to build in. It must be a git checkout of
# exactly <device>/BASE, tag or commit (scripts/fetch.sh makes one; the
# Dockerfile caches it in its own stage) and is left in place afterwards. Without SRC a scratch
# tree is fetched and deleted again. OBJ overrides the scratch build
# directory, which is always deleted first and afterwards.
#
# DISTCC_POOL=<dns-name>[/<jobs-per-server>] also compiles on the distcc
# servers that name resolves to, those whose compiler matches the local one.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dev=${1:?device}
id=${2:?build id}
out=${3:?output directory}
case $id in *[!A-Za-z0-9._+-]*|'') echo "bad build id: $id" >&2; exit 2;; esac

# shellcheck source=/dev/null
. "$here/$dev/build.env"          # DEFCONFIG, DTB
obj=${OBJ:-/tmp/phone-kernel-obj}
base=$(cat "$here/$dev/BASE")
if [ -n "${SRC:-}" ]; then
    src=$SRC
    own_src=false
    head=$(git -C "$src" rev-parse HEAD 2>/dev/null || true)
    want=$(git -C "$src" rev-parse -q --verify "$base^{commit}" || true)
    if [ -z "$want" ] || [ "$head" != "$want" ]; then
        echo "SRC=$src is at ${head:-no commit}, not BASE $base; not touching it" >&2
        exit 1
    fi
else
    src=/tmp/phone-kernel-src
    own_src=true
    rm -rf "$src"
    "$here/scripts/fetch.sh" "$dev" "$src"
fi
rm -rf "$obj"
mkdir -p "$out"

while read -r p; do
    [ -n "$p" ] || continue
    git -C "$src" -c user.name=phone-kernel -c user.email=ci@phone-kernel.invalid \
        am -q -3 "$here/$dev/patches/$p"
done < "$here/$dev/series"

cc=aarch64-linux-gnu-gcc
command -v ccache >/dev/null && cc="ccache $cc"
jobs=$(nproc)
# DISTCC_POOL: compile on the distcc servers behind a DNS name as well (in CI,
# one per amd64 node). Only the compiler runs there; preprocessing, ccache,
# linking and packaging stay here, and so does every compile if no server
# matches the local compiler (distcc-pool.sh).
distcc_dir=
if [ -n "${DISTCC_POOL:-}" ]; then
    per=2                         # distcc's own default per server
    case $DISTCC_POOL in */*) per=${DISTCC_POOL#*/};; esac
    hosts=$("$here/scripts/distcc-pool.sh" "${DISTCC_POOL%%/*}" "$per") || hosts=
    if [ -n "$hosts" ]; then
        distcc_dir=$(mktemp -d)
        # --localslots bounds the compiles distcc falls back to running here
        # when a server drops out mid-build.
        export DISTCC_DIR=$distcc_dir DISTCC_HOSTS="--randomize --localslots=$jobs $hosts"
        if [ "${cc%% *}" = ccache ]; then export CCACHE_PREFIX=distcc; else cc="distcc $cc"; fi
        jobs=$((jobs + $(wc -w <<<"$hosts") * per))
    fi
fi
m=(make -C "$src" O="$obj" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="$cc"
   LOCALVERSION="-$id" KBUILD_BUILD_USER=phone-kernel KBUILD_BUILD_HOST=ci)
"${m[@]}" -s "$DEFCONFIG"
"${m[@]}" -s -j"$jobs" Image.gz dtbs modules
rel=$("${m[@]}" -s kernelrelease)
"${m[@]}" -s INSTALL_MOD_PATH="$out" INSTALL_MOD_STRIP=1 modules_install
rm -f "$out/lib/modules/$rel/build" "$out/lib/modules/$rel/source"

cp "$obj/arch/arm64/boot/Image.gz" "$obj/System.map" "$out/"
cp "$obj/arch/arm64/boot/dts/$DTB" "$out/"
cp "$obj/.config" "$out/config"
echo "$rel" > "$out/kernel.release"

# Debian packages. The version is the kernel version with "-rcN" turned into
# "~rcN" (so release candidates sort before the release) plus the build id,
# e.g. 7.3.0~rc2+ci12. linux-image-<release> comes from the kernel's own
# bindeb-pkg, without the headers and debug packages; the linux-libc-dev it
# always builds is dropped so it can never shadow Debian's. META_PACKAGE
# depends on that exact image, so `apt upgrade` follows the newest build.
kver=$("${m[@]}" -s kernelversion)
debver="${kver/-/\~}+$id"
# dpkg-buildpackage writes next to the build directory. Remove only the exact
# files this build produces there, so a shared parent (e.g. /tmp) is safe.
debdir=$(dirname "$obj")
produced=("linux-image-${rel}_${debver}_arm64.deb" "linux-libc-dev_${debver}_arm64.deb"
          "linux-upstream_${debver}_arm64.buildinfo" "linux-upstream_${debver}_arm64.changes")
for f in "${produced[@]}"; do rm -f "${debdir:?}/$f"; done
DEB_BUILD_PROFILES="pkg.linux-upstream.nokernelheaders pkg.linux-upstream.nokerneldbg" \
    "${m[@]}" -s -j"$(nproc)" KDEB_PKGVERSION="$debver" KDEB_CHANGELOG_DIST=trixie bindeb-pkg
mkdir -p "$out/debs"
mv "$debdir/${produced[0]}" "$out/debs/"
for f in "${produced[@]}"; do rm -f "${debdir:?}/$f"; done

meta=$(mktemp -d)
mkdir -p "$meta/DEBIAN"
cat > "$meta/DEBIAN/control" <<EOF
Package: $META_PACKAGE
Version: $debver
Architecture: arm64
Maintainer: phone-nodes <ci@phone-nodes.invalid>
Section: kernel
Priority: optional
Depends: linux-image-$rel
Description: kernel for $dev from phone-nodes
 Depends on the newest phone-kernel build for this device, so installing
 upgrades follows it. Build $id of $(git -C "$src" rev-parse --short HEAD).
EOF
dpkg-deb --root-owner-group -Zxz --build "$meta" "$out/debs/${META_PACKAGE}_${debver}_arm64.deb" >/dev/null
rm -rf "$meta"

{
    echo "device: $dev"
    echo "release: $rel"
    echo "debian version: $debver"
    echo "base: $base ($(git -C "$src" rev-parse --short "$base^{commit}"))"
    echo "compiler: $(aarch64-linux-gnu-gcc --version | head -n1)"
    echo "packages:"
    for d in "$out"/debs/*.deb; do echo "  $(basename "$d") ($(du -h "$d" | cut -f1))"; done
    echo "applied:"
    git -C "$src" log --format='  %h %s' "$base^{commit}..HEAD"
} > "$out/source.txt"

rm -rf "$obj"
if [ -n "$distcc_dir" ]; then rm -rf "$distcc_dir"; fi
if $own_src; then rm -rf "$src"; fi
echo "built $rel"
