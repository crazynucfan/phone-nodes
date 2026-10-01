<!-- SPDX-License-Identifier: GPL-2.0-only -->
# apollo: Xiaomi Mi 10T Pro (M2007J3SG, SM8250)

The series in `kernel/apollo/` applies to v7.2.8. It is one patch, reduced
from royka1's postmarketOS port (branch apollo-7.1 at 71aebd11db5d, see
CREDITS.md) to what a headless node needs. It builds
`qcom/sm8250-xiaomi-apollo.dtb` with `apollo_defconfig`, and kernels are
released as `<version>-apollo-<build>`.

**State:** the series builds and passes the artifact checks. It has not been
booted from one of these builds yet.

Notes from the bring-up plan:

- **The modem is left out.** It is an external SDX55 on PCIe; the port's PCIe
  changes that only serve the modem were dropped in the rebase to v7.2.8.
- **USB and Type-C are handled differently from negroni.** Type-C is the
  in-kernel TCPM on the PM8150B (PD sink and data-role swap in the device
  tree), not the ADSP, so charging plus USB host should need no recovery
  service. The USB port is high speed only.
- **Boot image:** not A/B. A header v2 boot image with the DTB appended, and
  the root filesystem on userdata. The dtbo partition has to be erased once.
- **Reboots must be warm (`reboot=warm`).** On this phone the secure firmware
  turns a PSCI reset into a power-off. The device tree reboots through PS_HOLD
  (a `qcom,pshold` restart node) instead. Without that, a reboot with the
  charger attached leaves the phone off. This is the opposite of negroni,
  where warm reboots are fatal: check per device.
- **Charge limit:** the PM8150B charger exposes only a writable
  `charging_enabled`, with no thresholds, so a charge limit needs a userspace
  toggle like negroni's.
