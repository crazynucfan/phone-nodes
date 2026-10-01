#!/usr/bin/env bash
# Apply a device's patch series to a Linux tree.
#
#   scripts/apply.sh <device> <linux-tree> [<base>]
#
# <base> defaults to <device>/BASE (the upstream tag or commit the series was
# exported from). To rebase onto a newer kernel, pass that kernel's tag or
# commit instead; `git am -3` then stops at the first conflict for you to
# resolve (`git am --continue`), after which scripts/export.sh writes the
# refreshed series back.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dev=${1:?device, e.g. negroni}
tree=${2:?path to a linux git tree}
base=${3:-$(cat "$here/$dev/BASE")}

cd "$tree"
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    echo "fetching $base from kernel.org"
    git fetch --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$base" 2>/dev/null ||
        git fetch --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$base"
    # Fetching a tag by name only sets FETCH_HEAD; keep it as a tag here.
    git rev-parse -q --verify "$base^{commit}" >/dev/null ||
        git update-ref "refs/tags/$base" FETCH_HEAD
fi
git switch -c "$dev/$(date +%Y%m%d-%H%M%S)" "$base"
while read -r p; do
    [ -n "$p" ] || continue
    git am -3 "$here/$dev/patches/$p"
done < "$here/$dev/series"
echo "applied $(wc -l < "$here/$dev/series") patches on $(git rev-parse --short "$base^{commit}")"
