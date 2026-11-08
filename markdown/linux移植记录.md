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
| LCD | 7 寸 RGB 屏，31MHz，840x480 时序（与 U-Boot 保持一致） |
| 以太网 | 仅 ENET2，RMII，PHY 地址 1，实板 RTL8201F（ID `001c.c816`），DTS 写死 `ethernet-phy-id001c.c816` |
| 调试串口 | UART1 / `ttymxc0`，115200 |
| 存储卡 | TF 卡：USDHC1，4 位，CD = GPIO1_IO19 |
| USB | USB OTG（OTG1，MiniUSB）+ USB HOST（OTG2）+ USB 串口（调试） |
| 人机接口 | 红色状态 LED（GPIO1_IO03）、有源蜂鸣器（GPIO5_IO01）、KEY0（GPIO1_IO18） |
| 现场总线 | CAN1（TJA1050）；UART3 经跳线选择 RS232/RS485/GPS |
| 模块接口 | ATK 模块（I2C2 + UART3）；摄像头接口（CSI，无传感器） |
| 本方案未启用 | WM8960 音频、OV5640 摄像头驱动、AP3216C/ICM20608、SDIO WiFi、触摸屏 |
| 启动方式 | NAND：U-Boot 从 `0x1400000` 读内核、`0x3400000` 读 DTB |

实测 U-Boot 启动日志与本表一致：

```text
DRAM:  256 MiB
NAND:  512 MiB
[*]-Video Link 0 (840 x 480)
Net:   eth1: ethernet@20b4000 [PRIME]
```

> NAND 容量以实机 `NAND: 512 MiB` 为准。早期文档按 256MiB 估算的
> rootfs 可用空间（184MiB）已作废，实际为 440MiB = `0x1B800000`。

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
| `drivers/video/fbdev/mxsfb.c` | 修改 | 支持 LCD 复位脉冲（`enable-gpio`） |
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

沿用 U-Boot `imx6ul-14x14-evk.dtsi` 中的 7 寸屏参数：

```dts
&timing0 {
	clock-frequency = <31000000>;
	hactive = <840>;
	vactive = <480>;
	hfront-porch = <40>;
	hback-porch = <88>;
	hsync-len = <48>;
	vback-porch = <32>;
	vfront-porch = <13>;
	vsync-len = <3>;
};
```

LCD 复位脚为 `GPIO5_IO09`，已在 pinctrl 中复用为 GPIO，设备树通过 `enable-gpio` 交给 `mxsfb` 驱动：

```dts
&lcdif {
	enable-gpio = <&gpio5 9 GPIO_ACTIVE_HIGH>;
};
```

> 注意：U-Boot 原始提交中 `hactive = <840>`，若实际屏为标准 800x480，需要同时修改 U-Boot 与内核设备树为 `800`。

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

### 6.6 LCD 复位

U-Boot `setup_lcd()` 会通过 `GPIO5_IO09` 产生复位脉冲；内核 `mxsfb` 原先只把 `enable-gpio` 初始化为低电平，不会释放。驱动补充：

```c
if (gpio_is_valid(gpio)) {
	ret = devm_gpio_request_one(&pdev->dev, gpio,
					GPIOF_OUT_INIT_LOW, "lcd_pwr_en");
	if (ret) {
		dev_err(&pdev->dev,
			"failed to request gpio %d, ret = %d\n", gpio, ret);
		return ret;
	}

	/*
	 * LCD 复位脉冲：与 U-Boot setup_lcd() 一致，
	 * 拉低 500us 后释放，否则 RGB 屏会一直处于复位状态。
	 */
	udelay(500);
	gpio_set_value(gpio, 1);
}
```

同时新增 `#include <linux/delay.h>` 和 `#include <linux/gpio.h>`。

### 6.7 最终节点清单（最小设备树）

DTS 直接 `#include "imx6ull.dtsi"`，编译后约 31KiB（精简前 37KiB）。

保留并启用的节点：

| 节点 | 关键配置 |
|---|---|
| `memory@80000000` | 256MiB |
| `&uart1` | 调试串口 `ttymxc0` |
| `&fec2` | RMII，PHY@1 `ethernet-phy-id001c.c816`（RTL8201F），`GPIO5_IO08` 复位 200ms |
| `&gpmi` | `nand-on-flash-bbt`、`fsl,use-minimum-ecc`、7 个分区 |
| `&lcdif` | 840x480/31MHz、24bit RGB888、`bits-per-pixel=32`、PWM1 背光、`GPIO5_IO09` 复位 |
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

> 触摸屏（GT9147/FT5426）使用 I2C2 + `GPIO1_IO09`(INT) / `GPIO1_IO05`(RST)，
> 本方案未启用；USDHC1 的简化 pinctrl 已释放这两个 GPIO，后续可按需追加。

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
- **模块**：`CONFIG_MODULES=n`，全部驱动 built-in，不再生成 `.ko`；
- **子系统**：关闭 `MEDIA_SUPPORT`（摄像头/V4L2）、`SND`（音频）、`BT`、
  `CFG80211`/`WLAN`、`DRM`、`OPTEE`/`TEE`、`MXC_GPU_VIV`/`MXC_VPU`；
- **进一步关闭**：`PM_DEBUG`/`PM_TEST_SUSPEND`、`USER_NS`、
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
- **CMA 修正**：`CONFIG_ARCH_FORCE_MAX_ORDER=10`（imx_v7 原为 13）。13 会令
  `pageblock_nr_pages = 2^13 = 32MiB`，进而 `CMA_MIN_ALIGNMENT_BYTES=32MiB`，
  导致 `CONFIG_CMA_SIZE_MBYTES=16` 被向上取整为 32MiB（`dmesg` 显示
  `cma: Reserved 32 MiB`）。降到 10 后 pageblock=4MiB，CMA 恢复 16MiB；
  i.MX6ULL 无 IPU/VPU/GPU，4MiB 最大连续分配已足够。

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
   中补上 `fsl,imx6ul-ocotp` 兼容项，MAC 地址可从 OCOTP 读取。

### 7.5 模块裁剪结果

最终决定：**不需要任何 .ko**，`CONFIG_MODULES=n`。

- 保留为 built-in：USB ACM/Serial/FTDI、USB Gadget/ConfigFS、RNG、VLAN、
  FAT16、BINFMT_MISC、CRC32C、CAN/FLEXCAN、UART3、I2C2、KEY0、
  iptables + nftables、IPv6、NFS、USB Storage、KEXEC/CRASH_DUMP、
  CGROUPS/NAMESPACES、FTRACE/DYNAMIC_DEBUG；
- 删除：USB 4G/WWAN、USB 网卡、AF_ALG/KTLS、CAAM、MD/DM、RPMSG/SIOX、
  PS/2、测试模块、传统加密算法；
- 裁剪前的 101 个 .ko 逐项分析见 [`模块裁剪评估.md`](模块裁剪评估.md)；
- 实测模块数从 101 降到 0，zImage 7.0MiB，vmlinux 18MiB。

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
| `drivers/video/logo/logo_mini_clut224.ppm` | 新增，P3 ASCII PPM，840x480，224 色，白底 |
| `drivers/video/logo/Kconfig` | 新增 `CONFIG_LOGO_MINI_CLUT224` |
| `drivers/video/logo/Makefile` | 新增 `logo_mini_clut224.o`（.c 由 `pnmtologo` 自动生成） |
| `include/linux/linux_logo.h` | 新增 `extern const struct linux_logo logo_mini_clut224;` |
| `drivers/video/logo/logo.c` | `depth >= 8` 分支末尾优先返回板级 logo |
| defconfig | `LOGO_MINI_CLUT224=y`，关闭 mono/vga16/clut224 三个标准 logo |

图片生成（源图 `linux_logo.png`，2656x1600 RGBA 白底）：

```text
等比缩放 797x480 → 居中贴到 840x480 纯白画布（不变形、左右各 21px 白边）
→ MEDIANCUT 量化 224 色、无抖动（白底不产生噪点）
→ 强制调色板最接近白的项为纯 (255,255,255)
→ 输出 P3 PPM（pnmtologo 不接受 PNG/P6 二进制 PNM）
→ 840*480 = 403200 字节数据 + 224*3 字节 clut，编进 __initconst
```

**"只显示图片、不要 VT 终端"的实现**：内核 logo 由
`fbcon_switch() → fb_show_logo()` 绘制，因此 `CONFIG_VT` 与
`CONFIG_FRAMEBUFFER_CONSOLE` 必须保留；做法是"不给 fbcon 任何文字/光标"：

- 全屏 480px → `logo_lines = 30`，`vc_top = 30 = vc_bottom`，文字区 0 行；
  `fb_show_logo` 画完白图后 `update_region()` 长度为 0，不覆盖图案；
- `console=ttymxc0` 保持单 console，printk 不进 LCD；
- `inittab` 只在 `ttymxc0` 起 shell，不在 tty1 起 getty；
- `CONFIG_CMDLINE_EXTEND=y` +
  `CONFIG_CMDLINE="vt.global_cursor_default=0 consoleblank=0"`：
  U-Boot bootargs 仍完整（root/mtdparts/console），内核追加这两个参数，
  关掉下划线光标与 10 分钟自动黑屏（`blank_screen` 会清掉图片）；
- `CONFIG_ARCH_FORCE_MAX_ORDER=10` 保证 CMA 是 16MiB，全屏 logo 能分配成功。

> 注意：`vt.global_cursor_default` 使 `vc_deccm=0`，`fbcon_cursor()` 直接
> 返回，闪烁 work 不启动。若以后想恢复光标，去掉该参数即可。
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
lcdif:           enable-gpio = <&gpio5 9 GPIO_ACTIVE_HIGH>
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
4. **LCD 时序**：`hactive = 840` 来自 U-Boot 提交，若屏幕为 800x480 需两端同步修改。
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
8. **未启用外设**：最小 DTS 只保留启动/显示/网络/NAND/TF/USB/LED/BEEP。CAN、RS485、
   触摸屏、SDIO WiFi、摄像头、音频均未启用；需要时按 6.7 的引脚说明追加节点，
   并同步打开对应内核配置（如 `CONFIG_CAN`、`CONFIG_TOUCHSCREEN_GOODIX`、
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
| 1 个摄像头模块接口（板上无传感器） | 未启用 CSI（接 OV5640 时再打开 MEDIA_SUPPORT） |
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
| 1 个 RTC 后备电池座（带电池） | SNVS RTC |
| 1 个复位按钮（复位 MPU 和 LCD） | 硬件 |
| 1 个 ON/OFF 按钮 | 硬件 |
| 1 个功能按钮 | 已启用（gpio-keys KEY0，GPIO1_IO18） |
| 1 个电源开关 | 硬件 |
| 1 个 SDIO WIFI 接口 | 未启用（与 NAND 引脚复用） |
| 1 个 10P JTAG 接口（JLINK 等） | 调试用，无内核节点 |

> 官方底板资源列表没有单列 LCD 接口；实机 U-Boot 输出 `840 x 480`，本方案仍按
> RGB LCD 存在配置（PWM1 背光、GPIO5_IO09 复位）。触摸屏为 LCD 模块选配，
> 使用 I2C2，INT=GPIO1_IO09，RST=GPIO1_IO05，当前未启用。

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
