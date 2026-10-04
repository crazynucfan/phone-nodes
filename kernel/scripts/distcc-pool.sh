#!/usr/bin/env bash
# Find the distcc servers a build can trust.
#
#   scripts/distcc-pool.sh <dns-name>[,<dns-name>...] <jobs-per-server>
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
# Several names are tried in order, and the first with a usable server is the
# pool: the others are the same servers by another route, never more of them.
# CI names the servers' pod addresses first and their node addresses second,
# for a build that runs on a daemon outside the cluster, which resolves the
# first name but cannot reach what it resolves to.
#
# The test compiles without -g on purpose. A server compiles the source after
# local preprocessing, and gcc's debug info depends on what that loses
# (source columns inside macro expansions, the main file's name for
# -femit-struct-debug-baseonly): a remote object's code is the local one's,
# byte for byte, but its DWARF is not, and neither is the build-id computed
# over it.
set -euo pipefail
names=${1:?dns name}
jobs=${2:?jobs per server}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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
cc=(aarch64-linux-gnu-gcc -O2 -c ../probe.c)
mkdir "$tmp/local"
(cd "$tmp/local" && "${cc[@]}" -o local.o)

# Test one server, in a directory of its own ($tmp/<ip>): leaves `ok` there
# if it is usable, and otherwise the reason in `why`.
probe() {
    local ip=$1 d=$tmp/$1
    mkdir -p "$d/state"           # DISTCC_DIR; distcc does not create it
    # No fallback and no local retry: remote.o can only come from $ip.
    if (cd "$d" && DISTCC_HOSTS="$ip/1,lzo" DISTCC_DIR="$d/state" \
            DISTCC_FALLBACK=0 DISTCC_SKIP_LOCAL_RETRY=1 \
            timeout 60 distcc "${cc[@]}" -o remote.o) 2>"$d/err" &&
       cmp -s "$tmp/local/local.o" "$d/remote.o"; then
        : > "$d/ok"
    elif [ -e "$d/remote.o" ]; then
        echo "compiles differently (another gcc build?); not using it" > "$d/why"
    else
        echo "failed, not using it: $(tail -n1 "$d/err")" > "$d/why"
    fi
}

hosts=()
for name in ${names//,/ }; do
    addrs=$(getent ahostsv4 "$name" | awk '{ print $1 }' | sort -u || true)
    # All at once: a server that cannot be reached takes distcc four seconds
    # to give up on, and a pool out of reach is nothing but those.
    for ip in $addrs; do probe "$ip" & done
    wait
    hosts=()
    for ip in $addrs; do
        if [ -e "$tmp/$ip/ok" ]; then
            hosts+=("$ip/$jobs,lzo")
        else
            echo "distcc: $ip $(cat "$tmp/$ip/why")" >&2
        fi
    done
    echo "distcc: ${#hosts[@]} of $(wc -w <<<"$addrs") server(s) behind $name usable" >&2
    if [ ${#hosts[@]} -gt 0 ]; then break; fi
done
echo "${hosts[*]}"
