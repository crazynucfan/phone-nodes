#!/usr/bin/env bash
# Write a device's series back from a Linux tree after a rebase.
#
#   scripts/export.sh <device> <linux-tree> <base>
#
# Exports every commit in <base>..HEAD, replaces <device>/patches and
# <device>/series, and records <base> in <device>/BASE: the tag's name when
# <base> is a tag (Renovate then proposes newer kernel.org tags, see
# renovate.json), otherwise the full commit.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dev=${1:?device}
tree=${2:?linux tree}
base=${3:?base commit or tag the series now applies to}

full=$(git -C "$tree" rev-parse "$base^{commit}")
rm -rf "$here/$dev/patches"
git -C "$tree" format-patch -q -o "$here/$dev/patches" "$full..HEAD"
for p in "$here/$dev/patches"/*.patch; do basename "$p"; done > "$here/$dev/series"
if git -C "$tree" rev-parse -q --verify "refs/tags/$base" >/dev/null; then
    echo "$base" > "$here/$dev/BASE"
else
    echo "$full" > "$here/$dev/BASE"
fi
echo "exported $(wc -l < "$here/$dev/series") patches on $(git -C "$tree" rev-parse --short "$full")"
