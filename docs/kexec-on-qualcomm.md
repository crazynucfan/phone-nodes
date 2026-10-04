<!-- SPDX-License-Identifier: GPL-2.0-only -->
# kexec on Qualcomm phones: what it took

These are the problems we hit getting mainline kernels to kexec reliably on a
negroni (SM8450), a rhodep (SM6375) and an apollo (SM8250). Each entry gives the symptom,
the cause as far as we established it, and what `loader/phone-kexec-test` and
`loader/phone-kexec-dtb` now do about it. There was no UART; most of this came
from photos of the panel's console and from bisecting.

## Command line

**`earlycon` sends the kexec'd kernel to EDL.** The bootloader passes
`earlycon`, and kexec reuses `/proc/cmdline`. The new kernel faults into the
9008 download mode within seconds. *Fix:* strip `earlycon`, and `bootconfig`
with it, from the kexec'd command line.

## Remote processors

**The modem must be stopped first, and rmtfs must not hand its memory back.**
On negroni, with the modem running, or with the rmtfs shared memory returned
to the system, the modem boots again under the new kernel and the phone ends
in EDL. This happened three times. *Fix:* stop the modem's remoteproc first.
Leave rmtfs bound. The hand-back is behind `PHONE_KEXEC_RMTFS_HANDBACK=1` and
off by default. negroni's kexec'd kernel runs without rmtfs; that service
shows as failed there, and it is expected.

**On SM6375 the rmtfs region cannot be assigned twice.** The secure world
refuses every further assignment of the region (-EINVAL), even back to Linux,
so a hand-back cannot work there either. After a kexec the next kernel's
`qcom_rmtfs_mem` probe failed, rmtfs had no memory, the modem crashed reading
its file system, and the recovery hung the SoC. *Fix:* rhodep's patch 0016.
When the assignment is refused, the driver warns and uses the region as the
previous kernel left it, and does not try to give it back on remove. With it
the modem and Wi-Fi come up in the kexec'd kernel.

**Stop the other DSPs too**, through `/sys/class/remoteproc/*/state`. When the
loader runs at boot their modules may not be loaded yet, so every glob is
guarded. An empty glob killed the first loader run.

**Or never start them.** apollo's loader kernel has its DSP firmware built in
and boots the DSPs ~3.5 s into boot, so they are running, or still starting,
when the loader jumps. A node needs none of them there, so `qcom_q6v5_pas` is
never loaded (`devices/apollo/apollo-no-dsp.conf`), and the loader jumps from
a kernel with no DSP at all, which is what it was designed around.

## The display (SM8250)

**A jump with the panel on resets the phone.** apollo's loader kernel has the
msm display driver built in and the console on the panel. Every kexec while
the panel was lit reset the phone at once: nothing in pstore, no shutdown in
the journal. Every kexec after console blanking had turned it off worked. The
cause is most likely the display engine still scanning out through the SMMU
while the next kernel takes the memory and the SMMU over. *Fix:*
`PHONE_KEXEC_DISPLAY_OFF=1`: `phone-kexec-test go` first writes 4 (power down)
to `/sys/class/graphics/fb*/blank`, which turns the CRTC off through DRM, as
console blanking does. negroni and rhodep do not need it.

## An older device tree under newer kernels

**The loader kernel's tree is not the kexec'd kernel's.** On negroni and
rhodep the loader kernel is built from the same series, so the running tree
(the bootloader's, with its fixups) suits the kexec'd kernel. apollo's loader
kernel is a 7.1 build; the series' 7.2 tree differs in the PCIe `iommu-map`
cells and moved the USB-C VBUS supply to the connector node. *Fix:*
`PHONE_KEXEC_DTB_BASE=package`: `phone-kexec-dtb` starts from the kernel
package's DTB and copies in the running tree's memory nodes, the one fixup
the new kernel needs (kexec writes `/chosen`). `phone-kexec-test fdt-diff
<release>` shows what differs. Xiaomi's bootloader-modified tree also
defeats `fdtget -l /`, which stops after the first two root nodes, so the
memory nodes are found through `/proc/device-tree`.

## Serial engines

**GPI "EV ALLOCATE" errors in the new kernel.** The GENI I2C/SPI controllers
keep their GPI DMA channels allocated across the jump. *Fix:* unbind
`geni_i2c`, `geni_spi` and `spi_geni_qcom` devices before the kexec.

## The GIC's LPI tables

**The next kernel faults or loses interrupts through the ITS.** On GICv3 with an
ITS, the LPI property and pending tables cannot be disabled once enabled. The
new kernel finds them enabled and reuses the addresses the previous kernel
chose, which to it are ordinary free memory. *Fix:* `phone-kexec-dtb` builds
the kexec device tree from the running one (`/sys/firmware/fdt`) and adds
reserved-memory nodes for the running kernel's LPI property table, every CPU's
pending table and the ITS device and collection tables. It parses them from the
kernel log ("using LPI property table @…", "ITS@… allocated …"), and falls back
to the reservations already in the device tree in a kernel that was itself
kexec'd. SoCs without an ITS (SM6375) pass the running tree through unchanged.

**Use classic kexec with low placement.** `kexec_file_load` placed the initrd on
top of those tables. *Fix:* `kexec -c -l` (the kexec_load syscall) with
`--mem-max=0x7ffffffff` and the reserving DTB.

## Getting systemd to jump

**`systemctl kexec` does nothing.** The kubelet holds a logind shutdown
inhibitor. *Fix:* stop the cluster agent, run `k3s-killall.sh` if any pods are
running, then `systemctl start kexec.target
--job-mode=replace-irreversibly`.

**Stopping services from the early loader cancels their pending start jobs.**
*Fix:* stop only the units that are active.

## Watchdogs

**The APSS watchdog node sends negroni to EDL.** negroni's bootloader tree does
not describe the APSS watchdog. With `watchdog@17c10000` carried into the
kexec'd kernel's tree, that kernel went black and silent on two launches in a
row, which fits EDL. We did not bisect probe versus bark interrupt versus the
counter; the watchdog may belong to the secure side on this phone. negroni's
series described the node for a while and no longer does: a boot image built
from a DTB with the node would hit the same. `phone-kexec-dtb` can still carry
the node over from a package DTB that has one, behind
`PHONE_KEXEC_DTB_WATCHDOG=1` and off by default. The lesson stays: a watchdog
that the bootloader's tree does not describe may not be the kernel's to use,
so try it with someone at the phone.

**Where the watchdog works, mind its range.** rhodep's tree describes the APSS
watchdog. systemd on the loader kernel arms it, `KExecWatchdogSec` deliberately
keeps it armed across the jump, and the next kernel's `qcom_wdt` takes over the
watchdog the loader left armed, so a kexec'd kernel that hangs is reset. Two settings matter. The watchdog counts
to 31 s at most: a 2 min `RebootWatchdogSec` or `KExecWatchdogSec` fails and
leaves it disarmed, and 30 s works. And the new kernel pets the watchdog it
inherits until userspace opens it. `watchdog.open_timeout=180` on the kexec'd
command line ends that after 180 s, so a kernel stuck before userspace is
reset too.

## RPM-based SoCs (SM6375)

**A hard reset about 0.13 s into every kexec'd kernel,** around the SPMI
arbiter probe, plus "qcom_glink_rpm … unhandled rx cmd: 20". *Cause:*
`glink_rpm_probe()` zeroes the TX head and RX tail in message RAM. That is
right on a cold boot. After a kexec, though, the RPM's TX tail and RX head are
wherever the previous kernel left them. The RPM then parses stale FIFO bytes as
commands and takes the SoC down. *Fix:* rhodep's patch 0013 resumes both FIFOs
where the RPM left them: the TX head starts at the RPM's TX tail, and the RX
tail at the RPM's RX head.

**No RPM clocks, power domains or regulators in the kexec'd kernel.** With the
FIFOs resumed the kernel got past the reset but did not reach userspace: every
consumer of an RPM resource deferred forever. *Cause:* after a kexec the RPM's
glink link is still up. The RPM keeps its `rpm_requests` channel open under
the previous kernel's local channel id. It does not answer a new version
handshake, and it does not announce the channel again, so the new kernel never
gets an `rpm_requests` device. *Fix:* rhodep's patch 0014 takes the channel
over. When the FIFO indices show a previous user, it skips the version
handshake and registers `rpm_requests` as already open with local id 1. It
learns the RPM's id from the first data the RPM sends (2 on SM6375).
`qcom_glink_rpm.handover=` forces the choice: -1 auto, 0 no, 1 yes.

## Secondary CPUs

**A secondary CPU that takes no interrupt.** About 1 in 5 kexec'd kernels on
rhodep hung in their first 50 ms. CPU 6, the first Cortex-A78, came up and
then took no interrupt at all, so the first cross-CPU call waited forever.
*Fix:* pseudo-NMI. rhodep's patch 0017 builds it in
(`CONFIG_ARM64_PSEUDO_NMI`), and it only takes effect with
`irqchip.gicv3_pseudo_nmi=1` on the kexec'd command line. With it the hang did
not occur in 36 launches. We did not establish the cause. A plausible reading
is that pseudo-NMI rewrites the GIC priority mask on every interrupt enable.
`PHONE_KEXEC_OFFLINE_CPUS=1` was the diagnostic for this: it takes the
secondary CPUs offline a moment before the jump and reports how each powered
off. It is off by default, and it must stay off on negroni, where CPU hotplug
stalls storage I/O.

## Cilium needs kernel BTF

The Cilium releases that run on 7.2 and later kernels (1.19.8, and 1.20.2
onwards) need kernel BTF (`CONFIG_DEBUG_INFO_BTF`) on every node, for their
socket-LB programs. BPF masquerading needs it too: without BTF the verifier
rejects the program. `cilium-dbg status` said Ok on nodes whose datapath
initialisation was failing, so do not trust it alone. After a Cilium or kernel
change, start a fresh pod on each node and check that it has network.

## Bisecting an early death

When the kexec'd kernel dies before anything is visible, put
`initcall_blacklist=<initcall>` or `module_blacklist=<module>` on its command
line and move the suspect around. The SM6375 death survived blacklisting the
SPMI arbiter and went away with `glink_rpm_init` blacklisted. `boot_delay=`
(with `CONFIG_BOOT_PRINTK_DELAY`) slows the console enough to photograph the
last lines.

## pstore

**The saved console survives a hard reset only in part.** After a panic (hard
reset, not warm), about 20% of the bytes of the ramoops console record on a
negroni were wrong, and about 93% of the errors were single bits falling from 1
to 0. DRAM is not refreshed during the reset. The text is still readable by
eye. Ramoops' Reed-Solomon ECC corrects at most 63 bad bytes per 255-byte
codeword even at the maximum parity, so it cannot repair this. If the zone
header's signature decays, ramoops discards the record, and pstore simply looks
empty. A warm reset keeps DRAM refreshed, but on negroni a warm reboot leaves
the phone dead until a forced power-on, so this depends on the device.

**systemd-pstore races the loader.** It moves the record out of
`/sys/fs/pstore` about 40 ms into boot, and the next boot archives its own
console under the same file name. *Fix:* the loader unit runs
`Before=systemd-pstore.service` and keeps its own copy.

## Lockup drills

With the lockup detectors set to panic, `test_lockup` (`CONFIG_TEST_LOCKUP=m`)
turns each failure mode into a drill. On a negroni each one panicked, reset,
went back through the loader into the same kernel and was blessed again, in
about 3 minutes and with no one touching the phone:

| Drill | Parameters | Caught by |
|---|---|---|
| soft lockup | `time_secs=90 disable_preempt=1` | "watchdog: BUG: soft lockup" at ~46 s |
| hard lockup | `time_secs=30 disable_irq=1` | the buddy detector (`watchdog_hardlockup_check`) |
| hung task | `time_secs=260 state=D` | `khungtaskd`, "hung_task: blocked tasks" |
| crash | `echo c > /proc/sysrq-trigger` | `panic=10` |

A 40 s soft lockup did *not* panic. The RCU stall report at 21 s resets the soft
lockup timer, so the detector only fires about 20 s later. Hence
`kernel.panic_on_rcu_stall = 1`: a CPU stuck like that reboots at 21 s. The hard
lockup detector runs in buddy mode, the CPUs watching each other's timer
interrupts. negroni's kernels have no pseudo-NMI for the perf-based one.
rhodep's use the buddy detector as well, and their pseudo-NMI adds NMI
backtraces to its reports.
