#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install the kexec loader on a phone running Debian (or a derivative).
#
#   loader/install.sh [--apply] [--enable] [--flavour <name>] [--mark <word>]
#
# Without --apply it only prints what it would do. --apply installs the
# scripts, units, kernel hooks and example configuration (existing files in
# /etc/default are left alone); --enable also enables the boot-time units, so
# the next bootloader boot kexecs the trial or good kernel. Enable it only
# once `phone-kexec-test load <release>` and `phone-kexec-test go` have
# brought a kernel up by hand, with someone at the phone. Read
# docs/kexec-loader.md first.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
apply=false enable=false flavour= mark=
while [ $# -gt 0 ]; do
    case $1 in
    --apply) apply=true ;;
    --enable) enable=true ;;
    --flavour) flavour=${2:?--flavour needs a device codename}; shift ;;
    --mark) mark=${2:?--mark needs a word}; shift ;;
    *) echo "usage: $0 [--apply] [--enable] [--flavour <name>] [--mark <word>]" >&2; exit 2 ;;
    esac
    shift
done

run() { echo "+ $*"; if $apply; then "$@"; fi; }
put() {  # put <src> <dest> <mode>
    echo "+ install -m $3 $1 $2"
    if $apply; then install -D -m "$3" "$1" "$2"; fi
}
keep() {  # keep <src> <dest>: example configuration, never overwritten
    if [ -e "$2" ]; then echo "  $2 exists, left alone"; else put "$1" "$2" 0644; fi
}

[ "$(id -u)" = 0 ] || ! $apply || { echo "run as root" >&2; exit 1; }

# kexec-tools must not take over every reboot: the loader decides.
echo "+ debconf: kexec-tools/load_kexec = false"
if $apply; then
    echo "kexec-tools kexec-tools/load_kexec boolean false" | debconf-set-selections
fi
run apt-get install -y kexec-tools device-tree-compiler curl

for f in phone-kexec-loader phone-kexec-bless phone-kexec-test phone-kexec-dtb; do
    put "$here/$f" "/usr/local/sbin/$f" 0755
done
put "$here/systemd/phone-kexec-loader.service" /etc/systemd/system/phone-kexec-loader.service 0644
put "$here/systemd/phone-kexec-bless.service" /etc/systemd/system/phone-kexec-bless.service 0644
put "$here/zz-phone-kexec-trial" /etc/kernel/postinst.d/zz-phone-kexec-trial 0755
put "$here/zz-phone-kexec-trial.postrm" /etc/kernel/postrm.d/zz-phone-kexec-trial 0755
run mkdir -p /var/lib/phone-boot

keep "$here/examples/phone-kexec" /etc/default/phone-kexec
keep "$here/examples/phone-boot" /etc/default/phone-boot
keep "$here/examples/90-phone-panic.conf" /etc/sysctl.d/90-phone-panic.conf
keep "$here/examples/no-debian-kernels" /etc/apt/preferences.d/no-debian-kernels
if [ -n "$flavour" ]; then
    echo "+ FLAVOUR=\"$flavour\" in /etc/default/phone-kexec"
    if $apply; then sed -i "s/^FLAVOUR=.*/FLAVOUR=\"$flavour\"/" /etc/default/phone-kexec; fi
fi
if [ -n "$mark" ]; then
    echo "+ PHONE_BOOT_LOADER_MARK=$mark in /etc/default/phone-boot"
    if $apply; then sed -i "s/^PHONE_BOOT_LOADER_MARK=.*/PHONE_BOOT_LOADER_MARK=$mark/" /etc/default/phone-boot; fi
fi

run systemctl daemon-reload
run systemctl restart systemd-sysctl
if $enable; then
    run systemctl enable phone-kexec-loader.service phone-kexec-bless.service
else
    echo "  boot-time units not enabled (--enable)"
fi
$apply || echo "(dry run: nothing was changed; --apply to install)"
