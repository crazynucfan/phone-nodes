#!/bin/bash
# Offline scenario tests (run: bash loader/tests/phone-kexec-loader.sh) for phone-kexec-loader, phone-kexec-bless and the
# kernel hooks: stubbed kexec, fake /boot, fake cmdline, state in a temp dir.
set -u
F=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PHONE_BOOT_STATE=$T/state PHONE_BOOT_RUN=$T/run PHONE_BOOT_BOOTDIR=$T/boot PHONE_BOOT_MODDIR=$T/modules
export PHONE_KEXEC_TEST=$T/stub-kexec PHONE_BOOT_PSTORE=$T/sys-pstore PHONE_BOOT_CONF=$T/phone-kexec.conf
mkdir -p $T/boot $T/modules
for r in good1 trial1 trial2; do : > /dev/null; echo x > $T/boot/vmlinuz-$r; echo x > $T/boot/initrd.img-$r; mkdir -p $T/modules/$r/kernel; done
cat > $T/stub-kexec <<'S'
#!/bin/sh
echo "$*" >> "$(dirname "$0")/kexec.log"
[ "$1" = load ] && [ "${STUB_LOAD_FAIL:-0}" = 1 ] && exit 1
[ "$1" = go ] && [ "${STUB_GO_FAIL:-0}" = 1 ] && exit 1
exit 0
S
chmod +x $T/stub-kexec
printf '#!/bin/sh\necho REBOOT >> "%s/kexec.log"\n' "$T" > $T/stub-reboot; chmod +x $T/stub-reboot
echo "console=tty0 earlycon rw" > $T/cmdline-abl; echo "console=tty0 rw" > $T/cmdline-kexec
fails=0
st() { tr '\n' ' ' < $PHONE_BOOT_STATE 2>/dev/null; }
last() { tail -n 2 $T/kexec.log 2>/dev/null | tr '\n' ' '; }
abl_boot() { rm -rf $T/run; : > $T/kexec.log; PHONE_BOOT_CMDLINE=$T/cmdline-abl PHONE_BOOT_RUNNING=loader bash $F/phone-kexec-loader >/dev/null; }
kexec_boot() { rm -rf $T/run; PHONE_BOOT_CMDLINE=$T/cmdline-kexec PHONE_BOOT_RUNNING=$1 bash $F/phone-kexec-loader >/dev/null; }
bless() { PHONE_BOOT_RUNNING=$1 PHONE_BOOT_HEALTH_CMD=$2 PHONE_BOOT_HEALTH_DEADLINE=0 PHONE_BOOT_HEALTH_INTERVAL=0 PHONE_BOOT_REBOOT_CMD=$T/stub-reboot bash $F/phone-kexec-bless >/dev/null; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: want [$3] got [$2]"; fails=$((fails+1)); fi; }

echo "## 1. empty state: stay on the loader kernel"
abl_boot; check "no kexec" "$(last)" ""
echo "## 2. new trial installed (postinst hook), bootloader boot kexecs it"
sh $F/zz-phone-kexec-trial trial1 >/dev/null
abl_boot; check "launch trial1" "$(last)" "load trial1 go "
check "state" "$(st)" "good= trial=trial1 tries=1 launched=trial1 strikes=0 "
echo "## 3. trial1 comes up healthy, bless promotes it"
kexec_boot trial1; bless trial1 true
check "good=trial1" "$(st)" "good=trial1 trial= tries=0 launched= strikes=0 "
echo "## 4. steady state: bootloader boot kexecs good"
abl_boot; check "launch good" "$(last)" "load trial1 go "
kexec_boot trial1; bless trial1 true
check "blessed again" "$(st)" "good=trial1 trial= tries=0 launched= strikes=0 "
echo "## 5. bad trial2 hangs twice (resets), then falls back to good"
sh $F/zz-phone-kexec-trial trial2 >/dev/null
abl_boot; check "try 1" "$(last)" "load trial2 go "
abl_boot; check "try 2 (no bless in between)" "$(last)" "load trial2 go "
abl_boot; check "tries used up -> good" "$(last)" "load trial1 go "
check "trial dropped" "$(st)" "good=trial1 trial= tries=0 launched=trial1 strikes=0 "
kexec_boot trial1; bless trial1 true
echo "## 6. trial that boots but stays unhealthy: bless reboots it"
sh $F/zz-phone-kexec-trial trial2 >/dev/null
abl_boot; kexec_boot trial2; : > $T/kexec.log; bless trial2 false; check "bless reboots" "$(last)" "REBOOT "
abl_boot; check "second try" "$(last)" "load trial2 go "
kexec_boot trial2; : > $T/kexec.log; bless trial2 false
abl_boot; check "falls back to good" "$(last)" "load trial1 go "
kexec_boot trial1; bless trial1 true
echo "## 7. good itself breaks: two strikes, then stay on the loader kernel"
abl_boot; check "good launch 1" "$(last)" "load trial1 go "
abl_boot; check "strike 1, launch 2" "$(last)" "load trial1 go "
check "strikes=1" "$(st)" "good=trial1 trial= tries=0 launched=trial1 strikes=1 "
abl_boot; check "strike 2 -> stay" "$(last)" ""
abl_boot; check "keeps staying" "$(last)" ""
echo "## 8. reset clears the strikes"
bash $F/phone-kexec-loader reset >/dev/null
check "after reset" "$(st)" "good=trial1 trial= tries=0 launched= strikes=0 "
abl_boot; check "launches good again" "$(last)" "load trial1 go "
kexec_boot trial1; bless trial1 true
echo "## 9. a new trial also gets through after strikes"
abl_boot; abl_boot; abl_boot
sh $F/zz-phone-kexec-trial trial2 >/dev/null
abl_boot; check "trial launched despite strikes" "$(last)" "load trial2 go "
kexec_boot trial2; bless trial2 true; check "trial blessed, strikes cleared" "$(st)" "good=trial2 trial= tries=0 launched= strikes=0 "
echo "## 10. hand-kexec'd kernel: bless never reboots it"
kexec_boot trial1; : > $T/kexec.log; bless trial1 false; check "no reboot" "$(last)" ""
echo "## 11. removed kernels are forgotten (postrm)"
sh $F/zz-phone-kexec-trial trial1 >/dev/null; sh $F/zz-phone-kexec-trial.postrm trial1
check "trial1 gone" "$(st)" "good=trial2 trial= tries=0 launched= strikes=0 "
rm -rf $T/boot/vmlinuz-trial2; abl_boot; check "good not installed -> stay" "$(last)" ""
check "good cleared" "$(st)" "good= trial= tries=0 launched= strikes=0 "
echo "## 12. staging failure stays on the loader kernel and records no launch"
sh $F/zz-phone-kexec-trial trial1 >/dev/null; : > $T/kexec.log; rm -rf $T/run
STUB_LOAD_FAIL=1 PHONE_BOOT_CMDLINE=$T/cmdline-abl PHONE_BOOT_RUNNING=loader bash $F/phone-kexec-loader >/dev/null
check "no go after failed load" "$(last)" "load trial1 "
check "no launch recorded, try refunded" "$(st)" "good= trial=trial1 tries=2 launched= strikes=0 "
echo "## 13. handover fails before the jump (go exits non-zero): try refunded"
: > $T/kexec.log; rm -rf $T/run
STUB_GO_FAIL=1 PHONE_BOOT_CMDLINE=$T/cmdline-abl PHONE_BOOT_RUNNING=loader bash $F/phone-kexec-loader >/dev/null
check "load and go were attempted" "$(last)" "load trial1 go "
check "no launch recorded, try refunded" "$(st)" "good= trial=trial1 tries=2 launched= strikes=0 "
echo "## 14. the previous kernel's pstore is kept on bootloader boots (newest few), not on kexec'd ones"
kept() { ls -d $T/pstore/*/ 2>/dev/null | wc -l | tr -d " "; }
mkdir -p $T/sys-pstore; printf '[   61.2] sysrq: Trigger a crash\n[   61.3] Kernel panic - not syncing: sysrq triggered crash\n\0\0' > $T/sys-pstore/console-ramoops-0
export PHONE_BOOT_PSTORE_KEEP=2
abl_boot; check "copied" "$(kept) $(cat $T/pstore/*/console-ramoops-0 | tr -d '\000' | tail -n 1)" "1 [   61.3] Kernel panic - not syncing: sysrq triggered crash"
check "logged how it ended" "$(grep -c "it ended with: Kernel panic - not syncing: sysrq triggered crash$" $T/log)" "1"
kexec_boot trial1; check "kexec'd boot keeps nothing" "$(kept)" "1"
abl_boot; abl_boot; check "only the newest 2 kept" "$(kept)" "2"
rm -f $T/sys-pstore/*; sh $F/zz-phone-kexec-trial trial1 >/dev/null; abl_boot; check "empty pstore: nothing kept, boot goes on" "$(kept) $(last)" "2 load trial1 go "
echo "## 15. with a FLAVOUR, other kernels (a distribution kernel apt pulled in) are never tried"
echo FLAVOUR=flav > $T/phone-kexec.conf
for r in 7.3.0-flav-ci1 6.12.111+deb13-rt-arm64; do echo x > $T/boot/vmlinuz-$r; echo x > $T/boot/initrd.img-$r; mkdir -p $T/modules/$r/kernel; done
printf 'good=7.3.0-flav-ci1\ntrial=\ntries=0\nlaunched=\nstrikes=0\n' > $PHONE_BOOT_STATE
sh $F/zz-phone-kexec-trial 6.12.111+deb13-rt-arm64 >/dev/null; check "hook ignores it" "$(st)" "good=7.3.0-flav-ci1 trial= tries=0 launched= strikes=0 "
printf 'good=7.3.0-flav-ci1\ntrial=6.12.111+deb13-rt-arm64\ntries=2\nlaunched=\nstrikes=0\n' > $PHONE_BOOT_STATE
abl_boot; check "loader drops a foreign trial, launches good" "$(last)" "load 7.3.0-flav-ci1 go "
check "trial cleared" "$(st)" "good=7.3.0-flav-ci1 trial= tries=0 launched=7.3.0-flav-ci1 strikes=0 "
printf 'good=6.12.111+deb13-rt-arm64\ntrial=\ntries=0\nlaunched=\nstrikes=0\n' > $PHONE_BOOT_STATE
abl_boot; check "foreign good: stay on the loader kernel" "$(last) $(st)" " good= trial= tries=0 launched= strikes=0 "
echo "## 16. rhodep's own marker: phone.loader, not earlycon, marks a bootloader boot"
rm -f $T/phone-kexec.conf
printf 'good=\ntrial=trial1\ntries=2\nlaunched=\nstrikes=0\n' > $PHONE_BOOT_STATE
echo "console=null phone.loader rw" > $T/cmdline-rhodep; : > $T/kexec.log; rm -rf $T/run
PHONE_BOOT_LOADER_MARK=phone.loader PHONE_BOOT_CMDLINE=$T/cmdline-rhodep PHONE_BOOT_RUNNING=loader bash $F/phone-kexec-loader >/dev/null
check "phone.loader boot launches the trial" "$(last)" "load trial1 go "
: > $T/kexec.log; rm -rf $T/run
PHONE_BOOT_LOADER_MARK=phone.loader PHONE_BOOT_CMDLINE=$T/cmdline-abl PHONE_BOOT_RUNNING=trial1 bash $F/phone-kexec-loader >/dev/null
check "earlycon alone is a kexec'd boot there" "$(last)" ""
check "kexec'd marker left for bless" "$(cat $T/run/kexec-booted 2>/dev/null)" "trial1"
echo "phoneXloader rw" > $T/cmdline-lookalike; : > $T/kexec.log; rm -rf $T/run
PHONE_BOOT_LOADER_MARK=phone.loader PHONE_BOOT_CMDLINE=$T/cmdline-lookalike PHONE_BOOT_RUNNING=trial1 bash $F/phone-kexec-loader >/dev/null
check "the marker matches literally" "$(cat $T/run/kexec-booted 2>/dev/null)" "trial1"
echo "## 17. FLAVOUR lists old and new names while a device's builds are renamed"
echo 'FLAVOUR="new flav"' > $T/phone-kexec.conf
for r in 7.3.0-new-ci2; do echo x > $T/boot/vmlinuz-$r; echo x > $T/boot/initrd.img-$r; mkdir -p $T/modules/$r/kernel; done
printf 'good=7.3.0-flav-ci1\ntrial=\ntries=0\nlaunched=\nstrikes=0\n' > $PHONE_BOOT_STATE
abl_boot; check "old-name good still launched" "$(last)" "load 7.3.0-flav-ci1 go "
kexec_boot 7.3.0-flav-ci1; bless 7.3.0-flav-ci1 true
sh $F/zz-phone-kexec-trial 6.12.111+deb13-rt-arm64 >/dev/null; check "foreign kernel still ignored" "$(st)" "good=7.3.0-flav-ci1 trial= tries=0 launched= strikes=0 "
sh $F/zz-phone-kexec-trial 7.3.0-new-ci2 >/dev/null; check "new-name kernel becomes the trial" "$(st)" "good=7.3.0-flav-ci1 trial=7.3.0-new-ci2 tries=2 launched= strikes=0 "
abl_boot; check "new-name trial launched" "$(last)" "load 7.3.0-new-ci2 go "
kexec_boot 7.3.0-new-ci2; bless 7.3.0-new-ci2 true; check "new name blessed" "$(st)" "good=7.3.0-new-ci2 trial= tries=0 launched= strikes=0 "
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
