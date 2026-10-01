#!/usr/bin/env bash
# Fetch a device's upstream base into a new source tree.
#
#   scripts/fetch.sh <device> <src-dir>
#
# Creates <src-dir> (which must not exist) as a shallow git checkout of
# <device>/BASE from kernel.org: a commit, or a tag from Linus's tree or the
# stable tree (v7.3, v7.3.2). A tag also becomes a local tag in <src-dir>, so
# build.sh can resolve it. The Dockerfile runs this in its own stage so
# BuildKit caches the tree for as long as BASE does not change.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dev=${1:?device}
src=${2:?source directory}
base=$(cat "$here/$dev/BASE")

if [ -e "$src" ]; then
    echo "$src already exists; refusing to overwrite it" >&2
    exit 1
fi
git init -q "$src"
git -C "$src" fetch -q --depth=1 \
    https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$base" 2>/dev/null ||
    git -C "$src" fetch -q --depth=1 \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$base"
git -C "$src" rev-parse -q --verify "$base^{commit}" >/dev/null ||
    git -C "$src" update-ref "refs/tags/$base" FETCH_HEAD
git -C "$src" checkout -q FETCH_HEAD
echo "fetched $(git -C "$src" rev-parse --short HEAD) into $src"
