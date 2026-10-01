<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Credits

The kernel series here stand on other people's work. Every file keeps the
copyright and licence notice it came with; this page says where each series
comes from and who wrote the code it was reduced from. The series themselves
say what was changed, and why, in their commit messages.

## negroni (OnePlus 10 Pro)

Patch 0001 is [withsalt/linux](https://github.com/withsalt/linux) branch
`7.3-rc2` at `05e876f60a30`, reduced to what a negroni build compiles, as one
commit so it can be rebased. That branch is Xlie Electronic Customs' SM8450
work plus WithSalt's own commits, on top of torvalds/linux `50d05c7c76c9`.

Authors of the 155 commits that branch adds to upstream, by commit count:

- Nazar Kompanets (ZXlieC) <xlie7669@gmail.com> — 132
- sarabpal-dev <sarabpal.maan@gmail.com>
- idusergod <artem.martyanov06@gmail.com>
- EYC <e@eyc.one>
- Teguh Sobirin <teguh@sobir.in>
- Gianni Spadoni <me@gio.blue>
- Vladimir Lypak <vladimir.lypak@gmail.com>
- Vldly
- Danila Tikhonov <danila@jiaxyga.com>
- Stanislav Zaikin <zstaseg@gmail.com>
- Jingyi Wang <jingyi.wang@oss.qualcomm.com>
- Qingqing Zhou <quic_qqzhou@quicinc.com>
- Akhil P Oommen <akhilpo@oss.qualcomm.com>
- WithSalt <sysrun@163.com>

Files in the patch also carry notices of Oplus (the OnePlus drivers it adapts,
released under GPL-2.0-only), NXP Semiconductors, Linaro and The Linux
Foundation. The panel driver was generated with
linux-mdss-dsi-panel-driver-generator from the vendor device tree.

## apollo (Xiaomi Mi 10T Pro)

Patch 0001 is royka1's
[postmarketOS port](https://gitlab.postmarketos.org/royka1/linux) branch
`apollo-7.1` at `71aebd11db5d`, reduced to what the node configuration
compiles and rebased onto v7.2.8.

Authors of the 215 commits that branch adds to v7.1, by commit count:

- royka1 <roykaandorp@gmail.com> — 140
- Jianhua Lu <lujianhua000@gmail.com> — 26
- Dawid Wróbel <me@dawidwrobel.com> — 11
- Xin Xu <xxsemail@qq.com> — 9
- map220v <map220v300@gmail.com>
- chalkin / silime <chalkin@yeah.net>
- bluebunny
- Teguh Sobirin <teguh@sobir.in>
- Tomasz Duda <tomaszduda23@gmail.com>
- domin746826 <ominek.pl91@gmail.com>
- Pangwalla <pangwalla@protonmail.com>
- Dmitry Baryshkov <lumag@kernel.org>
- d4n1 <d4n1.551@gmail.com>
- Nicola Guerrera <guerrera.nicola@gmail.com>
- Joel Selvaraj <jo@jsfamily.in>
- Casey Connolly <casey.connolly@linaro.org>
- Jun Nie <jun.nie@linaro.org>
- Arseniy Velikanov <me@adomerle.pw>
- Damillora <developer@damillora.com>
- Aelin Reidel <aelin@mainlining.org>

Drivers in the patch also name Caleb Connolly, Yassine Oudjana, Joel Selvaraj
and Teguh Sobirin as authors, and carry notices of Qualcomm Innovation Center,
The Linux Foundation and MontaVista Software.

## rhodep (Motorola moto g82 5G)

The rhodep patches are written for this series. What they build on:

- Register values, clocks, interrupts, reserved regions and PHY tables come
  from the Qualcomm and Motorola downstream kernel for SM6375 ("blair") and
  its rhodep device trees, as published in
  [LineageOS/android_kernel_motorola_sm6375](https://github.com/LineageOS/android_kernel_motorola_sm6375),
  and from the device tree the stock bootloader passes to Android. The UFS PHY
  tables turned out identical to upstream's SC7280/SM8150 ones, which is what
  0001 uses.
- 0003 (the rhodep device tree) follows the structure of upstream's
  `sm6375-sony-xperia-murray-pdx225.dts` by Konrad Dybcio
  <konrad.dybcio@somainline.org>.
- 0005 extends TI's bq256xx driver (Ricardo Rivera-Matos, Texas Instruments);
  the SGM41542 charge-voltage steps follow Motorola's downstream sgm4154x
  driver.
- 0008's finding that UFS works without ICE is from the postmarketOS rhodep
  port.
- 0009 reuses the in-kernel pd-mapper's SM6115 domain table (Linaro).
- 0010's CPU capacities and power coefficients are upstream kodiak.dtsi's
  (SC7280).
- 0012 to 0017 (the bpf error code, the kexec fixes in `qcom_glink_rpm`,
  `qcom_glink` and `qcom_rmtfs_mem`, and the lockup and pseudo-NMI options in
  the defconfig) are written for this series against upstream code. Their
  commit messages name no other source.
- The [MobileLinux](https://github.com/d4rks1d33/MobileLinux) rhodep port was
  consulted along the way.

## Upstream

Everything else is Linux itself, and the series only make sense on top of
the work of the upstream Qualcomm SoC maintainers and contributors
(linux-arm-msm), and of the postmarketOS community that keeps these phones
alive on mainline kernels.
