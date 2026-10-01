#!/usr/bin/env bash
# Find the distcc servers a build can trust.
#
#   scripts/distcc-pool.sh <dns-name> <jobs-per-server>
#
# Prints a DISTCC_HOSTS list (`<ip>/<jobs>,lzo ...`) of those addresses of
# <dns-name> whose server compiles a test file into exactly the object the
# local aarch64-linux-gnu-gcc makes. distcc never compares compilers itself,
# so a server with another gcc build would slip its objects into the kernel
# and into the shared ccache without a word. The test object carries the
# compiler's version string (.comment), so another gcc release fails it.
# Failing servers are reported on stderr and left out; printing nothing
# means compile locally.
#
# The test compiles without -g on purpose. A server compiles the source after
# local preprocessing, and gcc's debug info depends on what that loses
# (source columns inside macro expansions, the main file's name for
# -femit-struct-debug-baseonly): a remote object's code is the local one's,
# byte for byte, but its DWARF is not, and neither is the build-id computed
# over it.
set -euo pipefail
name=${1:?dns name}
jobs=${2:?jobs per server}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/state"                # DISTCC_DIR; distcc does not create it
cat > "$tmp/probe.c" <<'EOF'
struct s { int a; long b; };
long probe(const struct s *p, int n)
{
	long t = 0;
	for (int i = 0; i < n; i++)
		t += p[i].a * p[i].b;
	return t;
}
EOF
cc=(aarch64-linux-gnu-gcc -O2 -c probe.c)
(cd "$tmp" && "${cc[@]}" -o local.o)

addrs=$(getent ahostsv4 "$name" | awk '{ print $1 }' | sort -u || true)
hosts=()
for ip in $addrs; do
    rm -f "$tmp/remote.o"
    # No fallback and no local retry: remote.o can only come from $ip.
    if (cd "$tmp" && DISTCC_HOSTS="$ip/1,lzo" DISTCC_DIR="$tmp/state" \
            DISTCC_FALLBACK=0 DISTCC_SKIP_LOCAL_RETRY=1 \
            timeout 60 distcc "${cc[@]}" -o remote.o) 2>"$tmp/err" &&
       cmp -s "$tmp/local.o" "$tmp/remote.o"; then
        hosts+=("$ip/$jobs,lzo")
    elif [ -e "$tmp/remote.o" ]; then
        echo "distcc: $ip compiles differently (another gcc build?); not using it" >&2
    else
        echo "distcc: $ip failed, not using it: $(tail -n1 "$tmp/err")" >&2
    fi
done
echo "distcc: ${#hosts[@]} of $(wc -w <<<"$addrs") server(s) behind $name usable" >&2
echo "${hosts[*]}"
