# i.MX6ULL Mini (NAND) Linux 内核移植方案

## 1. 概述

本文档记录在 `imx6ull_mini_linux`（Linux 6.12.49）中实施与 `imx6ull_mini_uboot`（U-Boot 2025.04）一致的板级移植方案，覆盖：

- 板级内核配置（defconfig）
- 板级设备树（DDR、LCD、网络、NAND 分区、外设冲突）
- 内核驱动适配（LCD 复位）
- 构建脚本 `build.sh`
- 与 U-Boot `tftp_update` 配套的产物发布

目标平台为正点原子 i.MX6ULL Mini 开发板，NAND 启动，根文件系统为 UBIFS。

## 2. 硬件与启动链

| 项目 | 配置 |
|---|---|
| SoC | NXP i.MX6ULL，Cortex-A7（ARMv7） |
| DDR3L | 256MB，起始地址 `0x80000000` |
| NAND | GPMI NAND，512MiB，`nand-on-flash-bbt`，minimum ECC |
| LCD | 4.3 寸 RGB888 屏（正点原子 ATK4384），31MHz，**800x480** 时序，60Hz（与 U-Boot 一致） |
| 以太网 | 仅 ENET2，RMII，PHY 地址 1，实板 RTL8201F（ID `001c.c816`），DTS 写死 `ethernet-phy-id001c.c816` |
| 调试串口 | UART1 / `ttymxc0`，115200 |
| 存储卡 | TF 卡：USDHC1，4 位，CD = GPIO1_IO19 |
| USB | USB OTG（OTG1，MiniUSB）+ USB HOST（OTG2）+ USB 串口（调试） |
| 人机接口 | 红色状态 LED（GPIO1_IO03）、有源蜂鸣器（GPIO5_IO01）、KEY0（GPIO1_IO18） |
| 现场总线 | CAN1（TJA1050）；UART3 经跳线选择 RS232/RS485/GPS |
| 模块接口 | ATK 模块（I2C2 + UART3）；摄像头接口（CSI，无传感器） |
| 本方案未启用 | WM8960 音频（走 USB 声卡）、AP3216C/ICM20608、SDIO WiFi、QSPI、USDHC2 |
| 启动方式 | NAND：U-Boot 从 `0x1400000` 读内核、`0x3400000` 读 DTB |

实测 U-Boot 启动日志与本表一致：

```text
DRAM:  256 MiB
NAND:  512 MiB
[*]-Video Link 0 (800 x 480)
Net:   eth1: ethernet@20b4000 [PRIME]
```

> NAND 容量以实机 `NAND: 512 MiB` 为准。早期文档按 256MiB 估算的
> rootfs 可用空间（184MiB）已作废，实际为 440MiB = `0x1B800000`。
>
> **DRAM 容量已确认是 256MiB**（U-Boot 启动日志 `DRAM: 256 MiB`，
> 来自 `imx_ddr_size()` 动态读取 MMDC 配置），因此设备树
> `memory@80000000 { reg = <0x80000000 0x10000000>; }`（256MiB）正确。
> 正点原子 Mini 核心板有 256MB/512MB 两个版本，本板是 256MB 版。
> 注意 `md.l 0x80000000 1` 读的是内存**内容**，不能判断容量；
> 要看容量应使用 U-Boot 的 `bdinfo` 命令或启动日志的 `DRAM:` 行。

U-Boot 加载地址与内核启动参数：

```text
loadaddr   = 0x80800000
fdt_addr   = 0x83000000
tee_addr   = 0x84000000
rootfs_addr= 0x85000000
bootargs   = console=ttymxc0,115200 ubi.mtd=rootfs root=ubi0:rootfs \
             rootfstype=ubifs mtdparts=gpmi-nand:8m(boot),4m(env), \
             8m(logo),32m(kernel),16m(dtb),4m(tee),-(rootfs)
```

## 3. U-Boot 侧移植记录与对应措施

| U-Boot 提交 | 主要改动 | Linux 侧对应措施 |
|---|---|---|
| `5d1ba2bc` | 导入 U-Boot 2025.04 源码 | 以内核 6.12.49 为基线 |
| `c3a1cd08` | 增加 `Project.md`、`build.sh`、`imxdownload` | 新增内核侧 `build.sh`，结构与 U-Boot 脚本对齐 |
| `ddf4dbb4` | 增加 U-Boot 启动流程分析 | 本文档记录 Linux 启动链与分区 |
| `e94aebea` | NAND defconfig、DDR 256MB、LCD 时序、ENET2 单网口、PHY 地址 | 板级设备树 + 板级 defconfig |
| `4fd08895` | 优化 `build.sh`，修复启动打印 | 内核脚本采用耗时统计、错误捕获、`info` 命令 |
| `c0d1ef74` | NAND 分区调整为 8m/4m/32m/16m/4m/- | 设备树 `fixed-partitions` + 内核 `CONFIG_CMDLINE` |
| `7ba7986b` | 增加 logo 分区与 LOADLOGO/tftp logo | 分区表增加 `logo`，标签改为 `boot/env/logo/kernel/dtb/tee/rootfs` |
| `9c1abf72` | 增加 `tftp_update` 命令（kernel/dtb/rootfs） | `build.sh deploy` 输出同名文件，供 TFTP 更新 |
| `285a7eaa` | 最终版 `build.sh`（环境变量覆盖、错误处理、耗时统计） | `build.sh` 按相同结构重写 |
| `536ab5d9` | 实板 PHY 实测为 RTL8201F，修正 DT/驱动分支 | DTS 写 `ethernet-phy-id001c.c816`，保留 `CONFIG_REALTEK_PHY` |

## 4. 总体设计

2026-11-07 起采用“最小设备树 + 裁剪内核”方案：

1. **设备树**不再继承 NXP EVK 的 `imx6ul-14x14-evk.dtsi`，直接基于 `imx6ull.dtsi`
   只描述本板实际硬件（内存、LCD、ENET2、GPMI NAND、USDHC1、USB、LED、BEEP）。
2. **defconfig** 由 `imx_v7_defconfig` 裁剪而来，只保留 i.MX6ULL 与本板驱动。
3. **驱动**只做必要适配：LCD 复位脉冲、FEC 与 busfreq 在 6ULL-only 配置下的
   链接保护；不再依赖 EVK dtsi 中的 74HC595/CAN 修复。
4. **构建脚本**统一编译、清理、配置、发布流程，产物命名与 U-Boot 环境变量一致。

## 5. 文件修改清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `arch/arm/configs/imx6ull_mini_nand_defconfig` | 新增 | 基于 `imx_v7_defconfig` 裁剪的板级配置 |
| `arch/arm/boot/dts/nxp/imx/imx6ull-14x14-evk_nand.dts` | 新增 | 独立最小设备树（只 include `imx6ull.dtsi`） |
| `arch/arm/boot/dts/nxp/imx/Makefile` | 修改 | 注册 `imx6ull-14x14-evk_nand.dtb` |
| `drivers/video/fbdev/mxsfb.c` | 未修改 | 上游原生支持 `enable-gpio`；本板按原理图确认不需要，DTS 不再提供该属性 |
| `drivers/net/ethernet/freescale/fec_main.c` | 修改 | 仅在 `CONFIG_SOC_IMX6Q` 下调用 i.MX6Q cpuidle 钩子 |
| `arch/arm/mach-imx/common.c` | 修改 | 为 i.MX6ULL 提供 DDR3/LPDDR2 频率切换空实现（busfreq 已禁用） |
| `build.sh` | 新增 | 内核构建脚本（对齐 U-Boot 最终版） |

生成的 dtb 文件名固定为 `imx6ull-14x14-evk_nand.dtb`，与 U-Boot 的 `dtb_file` 一致。

## 6. 设备树设计

> 2026-11-07 重构：板级 DTS 已改为独立最小设备树，直接 `#include "imx6ull.dtsi"`，
> 不再继承 `imx6ul-14x14-evk.dtsi`。6.3 节中基于 EVK dtsi 的 74HC595/CAN/音频修复
> 已随节点整体删除而不再适用，该节保留为问题分析记录；当前节点清单见 6.7。

### 6.1 内存

U-Boot 的 `imximage_256M.cfg` 将 DDR 配置为 256MB，设备树同步覆盖：

```dts
/ {
	memory@80000000 {
		device_type = "memory";
		reg = <0x80000000 0x10000000>;	/* 256MB */
	};
};
```

### 6.2 LCD 时序

正点原子 4.3 寸 ATK4384 屏参数（**hactive=800**，早期误写为 840，详见下方注意事项）：

```dts
&timing0 {
	clock-frequency = <31000000>;
	hactive = <800>;
	vactive = <480>;
	hfront-porch = <40>;
	hback-porch = <88>;
	hsync-len = <48>;
	vback-porch = <32>;
	vfront-porch = <13>;
	vsync-len = <3>;
};
```

LCD 的 RESET 接整板复位网络（LCD 接口 pin40 / 核心板 A40），与 MCU 共用
复位按键，软件不需要 GPIO 控制；`GPIO5_IO09` 实际是触摸屏 `CT_RST`，
本板未启用。详见 6.6 节。因此 `&lcdif` 里**没有** `enable-gpio`：

```dts
&lcdif {
	pinctrl-0 = <&pinctrl_lcdif_dat &pinctrl_lcdif_ctrl>;
	display = <&display0>;
	status = "okay";
};
```

> **注意（2026-11-10 已修正为 800）**：屏幕手册给出的权威时序为
> **800×480@60Hz、31MHz**：
>
> ```text
> 水平：显示区 800 + HSPW 48 + HBP 88 + HFP 40 = 976 tCLK
> 垂直：显示区 480 + VSPW 3 + VBP 32 + VFP 13 = 528 th
> 31MHz / (976 × 528) ≈ 60.1Hz
> ```
>
> U-Boot 共享的 `imx6ul-14x14-evk.dtsi` 里原来写成 `hactive = <840>`
> （把 hfront-porch 的 40 误加进了有效像素），帧率只有 57.8Hz、右侧 40 列被裁。
> 修正方式（两侧都直接改时序定义处）：
> - 内核：`imx6ull-14x14-evk_nand.dts` 的 `timing0 { hactive = <800>; }`；
> - U-Boot：直接改共享的 `arch/arm/dts/imx6ul-14x14-evk.dtsi` 的
>   `timing0 { hactive = <800>; }`（本仓库只构建本板 dtb，故直接改共享
>   dtsi；`imx6ul-14x14-evk` / `imx6ulz-14x14-evk` 会一并变成 800×480）。
> - logo 资源同步从 840×480 裁成 800×480（`fb_show_logo_line()` 里
>   `image.width = logo->width` 不按 `xres` 裁剪，840 宽会越界写坏画面）。
>
> **刷机必读（踩过的坑）**：U-Boot 的 logo 来自 **NAND 的 `logo` 分区**
> （`splashsource=nand` + `splashimage=0x8c000000` + `splashpos=m,m`），
> 不是编进 `u-boot-dtb.imx` 的。只执行 `tftp_update uboot` 而不执行
> `tftp_update logo`，NAND 里仍是旧的 840×480 图，与 800 宽面板不匹配：
>
> ```text
> video_splash_align_axis():  x = (panel - bmp) / 2 = (800-840)/2 = -20
> video_bmp_display():        start = fb + y*line_length + x*bpix/8
>                             = fb - 60   ← 负偏移，写到上一行末尾
> ```
>
> 结果就是整屏花屏。**改分辨率时 `uboot` 与 `logo` 必须一起刷**。
> 快速验证是否为此原因：U-Boot 里 `setenv splashpos=0,0; saveenv; reset`，
> 若图片能显示（只是右侧被裁）即证实。

### 6.3 网络

板上只有一个网口（ENET2），禁用 ENET1 及其 PHY：

```dts
&fec1 {
	status = "disabled";
	/delete-property/ phy-handle;
};

&ethphy0 {
	status = "disabled";
};
```

ENET2 配置：`phy-mode = "rmii"`、`phy-handle = <&ethphy1>`、PHY 地址 1、
`compatible = "ethernet-phy-ieee802.3-c22"` 与 `rmii-ref` 时钟。
C22 让 `fwnode_get_phy_id()` 返回 `-EINVAL`，走 `get_phy_device()` 按 MDIO
实读 reg2/3（本板 `0x001cc816`），再命中 `CONFIG_REALTEK_PHY` 的
`PHY_ID_MATCH_EXACT(0x001cc816)` → "RTL8201F Fast Ethernet"。换料时只要有
对应 PHY 驱动，DTS 与 defconfig 都不必改。

**PHY 硬件复位（网口不通的真正根因）**：正点原子把 `ENET2_RST` 接在
`SNVS_TAMPER8 = GPIO5_IO08`（低有效），而 NXP EVK 把这根脚给了
`spi-gpio` + `74HC595` 的 `enable-gpios`。`gpio-74x164.c:125` 的
`devm_gpiod_get_optional(&spi->dev, "enable", ...)` 会占用它：

- 不配复位属性时，PHY 可能停在复位态 → MDIO 全 `0xFFFF`
  （`phydump eth0 1` 的 reg0~7 全 `0xFFFF`、地址 0~7 全无响应）→
  `Unable to connect to phy` / `NO-CARRIER`；
- 只配 `phy-reset-gpios` 时，`fec_reset_phy()`（`fec_main.c:4555`）申请
  `GPIO5_IO08` 拿到 `-EBUSY` → `fec_probe()` `goto failed_reset` →
  `eth0` 不注册 → `ifconfig eth0 up` 报 `No such device`。

**完整修复四处缺一不可**：

```dts
/* ① 禁用 EVK 的 spi-gpio + 74HC595 扩展（本板无此硬件） */
spi-4 {
	status = "disabled";
};

/* ② 删除 74HC595 的 enable-gpios = <&gpio5 8 GPIO_ACTIVE_LOW> */
/* ③ pinctrl_spi4 移除 SNVS_TAMPER8；pinctrl_enet2 增加该脚 */
pinctrl_enet2: enet2grp {
	fsl,pins = <
		/* ... MDC/MDIO/DATA/TX_CLK 等 */
		MX6UL_PAD_SNVS_TAMPER8__GPIO5_IO08	0x10B0
	>;
};

/* ④ 交给 fec_reset_phy() 管理复位 */
&fec2 {
	phy-reset-gpios = <&gpio5 8 GPIO_ACTIVE_LOW>;
	phy-reset-duration = <200>;
};
```

时序依据：`fec_main.c:4555` 的 `fec_reset_phy()` 早于 `4591` 的
`fec_enet_mii_init()`（其内部调用 `of_mdiobus_register()`），因此 MDIO 扫描
之前 PHY 一定已完成复位并释放；`fec_reset_phy()` 用 `GPIOD_OUT_HIGH` +
延时 + `gpiod_set_value(0)`，对 `GPIO_ACTIVE_LOW` 即「先拉低复位、延时、
再释放」。RTL8201F 手册要求复位脉宽 ≥ 10 ms，正点原子官方取 200 ms。

> 复位正常后，`ethernet-phy-ieee802.3-c22` 自动探测即可正常工作（复位在
> `of_mdiobus_register()` 之前完成，探测时一定能读到有效 ID），因此最终采用
> C22，不再写死型号。

> **`spi-4` 必须保留 `status = "okay"`**：本板 `reg_can_3v3` 用
> `gpios = <&gpio_spi 3 GPIO_ACTIVE_LOW>` 从 74HC595 取电，若把整个 `spi-4`
> 禁用，`gpio_spi` 不会注册，CAN 会报
> `regulator-can-3v3: can't get GPIO` 与
> `supplier regulator-can-3v3 not ready`。正确做法是保留节点、只删除
> 74HC595 的 `enable-gpios`（它才是抢占 `GPIO5_IO08` 的那一项）。
>
> **Mini 板无 WM8960**：dtsi 里 `sound-wm8960` / `codec`(`wm8960@1a`) /
> `&sai2` 默认 okay，但 Mini 底板没有该编解码器（ALPHA 才有），会产生
> `platform sound-wm8960: deferred probe pending: fsl-asoc-card:
> snd_soc_register_card failed`。板级 dts 已把它们全部 `status = "disabled"`。

### 6.4 NAND 与分区

GPMI 配置沿用 U-Boot 的 `imx6ull-14x14-evk-nand.dts`：

```dts
&gpmi {
	pinctrl-names = "default";
	pinctrl-0 = <&pinctrl_gpmi_nand_1>;
	status = "okay";
	nand-on-flash-bbt;
	fsl,use-minimum-ecc;
	...
};
```

分区表与 U-Boot `MFG_NAND_PARTITION` 完全一致：

| MTD 分区 | 起始地址 | 大小 |
|---|---|---|
| `boot` | `0x00000000` | 8MB |
| `env` | `0x00800000` | 4MB |
| `logo` | `0x00C00000` | 8MB |

`logo` 分区存放 U-Boot 开机 LOGO 的 24bpp BI_RGB BMP，由 U-Boot 启动时按 raw 读取；Linux 侧不使用该分区，换图命令见 U-Boot 移植记录第 5 章（`tftp_update logo`）。
| `kernel` | `0x01400000` | 32MB |
| `dtb` | `0x03400000` | 16MB |
| `tee` | `0x04400000` | 4MB |
| `rootfs` | `0x04800000` | 剩余空间：512MiB NAND 时为 440MiB = `0x1B800000` |

设备树中定义 `fixed-partitions` 作为无 `mtdparts` 时的后备。`CONFIG_MTD_CMDLINE_PARTS=y` 时 `cmdlinepart` 优先于 `ofpart`，正常启动由 U-Boot 传入的 `mtdparts` 接管，rootfs 按 `-(rootfs)` 自动取剩余空间（512MiB 板为 440MiB）。

`fixed-partitions` 无法表达「占满剩余空间」，后备值只能按 512MiB 实机容量写死；这是整个设计里唯一残留的容量假设，已集中为 `NAND_ROOTFS_SIZE`，换用其它容量 NAND 时必须同步修改。`boot` / `env` 标记为 `read-only`，避免 Linux 侧误擦 bootloader 与环境变量：

```dts
#define NAND_ROOTFS_SIZE 0x1b800000  /* 440MiB = 512MiB NAND - 72MiB 前置分区 */
partition@0 {
	label = "boot";
	reg = <0x00000000 0x00800000>;
	read-only;
};
...
partition@4000000 {
	label = "rootfs";
	reg = <0x04800000 NAND_ROOTFS_SIZE>;
};
```

### 6.5 外设引脚冲突

NAND 与 QSPI、USDHC2 复用引脚，必须禁用：

```dts
&qspi {
	status = "disabled";
};

&usdhc2 {
	status = "disabled";
};
```

### 6.6 LCD 复位与背光（2026-11-10 按底板原理图核对修正）

依据 `markdown/IMX6ULL_MINI_V2.2(Mini底板原理图).pdf`（5 页，Altium 导出），
LCD 40pin 接口（J10）的引脚分配为：

```text
pin40 = RESET    ← 来自核心板 A40，接整板复位网络（复位按键 KEY4、与 MCU 共用）
pin39 = CT_INT   ← 核心板 B15 = GPIO_9 = GPIO1_IO09，触摸中断，10K 上拉
pin38 = I2C2_SCL ← 核心板 B31 = UART5_TXD
pin36 = I2C2_SDA ← 核心板 B32 = UART5_RXD
pin35 = CT_RST   ← 核心板 A48 = SNVS_TAMPER9 = GPIO5_IO09，触摸复位，10K 上拉
pin34 = BLT_PWM  ← 核心板 B16 = GPIO_8 = GPIO1_IO08，背光
```

**原来两处错误**（早期误以为 `SNVS_TAMPER9 / GPIO5_IO09` 是 LCD 复位）：

1. U-Boot `setup_lcd()` 对 `IMX_GPIO_NR(5, 9)` 发 500us 低脉冲；
   U-Boot 的 `pinctrl_lcdif_ctrl` 里还把 `SNVS_TAMPER9__GPIO5_IO09` 塞进了
   LCD 控制引脚组。
2. 内核 `&lcdif` 里有 `enable-gpio = <&gpio5 9 GPIO_ACTIVE_HIGH>` +
   `pinctrl_lcdif_reset`（iomuxc_snvs 下复用为 GPIO5_IO09），
   `mxsfb.c` 会 `devm_gpio_request_one(..., GPIOF_OUT_INIT_LOW)` 后
   `udelay(500)` 再拉高。

这些动作实际是在**给电容触摸屏发复位脉冲**，不是 LCD。LCD 真正的 RESET
是上电时由整板复位电路一次性完成的，软件不需要（也不应该）再拉。
`CT_RST` 现在由 &i2c2 里 gt9xx 节点的 `reset-gpios` 正确驱动（见 6.6.2）。

**修正**：删除 U-Boot 的 GPIO5_IO09 复位脉冲和 `pinctrl_lcdif_ctrl` 里的
`SNVS_TAMPER9` 项；删除内核 `enable-gpio`、`&pinctrl_lcdif_reset` 引用及
`pinctrl_lcdif_reset` 定义。`mxsfb` 的 `of_get_named_gpio()` 取不到属性时
`gpio_is_valid()` 为假，整段跳过，驱动行为不受影响。

> 顺带核对（同样来自原理图，均与 DTS 一致）：
> `KEY0` = 核心板 B48 = `UART1_CTS`；`LED0` = B47 = `GPIO_3`；
> `BEEP` = B5 = `SNVS_TAMPER1`；`CSI_RESET` = B13 = `GPIO_2`；
> `CSI_PWDN` = B14 = `GPIO_4`；摄像头 P1 是 Header 9X2，含
> `CSI_DATA0~7` + HSYNC/VSYNC/PIXCLK/MCLK + PWDN/RESET + I2C2_SCL/SDA。

### 6.6.1 电容触摸屏（2026-11-10 按原理图补全）

4.3 寸 800x480 屏（正点原子屏 ID `0x04`）带电容触摸，触控 IC 为 Goodix
GT9xx 系列（GT9147 / GT1151 等），挂在 **I2C2**，与 OV5640 共用总线。
底板原理图只到 LCD 40pin 接口，触控 IC 在屏模组内，因此具体料号与
I2C 地址不能从底板 PDF 读出，按下述方式处理。

```text
I2C2_SCL / SDA : LCD pin38 / pin36 → 核心板 B31/B32 (UART5_TXD/RXD)
CT_INT         : LCD pin39         → GPIO1_IO09，底板 R18 10K 上拉（触摸时拉低）
CT_RST         : LCD pin35         → SNVS_TAMPER9 = GPIO5_IO09，R19 10K 上拉
VDD            : 底板 DCDC_3V3 直连，不可控
```

DTS 要点：

- `&i2c2` 合并为一个节点，同时挂 `gt9xx@14` 与 `ov5640@3c`（地址不冲突）。
- `pinctrl_tsc_int`（`MX6UL_PAD_GPIO1_IO09__GPIO1_IO09`）放在 `&iomuxc`；
  `pinctrl_tsc_reset`（`MX6ULL_PAD_SNVS_TAMPER9__GPIO5_IO09`）放在
  `&iomuxc_snvs`。**两者属不同 IOMUXC 域，不能合并到同一组**。
- `irq-gpios` + `reset-gpios` 必须同时提供：mainline `goodix.c` 只有
  在 `IRQ_PIN_ACCESS_GPIO` 模式下才会在 probe 时按 `reg` 主动把芯片
  配置成对应 I2C 地址（复位时序中拉高 INT 选 `0x14`、拉低选 `0x5D`），
  从而避免"教程写 0x5d 但实板在 0x14"这类地址不匹配。
- **两个 GPIO 的极性都必须是 `GPIO_ACTIVE_HIGH`（实测踩坑，2026-11-11）**。
  容易搞错的地方：硬件上 `CT_RST`/`CT_INT` 都是"低有效"（复位拉低、触摸拉低），
  但 `gpiod_direction_output()` 收的是**逻辑值**，驱动写的复位序列是
  `output(rst,0)` → 20ms → `output(rst,1)`（释放）。极性写成 `ACTIVE_LOW`
  会让物理电平整体反相，变成"先高后低"：

```text
ACTIVE_HIGH : output(rst,0)=物理低(复位) → output(rst,1)=物理高(释放)  ✅
ACTIVE_LOW  : output(rst,0)=物理高(不复位) → output(rst,1)=物理低(复位) ❌
```

  实测现象：写成 `ACTIVE_LOW` 时 `dmesg` 出现
  `Goodix-TS 1-0014: Invalid config (799, 479, 0), using defaults`，
  驱动把 `touchscreen-size-x/y` 的 800x480 覆盖成 `GOODIX_MAX_*`(4095)，
  触摸坐标范围错乱；改成 `ACTIVE_HIGH` 后该报错消失。
  树内 mainline 板子（`imx6q-kp`/`imx6ul-kontron-bl-43`/
  `imx6ul-ccimx6ulsbcpro`/`sun7i-a20-wexler`）也全部是 `ACTIVE_HIGH`。

> 注意区分两层，别混：
> - `irq-gpios`/`reset-gpios` 的 `ACTIVE_*` 是 **GPIOD 逻辑极性**，
>   影响 `gpiod_direction_output()` 的实际电平 → 必须 `ACTIVE_HIGH`；
> - `interrupts = <9 IRQ_TYPE_EDGE_FALLING>` 是 **中断触发沿**，
>   INT 空闲被 R18 上拉到高、触摸时芯片拉低 → 下降沿 → 保持 `FALLING`。
- `AVDD28-supply` / `VDDIO-supply` 是 `goodix.c` 的**强依赖**
  （`devm_regulator_get()` 非 optional），因此用 `reg_touch_3v3`
  （`regulator-fixed`、always-on、无控制 GPIO）显式提供，避免依赖
  regulator core 的 dummy 回退。
- 内核需开 `CONFIG_INPUT_TOUCHSCREEN=y` + `CONFIG_TOUCHSCREEN_GOODIX=y`
  （`INPUT`/`INPUT_EVDEV` 原本已开）。
- `compatible` 只用于匹配驱动，驱动会读芯片 ID 自动选择配置，
  GT9147/GT1151 都能工作。若上板 `dmesg` 报 `ENXIO`，把 `reg` 改成
  `<0x5d>`；若屏是 7 寸 FT5x06（地址 0x38），需换成
  `edt,edt-ft5206` 节点并开 `CONFIG_TOUCHSCREEN_EDT_FT5X06`。

上板验证：

```bash
i2cdetect -y 1                     # 应看到 0x14（或 0x5d）与 0x3c
dmesg | grep -i goodix
# 实测输出（极性修正后，2026-11-11）：
#   Goodix-TS 1-0014: ID 9147, version: 1040
#   input: Goodix Capacitive TouchScreen as .../input/input0
# 不再出现 "Invalid config (799, 479, 0), using defaults"
cat /proc/bus/input/devices        # 应出现触摸设备
evtest /dev/input/eventX           # 触摸应上报 ABS_MT_POSITION_X/Y

# 判断是否真的修好，看 ABS_MT_POSITION_X/Y 的 max：
#   799 / 479  → 正确
#   4095       → 仍走了 Invalid config 的兜底分支
```

> OV5640 的 endpoint 用 `bus-type=PARALLEL`，只保留 `bus-width`/`data-shift`
> 与同步极性；`clock-lanes`/`data-lanes` 是 MIPI CSI-2 属性，并行 DVP 上
> 属于误用，已删除。

### 6.6.2 USB OTG1_ID 与 USB 刷写（澄清）

底板上 `USB_OTG1_ID`（核心板 B51 = `GPIO_0`）到 Type-C 座之间串了一颗
`0R/NC` 电阻，丝印标注 **DNP（默认不贴）**，即 ID 引脚在运行时是悬空的。
这与"USB 能正常刷写程序"**不冲突**，两条路径互不相干：

| 场景 | 谁来初始化 USB | 是否依赖 OTG1_ID |
|---|---|---|
| 烧写/刷机 | Boot ROM 的 SDP，BOOT_MODE 进 Serial Downloader | **否**，ROM 强制 OTG1 为 device，不读 ID，也不经过 Linux DTS |
| Linux 运行时 | `chipidea` + `dr_mode="otg"` | 是，靠 ID 电平切 host/device；ID 悬空 + 内部上拉 → device |

因此 OTG 口可以照常烧写，但**不会自动切到 host**，接 USB 声卡/耳机不会枚举。
USB 耳机应接 **USB HOST 口（OTG2 = `usb@2184200`，`dr_mode="host"` 固定）**，
该口不受 ID 影响，插上即识别（内核已开 `SND_USB_AUDIO`）。

若以后确需让 OTG 口做 host：贴那颗 0R 电阻让 ID 接到连接器，或把
`dr_mode` 改成 `host`（后者会失去 device 模式与 USB 烧写能力，不推荐）。

### 6.7 最终节点清单（最小设备树）

DTS 直接 `#include "imx6ull.dtsi"`，编译后约 31KiB（精简前 37KiB）。

保留并启用的节点：

| 节点 | 关键配置 |
|---|---|
| `memory@80000000` | 256MiB |
| `&uart1` | 调试串口 `ttymxc0` |
| `&fec2` | RMII，PHY@1 `ethernet-phy-id001c.c816`（RTL8201F），`GPIO5_IO08` 复位 200ms |
| `&gpmi` | `nand-on-flash-bbt`、`fsl,use-minimum-ecc`、7 个分区 |
| `&lcdif` | 800x480/31MHz(60Hz)、24bit RGB888、`bits-per-pixel=32`、PWM1 背光(80%)、无 GPIO 复位 |
| `&pwm1` | 背光 PWM |
| `&usdhc1` | TF 卡，4bit，CD=`GPIO1_IO19`，`no-1-8-v` |
| `&usbotg1` / `&usbotg2` | USB OTG（MiniUSB）/ USB HOST |
| `&uart3` | RS232/RS485/GPS（底板跳线选择，UART3） |
| `&can1` | CAN1 / TJA1050（FLEXCAN1） |
| `&i2c2` | ATK 模块（MPU6050/手势）与摄像头模块 |
| `gpio-keys` | 功能按键 KEY0（GPIO1_IO18，低有效） |
| `&wdog1` | 看门狗 |
| `leds` / `beep` | `gpio-leds`（GPIO1_IO03）/ `gpio-beeper`（GPIO5_IO01，低电平响） |
| `&iomuxc_snvs` | ENET2 复位、LCD 复位、BEEP 三组 SNVS 引脚 |

明确删除（本板没有或当前不用）：

| 删除内容 | 原因 |
|---|---|
| `spi-4` / `74HC595` / `reg_can_3v3` | 正点原子 Mini 无 74HC595 扩展；CAN 改由固定 3.3V 供电，不需要该扩展 |
| `sound-wm8960` / `codec` / `&sai2` | Mini 无 WM8960 编解码器 |
| `&csi` / `ov5640` | 板上无摄像头传感器；接口保留，接模块时再启用 |
| `&can2` | 底板只有 1 路 CAN（CAN1） |
| `&qspi` / `&usdhc2` | 与 NAND 引脚复用；SDIO WiFi 在 NAND 启动时不可用 |
| `i2c1` / `AP3216C` / `ICM20608` | Mini 板未贴片；ATK 模块走 I2C2 |
| `&pxp`、GPU/VPU、DRM | 仅控制台/帧缓冲场景不需要 |

> 触摸屏（4.3 寸 GT9xx 系列）使用 I2C2 + `GPIO1_IO09`(CT_INT) /
> `SNVS_TAMPER9`/`GPIO5_IO09`(CT_RST)，已在 6.6.2 启用。
> 7 寸屏用 FT5x06（地址 0x38），需换 `edt-ft5x06` 节点与驱动。

## 7. 内核配置设计

### 7.1 基准选择

选择 `arch/arm/configs/imx_v7_defconfig`，而不是 `imx_v6_v7_defconfig`：

- i.MX6ULL 为 Cortex-A7（ARMv7）；
- `imx_v6_v7_defconfig` 包含 ARMv6 / i.MX5 等无关平台，内核体积和编译时间更大；
- `imx_v7_defconfig` 已包含本板所需驱动：`SOC_IMX6UL`、`MTD_NAND_GPMI_NAND`、`MTD_CMDLINE_PARTS`、`MTD_UBI`、`UBIFS_FS`、`FB_MXS`、`MICREL_PHY`、`SERIAL_IMX_CONSOLE`。

新 defconfig 中：

```text
# CONFIG_ARCH_MULTI_V6 is not set
CONFIG_ARCH_MULTI_V7=y
```

### 7.2 板级差异

在 `imx_v7_defconfig` 基础上增加的板级项（随后按 7.4 裁剪）：

```text
CONFIG_LOCALVERSION="-imx6ull-mini-nand"
CONFIG_CMDLINE="noinitrd console=ttymxc0,115200 ubi.mtd=rootfs root=ubi0:rootfs rootfstype=ubifs mtdparts=gpmi-nand:8m(boot),4m(env),8m(logo),32m(kernel),16m(dtb),4m(tee),-(rootfs)"
CONFIG_CMDLINE_FROM_BOOTLOADER=y
CONFIG_FEC=y
CONFIG_SMSC_PHY=y
CONFIG_MTD_UBI_BEB_LIMIT=20
```

> 上面 `CONFIG_CMDLINE` 在 defconfig 中为同一行，此处仅为排版显示。

说明：

- `CONFIG_CMDLINE_FROM_BOOTLOADER=y`：优先使用 U-Boot 传入的 `bootargs`；上面的 `CONFIG_CMDLINE` 仅作为后备；
- `REALTEK_PHY=y` 是实板 RTL8201F 的驱动（必须 built-in，FEC 早期 probe 时模块未加载）；
  `MICREL_PHY` / `SMSC_PHY` 保留作换料兼容；
- 关闭 `CONFIG_ARCH_MULTI_V6`，减少无关代码。

### 7.3 关键配置校验

| 配置项 | 状态 | 用途 |
|---|---|---|
| `CONFIG_SOC_IMX6UL` | `y` | i.MX6ULL SoC 支持 |
| `CONFIG_MTD_NAND_GPMI_NAND` | `y` | GPMI NAND 控制器 |
| `CONFIG_MTD_CMDLINE_PARTS` | `y` | 解析 U-Boot 传入的 `mtdparts` |
| `CONFIG_MTD_OF_PARTS` | `y` | 解析设备树 `fixed-partitions` |
| `CONFIG_MTD_UBI` | `y` | UBI 支持 |
| `CONFIG_UBIFS_FS` | `y` | UBIFS 根文件系统 |
| `CONFIG_FEC` | `y` | i.MX FEC 以太网 |
| `CONFIG_REALTEK_PHY` | `y` | 实板 RTL8201F PHY 驱动（0x001cc816） |
| `CONFIG_MICREL_PHY` | `y` | KSZ8081 换料兼容 |
| `CONFIG_SMSC_PHY` | `y` | LAN8720A 换料兼容 |
| `CONFIG_FB_MXS` | `y` | LCDIF framebuffer |
| `CONFIG_SERIAL_IMX_CONSOLE` | `y` | `ttymxc0` 控制台 |
| `CONFIG_CMDLINE_FROM_BOOTLOADER` | `y` | 使用 U-Boot 启动参数 |

### 7.4 内核裁剪（2026-11-07）

defconfig 从 630 行裁剪到 406 行，只保留 i.MX6ULL 与本板实际外设：

- **SoC**：只保留 `SOC_IMX6UL`，关闭 `SOC_IMX6Q/SL/SLL/SX`、`SOC_IMX7D/7ULP`、`SOC_VF610`；
- **模块**：当时定为 `CONFIG_MODULES=n`，全部驱动 built-in、不生成 `.ko`；
  **2026-11-10 起改为 `CONFIG_MODULES=y`**，见 7.5 节；
- **子系统**：关闭 `MEDIA_SUPPORT`（摄像头/V4L2）、`SND`（音频）、`BT`、
  `CFG80211`/`WLAN`、`DRM`、`OPTEE`/`TEE`、`MXC_GPU_VIV`/`MXC_VPU`；
- **进一步关闭**：`PM_DEBUG`/`PM_TEST_SUSPEND`（`USER_NS` 已于 2026-11-10
  重新开启，见下）、
  `CRYPTO_TLS`/`CRYPTO_AUTHENC`、`CRYPTO_DEV_SAHARA`/`CRYPTO_DEV_FSL_CAAM_SECVIO`；
- **调试/系统服务**：启用 `KEXEC`、`CGROUPS`/`NAMESPACES`（systemd）、
  `DYNAMIC_DEBUG`、`KPROBES`；`CRASH_DUMP`/`FTRACE` 按最新决定关闭；
- **MTD**：只保留 GPMI NAND，关闭 CFI/JEDEC/NOR、legacy `MTD_NAND_MXC`；
- **文件系统**：关闭 BTRFS/F2FS/XFS/GFS2/OCFS2/REISERFS/JFS/NILFS2/9P/CIFS/ISO9660/UDF；
- **按硬件使能**：`CAN`/`CAN_FLEXCAN`（TJA1050）、`KEYBOARD_GPIO`+`INPUT_EVDEV`（KEY0）、
  `SERIAL_IMX`（UART3）、`I2C_IMX`（I2C2）、`USB_ACM`/`USB_SERIAL`/`FTDI_SIO`、
  `USB_GADGET`+`USB_CONFIGFS`（ACM/Serial/Mass Storage/FunctionFS）、
  `HW_RANDOM`/`IMX_RNGC`、`VLAN_8021Q`、`MSDOS_FS`、`BINFMT_MISC`、`LIBCRC32C`、
  `NETFILTER`/iptables（filter/NAT/mangle）、`NF_TABLES`（nftables + NAT/CT/LOG/LIMIT/REJECT/COMPAT）、
  `IPV6`、`NFS`、`USB_STORAGE`；
- **新增**：`INPUT_GPIO_BEEPER=y`（蜂鸣器），`LEDS_TRIGGER_HEARTBEAT` 已有。
- **CMA（2026-11-11 起以设备树为准）**：大小改由板级 DTS 的
  `reserved-memory/linux,cma` 显式声明（16MiB），defconfig 只保留
  `CONFIG_CMA=y` + `CONFIG_DMA_CMA=y`，**不显式设**
  `CONFIG_CMA_SIZE_MBYTES`——DTS 有该节点时 Kconfig 的值会被忽略，
  避免"两处配置、不知道谁生效"。
- **`CONFIG_ARCH_FORCE_MAX_ORDER=10`**（imx_v7 原为 13）：13 会令
  `pageblock_nr_pages = 2^13 = 32MiB`，进而 `CMA_MIN_ALIGNMENT_BYTES=32MiB`，
  CMA 会被向上取整到 32MiB（`dmesg` 显示 `cma: Reserved 32 MiB`）。
  降到 10 后 pageblock=4MiB，16MiB 的 CMA 才能原样保留；
  i.MX6ULL 无 IPU/VPU/GPU，4MiB 最大连续分配已足够。
- **虚拟地址布局（2026-11-09）**：`VMSPLIT` 从 `imx_v7_defconfig` 的
  `2G/2G` 改回 `arch/arm/Kconfig` 默认的 `3G/1G`（`VMSPLIT_3G`），
  `PAGE_OFFSET` 由 Kconfig 推导为 `0xC0000000`（不再是 `0x80000000`）；
  本板物理内存只有 `0x80000000-0x8FFFFFFF` 共 256MiB，全部落在
  lowmem，用户态虚拟地址由 2GB 恢复到 3GB。
  > `PAGE_OFFSET` 是 Kconfig 推导符号，`savedefconfig` 不输出；若在已有
  > `.config` 上用 `scripts/config` 切换 VMSPLIT，`olddefconfig` **不会**
  > 重算它，必须显式 `--set-val PAGE_OFFSET 0xC0000000`，否则会出现
  > "3G 分割 + 0x80000000" 的错误组合。切换后必须完整重编译。
- **HIGHMEM/HIGHPTE 关闭**：板端 dmesg 一直是 `HighMem empty`、`0K highmem`，
  256MiB 全部在 lowmem，`CONFIG_HIGHMEM=y` 只是把 kmap 代码编进来空转；
  关掉后 `HIGHPTE`（`depends on HIGHMEM`）自动消失，`KMAP_LOCAL*` 也不再
  被 select。属于纯体积清理，对运行行为无影响。
- **SMP 保留，`NR_CPUS` 4→2**：i.MX6ULL 是单核 Cortex-A7，NXP 社区
  《i.MX6ULL EVK and Linux Kernel CONFIG_SMP》也承认单核无需 SMP；但
  `arch/arm/mach-imx/busfreq_ddr3.c` 有 10 处 `#ifdef CONFIG_SMP`，且
  `busfreq-imx.o`/`busfreq_ddr3.o`/`busfreq_lpddr2.o` 是无条件 `obj-y`，
  关 SMP 会走未验证的 `!SMP` 分支。为降低风险暂不关 SMP，只把
  `NR_CPUS` 从默认 4 降到 `range` 下限 2（`arch/arm/Kconfig` 的
  `NR_CPUS` 依赖 `SMP` 且最小为 2，写 1 会被判非法；关 SMP 后则由
  `include/linux/threads.h` 兜底为 1），减少 per-CPU 静态数组开销。
  `HOTPLUG_CPU`/`SMP_ON_UP`/`ARM_CPU_TOPOLOGY` 保持原样不变。
- **清理本板无硬件的驱动**：关闭 `FB_MXC_MIPI_DSI_SAMSUNG`、
  `FB_MXC_TRULY_WVGA_SYNC_PANEL`（并行 RGB 屏，无 MIPI-DSI）、
  `USB_XHCI_HCD`（6ULL 只有 ChipIdea EHCI）、`USB_HCD_TEST_MODE`（EHSET
  调试项）、`NFSD`（NFS 服务端；`NFS_FS`/`NFS_V3`/`NFS_V4` 客户端保留）。
  `FB_MXC` 父项**必须保留**——`mxsfb` 仍包含 `mxc/mxc_dispdrv.h` 并调用
  `mxc_dispdrv_gethandle()`；本板 DTS 无 `disp-dev` 属性，`mxsfb_dispdrv_init()`
  会在 `!strlen(host->disp_dev)` 时直接返回，故关掉屏驱动不影响 `/dev/fb0`。
  > **必须显式保留 `CONFIG_BACKLIGHT_CLASS_DEVICE=y`**：`drivers/video/backlight/Kconfig`
  > 把 `BACKLIGHT_PWM` 包在 `if BACKLIGHT_CLASS_DEVICE` 块内，而该框架原本
  > 只靠上面两个屏驱动 `select` 拉起。直接关屏驱动会让 PWM 背光被 Kconfig
  > 一并隐藏，LCD 背光失效。显式写一行即可解耦。

裁剪后实测（含 nftables/CGROUPS/Dynamic Debug）：

| 产物 | 裁剪前 | 裁剪后 |
|---|---|---|
| `zImage` | 9.4MiB | **7.0MiB** |
| `vmlinux` | 26.4MiB | **18MiB** |
| dtb | 37KiB | **30KiB** |
| `.ko` | 101 个 / 2.5MiB | **0 个** |

三个 6ULL-only 适配需要配套修改：

1. **busfreq（已关闭）**：i.MX6ULL 的 DDR3 频率切换只在
   i.MX6SX 的 `ddr3_freq_imx6sx.S` 里实现。实测空闲降到 24MHz 会让
   LCDIF 读 framebuffer 出错（启动后屏幕出横线、画面拉伸），因此
   `&soc/busfreq` 在 DTS 中 `status=disabled`，`common.c` 提供 DDR3/LPDDR2
   空实现，`mach-imx6ul.c` 仍编译 `busfreq-imx.o`（仅为 `imx_busfreq_map_io`）。
   DDR 固定跑 400MHz。
2. `fec_main.c` 无条件调用 `imx6q_cpuidle_fec_irqs_*()`，这两个符号只在
   `SOC_IMX6Q` 下编译；已用 `#ifdef CONFIG_SOC_IMX6Q` 保护，i.MX6ULL 的
   `FEC_QUIRK_ERR006687` 本来也不会命中。
3. `mxsfb` 原厂固定申请 `SZ_32M` framebuffer，超出 16MiB CMA 导致
   `Unable to allocate framebuffer memory`、`probe -12`、`/dev/fb0` 不存在，
   LCD 无企鹅 logo。已改为按实际分辨率分配，最少 2MiB。
4. LCD 花屏：`display0` 原先写 `bits-per-pixel = <16>`，而屏是
   24bit RGB888，mxsfb 按 RGB565 输出导致颜色/像素错位。已改为
   `<32>`（RGB888，`bus-width=24`），`fb` 内存约 1.6MiB。
5. `imx-sdma` 因 rootfs 缺少 `imx/sdma/sdma-imx6q.bin`，启动 60s 后报
   `Direct firmware load ... failed`。已把 `sdma-imx6q.bin` 放入
   `imx6ull_mini_rootfs/overlay/lib/firmware/imx/sdma/`，并重新启用
   `CONFIG_IMX_SDMA=y`。
6. 启动日志中的无关驱动已裁掉：`e1000e`（PCIe）、`ata/libata`、
   USB 网卡（`USB_USBNET`/`r8152`/`asix`/`cdc_ether` 等）、
   `MXC_MIPI_CSI2`、`FB_MXS_SII902X`（无 HDMI，之前会打印
   `sii902x bound to mxs-lcdif`）；`FB_MXC` 父项保留仅用于
   `mxc_dispdrv`，其 IPU/panel 子驱动全部关闭。
7. `failed to find ocotp node`：`mach-imx6ul.c` 按 `fsl,imx6ul-ocotp`
   查找，而 6ULL DTS 是 `fsl,imx6ull-ocotp`；在板级 DTS 的 `&ocotp`
   中补上 `fsl,imx6ul-ocotp` 兼容项。

> **MAC 地址（2026-11-11 结论）**：本板 OCOTP 的 MAC 区域（0x88/0x8e）
> 实测全 0（出厂未烧录 MAC），因此 fec 读到全 0 后被
> `is_valid_ether_addr()` 判无效，回退到随机 MAC（`2e:ae:dc:...`，本地
> 管理位）。此外 `imx6ul.dtsi` 的 MAC cell 定义为 6 字节
> （`reg = <0x8e 6>`），不按 OCOTP 4 字节 word 对齐，nvmem 层打
> `cell mac-addr raw len 6 unaligned` 警告（非致命，cell 仍创建）。
> 已在板级 `&ocotp` 把 `fec2_mac_addr` 覆盖为 8 字节消除警告，但
> **仍拿不到有效 MAC**。要稳定 MAC 需在 `&fec2` 加
> `local-mac-address = [xx xx xx xx xx xx];`（或 U-Boot `ethaddr`，
> 或一次性烧录 OCOTP fuse）。

### 7.5 模块裁剪结果

**历史决定（2026-11-07）**：不需要任何 `.ko`，`CONFIG_MODULES=n`。

> **后续变更（2026-11-10）**：改为 `CONFIG_MODULES=y` +
> `CONFIG_MODULE_UNLOAD=y`，内核支持 `insmod`/`modprobe`，目的是能加载
> **板外单独编译的驱动模块**（驱动开发/调试用），而不是让内核自己产出 `.ko`。
> 板级驱动仍全部 built-in，`.config` 里 `=m` 项仍为 **0**，所以
> `make modules` 不生成任何 `.ko`，因此不需要 `modules_install`；用绝对路径
> `insmod` 时也不需要 `/lib/modules`（`modprobe` 按模块名查找才需要）。
> `CONFIG_MODULE_SIG`/`MODULE_SIG_FORCE` 关闭，未签名模块可加载，便于开发；
> `CONFIG_MODVERSIONS=y` **已开启**，模块会携带导出符号 CRC 并在加载时校验，
> 见下方 vermagic 说明。
>
> 开启 `MODULES` 后 `HW_RANDOM` 的 Kconfig 默认会变成 `m`，会在无人注意时
> 凭空产出一个 `.ko`；已在 defconfig 中显式固定 `CONFIG_HW_RANDOM=y`
> 保持 `=m` 为 0。`HW_RANDOM_IMX_RNGC` 的 Kconfig 是 `default HW_RANDOM`，
> 因此**不要再显式写** `CONFIG_HW_RANDOM_IMX_RNGC=y`（写也会被
> `savedefconfig` 丢弃、造成 diff 噪声）；只要 `HW_RANDOM=y`，它自动是
> built-in。
>
> **vermagic 使用约定（重要）**：`CONFIG_LOCALVERSION_AUTO=y` 且工作区常有
> `-dirty` 后缀，vermagic 形如
> `6.12.49-imx6ull-mini-nand-<git短号>-dirty SMP mod_unload modversions ARMv7 p2v8`。
> 每次改动内核源码/配置并重新编译后，**外部 `.ko` 必须用同一份源码树、
> 同一份 `.config`（以及同一份 `Module.symvers`）重新编译**，否则 `insmod`
> 会报 `version magic ... should be ...`，或在 `MODVERSIONS` 下报
> `disagrees about version of symbol xxx` 而拒绝加载。
>
> 外部模块编译方式（已实测通过）：
>
> ```bash
> # 在本内核源码树根目录
> ./build.sh modules          # 无 =m 项时用于刷新 Module.symvers / utsrelease.h
> make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- M=/path/to/module modules
> # 产物 hello.ko 拷到板子（如 /mnt/nfs 挂载目录）后
> insmod /mnt/nfs/xxx.ko
> ```
>
> rootfs 侧已启用 BusyBox 的 `insmod`/`rmmod`/`lsmod`/`modprobe`/`depmod`/
> `modinfo`；`modprobe` 按模块名查找需要 `/lib/modules/$(uname -r)/` 与
> `modules.dep`，仅用绝对路径 `insmod` 则不需要。
>
> **抢占模型与 USER_NS（2026-11-10）**：`PREEMPT` 改为
> `CONFIG_PREEMPT_VOLUNTARY=y`，`HZ` 取 Kconfig 默认 `250`
> （响应与开销折中；纯吞吐可改 `PREEMPT_NONE` + `HZ=100`）。
> `CONFIG_USER_NS=y` 已开启（`MEMCG`/`CGROUPS`/其他 namespace 均已在），
> 支持容器/unprivileged 场景。

### 7.8 摄像头（OV5640）与 USB 音频（2026-11-10）

板载无 WM8960 codec，音频改用 **USB 声卡（UAC）** 走 OTG2 host 口；
摄像头用 OV5640 并行 DVP 接 CSI，色彩转换/缩放交给 **PXP 硬件**。

**内核配置新增**

```text
CONFIG_MEDIA_SUPPORT=y / MEDIA_SUPPORT_FILTER=y
CONFIG_MEDIA_CAMERA_SUPPORT=y / MEDIA_PLATFORM_SUPPORT=y
CONFIG_MEDIA_CONTROLLER=y / VIDEO_DEV=y
CONFIG_VIDEO_IMX7_CSI=y      ← imx7-media-csi，匹配 "fsl,imx6ul-csi"
CONFIG_VIDEO_OV5640=y
CONFIG_VIDEO_IMX_PXP=y / V4L_MEM2MEM_DRIVERS=y   ← 硬件 CSC + 缩放
CONFIG_SOUND=y / SND=y / SND_PCM=y / SND_USB_AUDIO=y
```

关闭：`MEDIA_ANALOG_TV/DIGITAL_TV/RADIO/SDR/TEST_SUPPORT`、`STAGING_MEDIA`。
`=m` 仍为 0。

**三个必须修的 DTS/驱动不匹配（否则 probe 失败）**

| 位置 | SoC dtsi（NXP BSP 风格） | mainline 6.12 驱动要求 | 处理 |
|---|---|---|---|
| `pxp` compatible | `fsl,imx6ull-pxp-dma` | `fsl,imx6ull-pxp` | 板级 DTS 覆盖 |
| `pxp` clock-names | `pxp_ipg`, `pxp_axi` | `axi`（`devm_clk_get(dev,"axi")`） | 板级 DTS 覆盖为 `axi` + `IMX6UL_CLK_PXP` |
| `csi` clock-names | `disp-axi`, `csi_mclk`, `disp_dcic` | `mclk` | 板级 DTS 覆盖为 `mclk` + `IMX6UL_CLK_CSI` |
| `ov5640` 属性名 | NXP: `pwn-gpios`/`rst-gpios`/`clock-names="csi_mclk"` | `powerdown-gpios`/`reset-gpios`/`clock-names="xclk"` | 按 mainline 绑定写 |

**板级 DTS 新增**

```text
&i2c2 下 ov5640: camera@3c
  compatible="ovti,ov5640"; clocks=IMX6UL_CLK_CSI; clock-names="xclk"
  powerdown-gpios=<&gpio1 4 GPIO_ACTIVE_HIGH>
  reset-gpios=<&gpio1 2 GPIO_ACTIVE_LOW>
  endpoint: bus-type=MEDIA_BUS_TYPE_PARALLEL, bus-width=8, data-shift=2
&csi   status=okay, clocks=IMX6UL_CLK_CSI, clock-names="mclk"
&pxp   compatible="fsl,imx6ull-pxp", clocks=IMX6UL_CLK_PXP, clock-names="axi"
iomuxc: pinctrl_csi1（PIXCLK/HSYNC/VSYNC + DATA00..07→CSI_DATA02..09）
        pinctrl_csi_pwr（GPIO1_IO04 / GPIO1_IO02）
```

> **注意**：`powerdown-gpios`/`reset-gpios` 用的是 GPIO1_IO04 / GPIO1_IO02，
> 需按实际板子原理图核对；若不符，只改这两行与 `pinctrl_csi_pwr` 即可。
> 本板 LCD 是 24 位并口，与 CSI 引脚不重叠（CSI 用独立 CSI_* pad），
> 不需要像某些板子那样把 LCD 降到 16 位。

**板端验证**

```bash
dmesg | grep -iE 'csi|ov5640|pxp'
v4l2-ctl --list-devices          # 期望出现 imx-media / /dev/video0、/dev/video1
v4l2-ctl -d /dev/video0 --list-formats-ext
# USB 声卡
cat /proc/asound/cards           # 插 USB 耳机后应出现新 card
aplay -l
```

**Qt 运行建议（无 GPU、256MiB）**

```bash
export QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0
export QT_QPA_FONTDIR=/usr/share/fonts
```

用 QtWidgets + 软件渲染；避免 QtQuick 复杂动画；相册用缩略图缓存；
音乐走 ALSA 直连（不要 gstreamer）；必要时开 zram/swap 缓解 256MiB 压力。

#### 背光亮度与 U-Boot 统一（2026-11-10）

现象：U-Boot logo 明显比 Linux logo 亮。原因是同一根 `GPIO1_IO08`、两边控制方式不同：

```text
U-Boot（改前）board/freescale/mx6ullevk/mx6ullevk.c : setup_lcd()
        gpio_direction_output(IMX_GPIO_NR(1, 8), 1)   → 恒定高电平 = 100%
Linux（改前）backlight: brightness-levels = <0 4 8 16 32 64 128 255>
        default-brightness-level = <6>                → levels[6]=128 → 50%
```

**两侧统一到 PWM 80%，并重做 Linux 的亮度表。**

1. **Linux 亮度档位**：原表只有 8 档（`0 4 8 16 32 64 128 255`），
   50% 之后直接跳 100%，中间没有可调空间。改为两点 + 内核插值：

```dts
brightness-levels = <0 255>;
num-interpolated-steps = <255>;      /* (2-1)*255+1 = 256 档，max_brightness=255 */
default-brightness-level = <204>;    /* 255*80% ≈ 80% */
```

   于是 `brightness` 0..255 直接对应占空比 0..100%（每档 0.39%），
   运行时 `echo 190 > /sys/class/backlight/backlight/brightness` 即 74.5%。

2. **U-Boot 改用 PWM**（不再用 GPIO 拉高）：

```text
include/configs/mx6ullevk.h : + #define CFG_IMX6_PWM_PER_CLK 24000000
configs/mx6ull_14x14_evk_nand_defconfig : + CONFIG_PWM_IMX=y（不加 CONFIG_DM_PWM）
board/freescale/mx6ullevk/mx6ullevk.c :
    lcd_pads 改为 MX6_PAD_GPIO1_IO08__PWM1_OUT
    LCD_BACKLIGHT_PERIOD_NS = 5000000（200Hz）
    LCD_BACKLIGHT_DUTY_NS   = period*204/255（=4000000ns，80%）
    手动 setbits CCGR4 的 MXC_CCM_CCGR4_PWM1_MASK 打开 PWM1 时钟门控，
    再调用 legacy 的 pwm_init/pwm_config/pwm_enable（参数顺序是
    (id, duty_ns, period_ns)，duty 在前，容易写反）；
    失败时回退到 GPIO 常亮，保证屏幕仍可见。
```

> **必须用 legacy PWM，不能用 DM PWM**：U-Boot 的 i.MX6ULL 没有
> `clk-imx6ul.c`、`CONFIG_CLK` 也未开启，DM 版 `drivers/pwm/pwm-imx.c`
> 在 `imx_pwm_of_to_plat()` 里调用 `clk_get_by_name(dev, "per")` 会返回
> `-ENOSYS`，probe 失败，串口打印
> `Failed to get per_clk` + `LCD backlight: no PWM device (-38)`。
> 关掉 `CONFIG_DM_PWM` 后 `pwm-imx.c` 走 `#ifndef CONFIG_DM_PWM` 的
> legacy 分支，按 `PWM1_BASE_ADDR` 直接操作寄存器，并用
> `CFG_IMX6_PWM_PER_CLK` 计算分频，完全不依赖 clk 框架。
> 注意 `CONFIG_BACKLIGHT_PWM` 依赖 `DM_PWM`，关掉后会一起消失（无影响，
> U-Boot 的 `backlight` 节点本板 DTS 里也没有）。
>
> U-Boot 侧 `lcd_pads` 必须同步改成 PWM 复用功能，否则 PWM 驱动配好了但引脚
> 还是 GPIO，输出不会到背光；回退路径会重新把引脚切回 GPIO 模式。
> Linux 侧 `pwm-imx27` 在 100% 占空比时 `SAR(=period) > PWMPR(=period-2)`，
> 硬件输出恒高，同样安全。
> 两侧现在都是 80%（`204/255`，U-Boot 侧 `5000000*204/255 = 4000000ns`），
> 切换时不再有亮度跳变。运行时调亮/调暗只写 Linux 侧
> `/sys/class/backlight/backlight/brightness`（0..255）；下次上电仍回到 80%。
> 若要让 U-Boot 和 Linux 一起改默认值，需同时改
> `default-brightness-level` 与 U-Boot 的 `LCD_BACKLIGHT_DUTY_NS`。

- 保留为 built-in：USB ACM/Serial/FTDI、USB Gadget/ConfigFS、RNG、VLAN、
  FAT16、BINFMT_MISC、CRC32C、CAN/FLEXCAN、UART3、I2C2、KEY0、
  iptables + nftables、IPv6、NFS 客户端、USB Storage、KEXEC、
  CGROUPS/NAMESPACES、DYNAMIC_DEBUG/KPROBES
  （`CRASH_DUMP`/`FTRACE`/`NFSD` 按后续决定关闭）；
- 删除：USB 4G/WWAN、USB 网卡、AF_ALG/KTLS、CAAM、MD/DM、RPMSG/SIOX、
  PS/2、测试模块、传统加密算法；
- 裁剪前的 101 个 .ko 逐项分析见 [`模块裁剪评估.md`](模块裁剪评估.md)；
- 实测模块数从 101 降到 0，zImage 7.0MiB，vmlinux 18MiB。
- **`build.sh` 已同步模块支持**：`modules` 命令在 `=m` 为 0 时仍跑一次
  `make modules` 以刷新外部模块编译环境；`info`/编译结果显示模块支持状态；
  `all` 与 `deploy` 流程不变（内核不产出 `.ko`，无需 `modules_install`）。

### 7.8.1 消除 dummy regulator 告警（2026-11-11）

启动日志里出现过三条（外加 `mxsfb` 一条）：

```text
ov5640 1-003c: supply DOVDD not found, using dummy regulator
ov5640 1-003c: supply AVDD  not found, using dummy regulator
ov5640 1-003c: supply DVDD  not found, using dummy regulator
mxsfb 21c8000.lcdif: supply lcd not found, using dummy regulator
```

**原因**：这几个驱动都用 `devm_regulator_get()`（非 optional）取 supply，
设备树没提供时 regulator core 回退到 dummy 并打 warning。功能不受影响
（dummy 的 enable/disable 都是空操作），但
`ovti,ov5640.yaml` 里 **AVDD/DVDD 是 required**，按规范应显式声明。

**处理方式**：模组供电都来自底板 `DCDC_3V3` 直连、不可控，所以用
`regulator-fixed` + `regulator-always-on` 描述：

```dts
reg_cam_3v3: regulator-cam-3v3 { ... 3.3V, always-on ... };
reg_lcd_3v3: regulator-lcd-3v3 { ... 3.3V, always-on ... };

ov5640: camera@3c {
    AVDD-supply  = <&reg_cam_3v3>;
    DVDD-supply  = <&reg_cam_3v3>;
    DOVDD-supply = <&reg_cam_3v3>;
};
&lcdif { lcd-supply = <&reg_lcd_3v3>; };
```

三路同源是合理的：OV5640 模组内部自带 LDO，把 3.3V 转成
AVDD(2.8V)/DVDD(1.5V)/DOVDD(1.8V)，对外只有一个 3.3V 输入
（mainline 的 `stm32mp157c-ev1` 也是三路同源）。且 `ov5640.c` 只调用
`regulator_bulk_enable/disable`，**不调用 `regulator_set_voltage`**，
所以 `regulator-fixed` 足够。

> 顺带打开 `CONFIG_WATCHDOG_SYSFS=y`，否则 `/sys/class/watchdog/watchdog0/`
> 下只有 `dev`/`uevent`，没有 `identity`/`timeout`/`state` 等属性，
> 无法从 sysfs 查看看门狗状态（驱动本身正常绑定为 `imx2-wdt`）。

### 7.8.2 设备侧驱动配置核查（2026-11-11，SSH 实测）

**platform 驱动绑定**（全部正常，无 `driver_override`/未绑定）：

| 设备 | 驱动 | 设备 | 驱动 |
|---|---|---|---|
| `21c8000.lcdif` | `mxsfb` | `21c4000.csi` | `imx6ul-csi`（`imx7-media-csi.c`，driver.name 已改为 imx6ul-csi） |
| `21cc000.pxp` | `pxp` | `2080000.pwm` | `pwm-imx27` |
| `20b4000.ethernet` | `fec` | `2190000.mmc` | `sdhci-esdhc-imx` |
| `2090000.can` | `flexcan` | `2184000/2184200.usb` | `imx_usb` |
| `1806000.nand-controller` | `gpmi-nand` | `2284000.rng` | `imx_rngc` |
| `20bc000.watchdog` | `imx2-wdt` | `21a4000.i2c` | `imx-i2c` |
| `2020000/21ec000.serial` | `imx-uart` | `20cc000.snvs` | SNVS |

**设备节点**：`video0`=csi capture、`video1`=pxp、
`v4l-subdev0`=csi、`v4l-subdev1`=ov5640 1-003c；
`fb0`=800x480/32bpp/stride 3200；背光 `204/255`=80%；
`can0`/`eth0`(100M)/`lo`；`rtc0`；`mtd0..6` 七个分区与
`mtdparts=` 完全一致；`ubi0:rootfs` 以 rw 挂载。

**I2C2** (`i2c-1`) 上只有两个设备：`1-0014`=gt9147、`1-003c`=ov5640。

**时钟**（`clk_summary`）：`lcdif_pix`=31MHz、`csi_podf`=24MHz、
`pwm1 per`=**24MHz**、`perclk`=24MHz。

> **注意（2026-11-11 已修正）**：`CFG_IMX6_PWM_PER_CLK` 正确值是
> **24000000**，不是 66MHz。PWM1 的 per 时钟源是 `perclk`，父时钟
> `perclk_sel` 二选一（`CSCMR1[PERCLK_CLK_SEL]`：0=ipg 66MHz / 1=osc 24MHz），
> **复位默认是 1（osc 24MHz）**，U-Boot 不修改该位，Linux 侧 `clk_summary`
> 实测 `osc=24MHz → perclk=24MHz → pwm1=24MHz` 印证。写成 66MHz 会让
> U-Boot 阶段 PWM 频率算成约 73Hz（占空比 80% 不变、亮度看着对，但频率低）。

**输入设备编号会变**（2026-11-11 实测）：

```text
event0 = 20cc000.snvs:snvs-powerkey   ← 启用 snvs_pwrkey 后出现
event1 = Goodix Capacitive TouchScreen
event2 = beep
event3 = gpio-keys (KEY0)
```

> **应用层不要硬编码 `/dev/input/event0`**：启用 ON_OFF 按键后它变成了
> pwrkey，触摸是 event1。应按 `EVIOCGNAME` 按名字查找，或用 udev 固定
> symlink。触摸 ABS 范围实测 `ABS_X/ABS_MT_POSITION_X max=799`、
> `ABS_Y/ABS_MT_POSITION_Y max=479`，正确（非 4095 兜底）。

**GPIO 占用**（`debugfs/gpio`，全部与原理图一致）：

```text
GPIO1: 2=OV5640 reset, 3=sys-led, 4=OV5640 powerdown,
       9=触摸 irq, 18=KEY0, 19=TF 卡 cd
GPIO5: 1=beep, 8=phy-reset, 9=触摸 reset
```

**dmesg 残余告警**（均已确认无害）：`gpiochipX: Static allocation of
GPIO base is deprecated`（i.MX pinctrl 固有）、`Console: colour dummy
device`（正常）、`No soundcards found`（未插 USB 声卡）、
`Fixed dependency cycle(s)`（fw_devlink 自动解环）。
`dummy regulator` 四条已由 7.8.1 修复。

### 7.9 RTC 与 ON_OFF 按键（2026-11-11 实测）

**硬件**：i.MX6ULL 片内 SNVS RTC（`fsl,sec-v4.0-mon-rtc-lp`），
核心板上由 **CR1220 纽扣电池**经 `BAT54C` 双电源切换供电：

```text
外部电源正常时  VDD_SNVS_3V3 供电，CR1220 不放电
外部电源断开时  VDD_COIN_3V → BAT54C → VDD_SNVS_IN，CR1220 顶上来
```

因此 SNVS 域（含 RTC 计数器）始终有电，断电后走时不受影响。

**内核配置**（均已开启）：

```text
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_SNVS=y
CONFIG_RTC_HCTOSYS=y                      开机 rtc0 → 系统时钟
CONFIG_RTC_HCTOSYS_DEVICE="rtc0"
CONFIG_RTC_SYSTOHC=y                      关机 系统时钟 → rtc0
```

**实测保时能力**（2026-11-11）：

```text
设置   date -u -s "2026-11-11 01:30:00"  &&  hwclock -w -u
RTC 读回  Wed Nov 11 01:30:00 2026
reboot
重启后    Wed Nov 11 01:30:53 2026      uptime 45.68s
差值 53s = reboot 排队 2s + 启动到应用 45.7s  → 分秒不差，电池正常
```

> **注意：新板首次使用或换电池后，必须手动设一次时间**，否则 RTC 从
> 1970-01-01 开始累计，`dmesg` 会看到
> `setting system clock to 1970-01-01T...`。这不是故障。
> 联网后可直接 `ntpd -q` / `chronyc makestep` 校时，再 `hwclock -w`
> 写回 RTC 即可长期保持。

**ON_OFF 按键**：核心板连接器 B4 = `ON_OFF`（SNVS 域 PWRON 引脚），
接底板 K1 按键。已在 DTS 启用：

```dts
&snvs_pwrkey { status = "okay"; };
```

作用：短按唤醒/开机，长按触发 SNVS power down。
`ON_OFF` 是 SoC 专用引脚，不需要 pinctrl。

> 未启用 `&snvs_poweroff`：它通过拉低 `PMIC_ON_REQ` 通知 PMIC 断电，
> 而本板是分立 DCDC、无 PMIC，启用后 `poweroff` 只会 halt 不会真正断电，
> 容易误解，故保持关闭。

### 7.6 内建配置评估

当前 `=y` 配置共 1328 项，其中与板级相关、可选/建议关闭的 built-in 项，
按 P0（必须）～P4（建议关闭）分级列在
[`内核内建配置评估.md`](内核内建配置评估.md) 中，包括：

- P0 启动/UBIFS 必须项（SoC、时钟、pinctrl、串口、GPMI、UBI/UBIFS、devtmpfs）
- P1 板级外设（FEC/RTL8201F、USDHC1、LCD/PWM、USB、CAN、I2C2、KEY0）
- P2/P3 可选功能（容器、IPv6、NFS、USB 存储、USB Gadget、PM、CPU governor）
- P4 建议关闭（KEXEC、CRASH_DUMP、PM_DEBUG、JFFS2、SAHARA、CAAM SECVIO 等）

### 7.7 自定义全屏启动画面（2026-11-08）

采用**方案 A2**：新增板级 logo 文件与 Kconfig 项，不改动内核自带的
`logo_linux_clut224.ppm`。

| 文件 | 改动 |
|---|---|
| `drivers/video/logo/logo_mini_clut224.ppm` | 新增，P3 ASCII PPM，**800x480**，224 色，白底 |
| `drivers/video/logo/Kconfig` | 新增 `CONFIG_LOGO_MINI_CLUT224` |
| `drivers/video/logo/Makefile` | 新增 `logo_mini_clut224.o`（.c 由 `pnmtologo` 自动生成） |
| `include/linux/linux_logo.h` | 新增 `extern const struct linux_logo logo_mini_clut224;` |
| `drivers/video/logo/logo.c` | `depth >= 8` 分支末尾优先返回板级 logo |
| defconfig | `LOGO_MINI_CLUT224=y`，关闭 mono/vga16/clut224 三个标准 logo |

图片生成（源图 `linux_logo.png`，2656x1600 RGBA 白底）：

```text
等比缩放 797x480 → 居中贴到 800x480 纯白画布（不变形、左右各 1~2px 白边）
→ MEDIANCUT 量化 224 色、无抖动（白底不产生噪点）
→ 强制调色板最接近白的项为纯 (255,255,255)
→ 输出 P3 PPM（pnmtologo 不接受 PNG/P6 二进制 PNM）
→ 800*480 = 384000 字节数据 + 224*3 字节 clut，编进 __initconst
```

**"只显示图片、不要 VT 终端"的实现**：内核 logo 由
`fbcon_switch() → fb_show_logo()` 绘制，因此 `CONFIG_VT` 与
`CONFIG_FRAMEBUFFER_CONSOLE` 必须保留；做法是"不给 fbcon 任何文字/光标"：

- 全屏 480px → `logo_lines = 30`，`vc_top = 30 = vc_bottom`，文字区 0 行；
  `fb_show_logo` 画完白图后 `update_region()` 长度为 0，不覆盖图案；
- `console=ttymxc0` 保持单 console，printk 不进 LCD；
- `inittab` 只在 `ttymxc0` 起 shell，不在 tty1 起 getty；
- 光标：`drivers/tty/vt/vt.c` 的 `global_cursor_default` 默认值由 -1 改为
  0，使 `vc_deccm=0`，`fbcon_cursor()` 直接返回、闪烁 work 不启动；
  仍可用 `vt.global_cursor_default=1` 在 bootargs 覆盖回来。
- `consoleblank` 无需设置：`vt.c` 的 `blankinterval` 初值为 0，
  不启动黑屏定时器（内核文档 `kernel-parameters.txt` 亦注明默认 0）。
- 命令行：`CONFIG_CMDLINE_FROM_BOOTLOADER=y`（Kconfig 默认）+
  完整兜底 `CONFIG_CMDLINE`，有 U-Boot bootargs 就用它，没有就用兜底。
  不使用 `CMDLINE_EXTEND`：那会让 bootargs 为空时内核只剩光标参数、
  缺 `root=`/`mtdparts=` 而无法启动。
- `CONFIG_ARCH_FORCE_MAX_ORDER=10` + DTS 的 `linux,cma { size = <0x1000000>; }`
  共同保证 CMA 是 16MiB，全屏 logo 能分配成功。
- CMA 实测不是帧率瓶颈：摄像头预览时 `CmaFree` 长期有 13MiB+ 剩余，
  瓶颈是 CPU memcpy（见 7.8 节）。

> 注意：改动 `global_cursor_default` 是内核通用代码，属板级定制；
> 升级内核版本时需重新应用。
> logo 数据在 `__initconst`，`late_initcall_sync` 后 `logos_freed=true`，
> 启动完成后内核无法再重画；**用户态程序一旦写 `/dev/fb0` 或触发 VT
> 滚动/清屏，图案就会被覆盖且不可恢复**。

## 8. build.sh 设计

脚本结构对齐 U-Boot 最终版 `build.sh`：

- `set -Eeuo pipefail` + `ERR` trap，失败时输出退出码和行号；
- 环境变量优先，所有参数可覆盖；
- 非终端场景自动关闭颜色输出；
- 每个步骤统一由 `run_make()` 执行并统计耗时；
- 从头构建与增量构建分离。

### 8.1 命令

| 命令 | 作用 |
|---|---|
| `all` | `distclean + config + 编译 + deploy`（默认） |
| `clean` | `make clean`，保留 `.config` |
| `distclean` | `make mrproper`，删除 `.config`（别名 `mrproper`） |
| `config` | 应用 `imx6ull_mini_nand_defconfig` |
| `menuconfig` | 交互式配置 |
| `savedefconfig` | 将当前配置回写为板级 defconfig（别名 `saveconfig`） |
| `build` | 增量编译 |
| `dtbs` | 仅编译板级 dtb |
| `modules` | 仅编译内核模块 |
| `deploy` | 发布 `zImage` + dtb 到 `output/`，并发布到 `$HOME/tftp` |
| `info` | 显示版本、配置、产物目录 |
| `help` | 帮助 |

### 8.2 环境变量

| 变量 | 默认值 |
|---|---|
| `ARCH` | `arm` |
| `CROSS_COMPILE` | `arm-linux-gnueabihf-` |
| `DEFCONFIG` | `imx6ull_mini_nand_defconfig` |
| `DTB` | `imx6ull-14x14-evk_nand` |
| `JOBS` | `nproc` |
| `MAKE` / `MAKE_FLAGS` | `make` / 空 |
| `OUT_DIR` | `<源码目录>/output` |
| `TFTP_DIR` | `$HOME/tftp`（显式置空 `TFTP_DIR=` 可禁用 TFTP 发布） |

### 8.3 与 U-Boot tftp_update 的衔接

U-Boot 侧：

```text
kernel_file = zImage
dtb_file    = imx6ull-14x14-evk_nand.dtb
rootfs_file = rootfs_nand.ubi
```

Linux 侧：

```bash
./build.sh deploy                    # 默认发布到 output/ 与 $HOME/tftp
TFTP_DIR= ./build.sh deploy          # 仅发布到 output/
TFTP_DIR=/srv/tftp ./build.sh deploy # 覆盖为系统 TFTP 目录
```

`deploy` 输出：

```text
output/zImage
output/imx6ull-14x14-evk_nand.dtb
$HOME/tftp/zImage
$HOME/tftp/imx6ull-14x14-evk_nand.dtb
```

之后在 U-Boot 中执行：

```text
tftp_update kernel
tftp_update dtb
tftp_update all
```

> `TFTP_DIR` 默认就是 `$HOME/tftp`，与 tftpd-hpa 的 `TFTP_DIRECTORY` 一致，
> 因此 `./build.sh deploy` 无需任何环境变量即可发布到 TFTP 根目录。
> 脚本使用 `${TFTP_DIR-默认值}`（不带冒号），显式置空 `TFTP_DIR=` 才会禁用
> TFTP 发布；目录不存在时只做 `mkdir -p`，不会对已存在目录 `chmod`。
> 目录不可写时脚本会在本地 `output/` 发布完成后给出明确提示。
>
> 把 `/etc/default/tftpd-hpa` 的 `TFTP_DIRECTORY` 改到 `$HOME` 下时，还需注意
> Ubuntu 的 `tftpd-hpa.service` 默认带有 `ProtectHome=yes`，服务看不到
> `/home/...`，`in.tftpd` 会报 `No such file or directory`（退出码 66）。
> 需通过 systemd drop-in 放开该目录：
>
> ```bash
> sudo install -d /etc/systemd/system/tftpd-hpa.service.d
> printf '[Service]\nProtectHome=read-only\n' | \
>     sudo tee /etc/systemd/system/tftpd-hpa.service.d/override.conf
> sudo systemctl daemon-reload
> sudo systemctl restart tftpd-hpa
> ```
>
> 另一种做法是保留 `TFTP_DIRECTORY="/srv/tftp"`，仅把该目录属主改为当前用户，
> 然后 `TFTP_DIR=/srv/tftp ./build.sh deploy` 显式覆盖默认值。

## 9. 验证方案与结果

### 9.1 设计原则

- 配置、设备树、驱动、脚本分别验证；
- 完整内核构建使用独立输出目录 `O=/tmp/imx6ull_trim_build`，保持源码树干净；
- 增量验证使用板级 defconfig 编译关键对象与 dtb；
- 对生成的 dtb 反编译检查关键属性，避免只验证“能编译”而不验证“内容正确”。

### 9.2 验证结果

| 验证项 | 命令 | 结果 |
|---|---|---|
| 脚本语法 | `bash -n build.sh` | 通过 |
| 配置应用 | `make imx6ull_mini_nand_defconfig` | 通过，无 override 警告 |
| 配置内容 | 检查 `.config` 关键项 | 只保留 i.MX6ULL 与本板驱动 |
| 板级 dtb | `make nxp/imx/imx6ull-14x14-evk_nand.dtb` | 通过，30KB |
| dtb 属性 | `dtc -I dtb -O dts` 反编译 | 只有本板节点，无 74HC595/音频/摄像头/CAN |
| 驱动对象 | `mxsfb.o`、`gpmi-nand.o`、`fec_main.o`、`common.o` | 全部编译通过 |
| 完整内核 | `make O=/tmp/imx6ull_trim_build -j8 zImage` | 通过，zImage 7.0MB |
| 内核版本 | `kernel.release` | `6.12.49-imx6ull-mini-nand` |
| 代码风格 | `checkpatch.pl` | 0 errors，0 warnings |
| 产物发布 | `./build.sh deploy` | 文件名与 U-Boot 环境变量一致 |

dtb 反编译确认（独立最小设备树）：

```text
memory@80000000: reg = <0x80000000 0x10000000>
fec2:            status = "okay"
ethernet-phy@1:  compatible = "ethernet-phy-id001c.c816"
lcdif:           display = <&display0>;  (无 enable-gpio)
gpmi:            status = "okay"
分区:            boot/env/logo/kernel/dtb/tee/rootfs
rootfs:          reg = <0x4800000 0x1b800000>  (440MiB)
无节点:          spi-4 / 74hc595 / wm8960 / ov5640 / can / qspi / usdhc2
```

## 10. 使用流程

### 10.1 编译

```bash
./build.sh             # all：distclean + config + compile + deploy
./build.sh config      # 应用板级配置
./build.sh build       # 增量编译（zImage + dtbs + modules）
./build.sh dtbs        # 只编译板级 dtb
./build.sh modules     # 只编译内核模块
./build.sh deploy      # 收集 zImage/dtb 到 output/，并发布到 $HOME/tftp
./build.sh clean       # make clean（保留 .config）
./build.sh distclean   # make mrproper（含 .config；别名 mrproper）
./build.sh info        # 构建参数与产物 / TFTP 目录
```

### 10.2 更新开发板

```bash
./build.sh deploy   # 默认发布到 $HOME/tftp（tftpd-hpa 的 TFTP_DIRECTORY）
```

U-Boot 下：

```text
tftp_update kernel
tftp_update dtb
```

或直接启动：

```text
nand read ${loadaddr} 0x1400000 0x2000000
nand read ${fdt_addr} 0x3400000 0x100000
bootz ${loadaddr} - ${fdt_addr}
```

### 10.3 根文件系统

`rootfs` 分区使用 UBI + UBIFS：

```text
ubi.mtd=rootfs root=ubi0:rootfs rootfstype=ubifs
```

rootfs 镜像命名与 U-Boot 的 `rootfs_file` 保持一致：`rootfs_nand.ubi`。

## 11. 注意事项

1. **分区一致性**：分区布局共有四处描述，修改时必须同时更新：U-Boot
   `MFG_NAND_PARTITION`（`bootargs`）、U-Boot `CONFIG_MTDPARTS_DEFAULT`、
   内核 `CONFIG_CMDLINE`、内核设备树 `fixed-partitions`；`bootcmd` 中的
   `nand read` 偏移/长度也要跟着调整。默认环境变量改动后，板上需执行
   `env default -a; saveenv` 才会生效。
2. **rootfs 大小**：`-(rootfs)` 由 `cmdlinepart` 按 ONFI 探测容量动态计算，
   实机 512MiB NAND 下为 440MiB（`0x1B800000`），256MiB 下为 184MiB。
   设备树 `fixed-partitions` 无法表达「占满剩余空间」，其
   `NAND_ROOTFS_SIZE` 是本设计里**唯一写死的容量假设**（仅作后备），
   换用其它容量 NAND 时必须同步修改；它只在 cmdlinepart 未生效时起作用。
   UBI 还会扣除坏块与元数据开销，实际可用卷空间小于分区大小。
3. **UBI 镜像**：`rootfs_nand.ubi` 的体积必须小于 TFTP 下载时的可用 RAM
   （256MiB 板约 218MiB），卷使用 `autoresize=1` 在首次挂载时扩展到整个
   分区；U-Boot 侧 `tftp_update rootfs` 采用 `nand write.trimffs` 写入，
   并在擦除前校验镜像大小与 RAM 窗口。
4. **LCD 时序**：`hactive` 已按屏幕手册修正为 800（原 U-Boot 提交里是 840），两端已同步。
5. **网络 PHY**：实板经 `mii read 1 2/3` 实测为 `0x001CC816`
   （Realtek RTL8201F），与正点原子资料标注的 LAN8720A 不符。最小 DTS 直接写
   `compatible = "ethernet-phy-id001c.c816"`，defconfig 保留
   `CONFIG_REALTEK_PHY=y`；Micrel / SMSC 驱动保留作换料兼容。
   旧版基于 EVK dtsi 的“PHY 复位脚被 74HC595 占用”问题，在最小 DTS 中已通过
   整体删除 `spi-4`/`74HC595` 彻底消除；ENET2_RST（`SNVS_TAMPER8`/`GPIO5_IO08`）
   改在 `&iomuxc_snvs` 中配置，并由 `&fec2` 的 `phy-reset-gpios` + 200ms 管理。
   换用其它 PHY 时改 compatible 或回到 C22 自动探测即可。
6. **`all` 会执行 `distclean`（`make mrproper`）**：自定义 `menuconfig` 配置请先执行 `./build.sh savedefconfig`，日常使用 `./build.sh build` 增量编译；`all` 结束会自动 `deploy` 到 `output/` 与 `$HOME/tftp`。
7. **DTB 命名**：内核 dtb 使用下划线 `imx6ull-14x14-evk_nand.dtb`，与 U-Boot 的 `dtb_file` 严格一致；U-Boot 自身内建 dtb 为 `imx6ull-14x14-evk-nand.dtb`（连字符，用于 U-Boot 驱动）。
8. **未启用外设**：早期最小 DTS 只保留启动/显示/网络/NAND/TF/USB/LED/BEEP，
   后续已陆续启用 CAN/UART3、摄像头（CSI+OV5640+PXP）、触摸（GT9xx）、USB 声卡。
   仍未启用：SDIO WiFi、QSPI、USDHC2、AP3216C/ICM20608、板载音频 codec；
   需要时按 6.7 的引脚说明追加节点，并同步打开对应内核配置（如 `CONFIG_CAN`、
   `CONFIG_CFG80211`/`CONFIG_WLAN`、`CONFIG_MEDIA_SUPPORT`、`CONFIG_SND`）。
9. **OP-TEE**：本方案关闭 `CONFIG_OPTEE`/`CONFIG_TEE`（`tee` 分区保留给 U-Boot）。
   若后续要在 Linux 下使用 OP-TEE，需要重新打开并保留 `busfreq_optee.o` 所需的
   `SOC_IMX6Q/SX` 或补充对应汇编符号。
10. **裁剪后的链接保护**：`fec_main.c` 的 i.MX6Q cpuidle 钩子、`common.c` 的
    DDR3/LPDDR2 空实现是为“只保留 SOC_IMX6UL”服务的。busfreq 因降频导致
    LCDIF 读 framebuffer 出错，已在 DTS 中禁用（固定 400MHz）。

## 12. 硬件资源清单

### 12.1 核心板（NAND 版）

| 项目 | 配置 |
|---|---|
| CPU | MCIMX6Y2CVM08AB，Cortex-A7，工业级，792MHz，BGA289 |
| DDR3L | 256MiB（NT5CC128M16JR-EK 级别） |
| NAND | 512MiB（实机 `NAND: 512 MiB`，MT29F4G08 级别） |
| 连接器 | 2×30 BTB，共 120 pin |

> 存在 256MiB/512MiB NAND、商业级/工业级等多种核心板版本；本板按实机
> `NAND: 512 MiB` 与 `NAND_ROOTFS_SIZE = 0x1B800000` 配置。

### 12.2 底板

官方底板资源与本方案状态：

| 底板资源 | 本方案状态 |
|---|---|
| 1 个核心板接口（支持 I.MX6ULL 核心板） | 使用 |
| 1 个电源指示灯（蓝色） | 不受控 |
| 1 个状态指示灯（红色，GPIO1_IO03，低有效） | 已启用 |
| 1 路 CAN，TJA1050 | 已启用（CAN1 / FLEXCAN1） |
| 1 路 485，SP3485 | 已启用（UART3，与 RS232 跳线选择） |
| 1 个 ATK 模块接口（蓝牙/GPS/MPU6050/手势等） | 控制器已启用（I2C2 + UART3），模块节点按需添加 |
| 1 个摄像头模块接口（P1, Header 9X2） | 已启用（CSI + OV5640 + PXP，接模块即可用） |
| 1 个 USB 串口（调试） | 已启用（UART1） |
| 1 个 USB HOST 接口 | 已启用（OTG2，`dr_mode=host`） |
| 1 个 USB OTG 接口（MiniUSB，USB_OTG） | 已启用（OTG1，`dr_mode=otg` + USB Gadget/ConfigFS） |
| 1 个有源蜂鸣器（GPIO5_IO01） | 已启用（`GPIO_ACTIVE_LOW`，低电平响） |
| 1 个 RS232/RS485 选择接口 | 已启用（UART3，跳线选择） |
| 1 个 TF 卡接口（板背面，USDHC1，CD=GPIO1_IO19） | 已启用 |
| 1 个 10M/100M 以太网接口（RJ45，ENET2 + RTL8201F） | 已启用 |
| 1 组 5V 电源供应/接入口 | 供电，无驱动 |
| 1 组 3.3V 电源供应/接入口 | 供电，无驱动 |
| 1 个 DC 电源输入（6~18V） | 供电，无驱动 |
| 1 个启动模式选择配置接口 | 硬件/U-Boot |
| 1 个 RTC 后备电池座（CR1220，带电池） | SNVS RTC，已启用并实测保时（见 7.9） |
| 1 个复位按钮（复位 MPU 和 LCD） | 硬件 |
| 1 个 ON/OFF 按钮（核心板 B4 = ON_OFF） | 已启用（`snvs_pwrkey`，短按唤醒/长按下电） |
| 1 个功能按钮 | 已启用（gpio-keys KEY0，GPIO1_IO18） |
| 1 个电源开关 | 硬件 |
| 1 个 SDIO WIFI 接口 | 未启用（与 NAND 引脚复用） |
| 1 个 10P JTAG 接口（JLINK 等） | 调试用，无内核节点 |

> 官方底板资源列表没有单列 LCD 接口；按屏幕手册与底板原理图，LCD 为
> 800x480@60Hz，PWM1 背光（BLT_PWM = GPIO1_IO08），RESET 接整板复位网络。
> 早期 U-Boot 输出 `840 x 480` 是配置错误，已修正（见 6.2 节）。
> 触摸屏已启用（4.3 寸 GT9xx），使用 I2C2，CT_RST=SNVS_TAMPER9、
> CT_INT=GPIO1_IO09；屏电源取底板 DCDC_3V3，用 always-on fixed regulator 描述。

### 12.3 与 ALPHA 底板的主要差异

- Mini 只有 1 个网口（ENET2），ALPHA 有 ENET1 + ENET2；
- Mini 底板有 USB OTG（MiniUSB，OTG1）+ USB HOST（OTG2）+ USB 串口，DTS 两者都启用；
- Mini 底板**没有** AP3216C 环境光传感器、WM8960 音频编解码器、ICM20608 六轴；
- Mini 通过 ATK 模块接口扩展蓝牙/GPS/MPU6050 等，不是板载；
- 因此最小 DTS 不包含 `i2c` 传感器、`sai2`/`wm8960`、`ecspi3`/ICM20608 节点。

### 12.4 资料来源

- 本地：`imx6ull_mini_uboot/markdown/`（分区、环境变量、TFTP 流程）、
  U-Boot 实机启动日志、`arch/arm/boot/dts/nxp/imx/` 与 U-Boot DTS；
- 网络：正点原子 Mini 开发板资料页
  <http://www.openedv.com/docs/boards/arm-linux/zdyz-i.mx6ullmini.html>、
  《I.MX6U 用户快速体验》硬件资源章节、
  <https://blog.csdn.net/ZSW2027008838/article/details/137496956>；
- PHY 型号以 U-Boot `mii read 1 2/3` 实测 `0x001CC816`（RTL8201F）为准。
