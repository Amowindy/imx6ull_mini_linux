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
| 以太网 | 仅 ENET2，RMII，PHY 地址 1（KSZ8081 兼容 ID `0022.1560`） |
| 调试串口 | UART1 / `ttymxc0`，115200 |
| 启动方式 | NAND：U-Boot 从 `0xC00000` 读内核、`0x2C00000` 读 DTB |

实测 U-Boot 启动日志与本表一致：

```text
DRAM:  256 MiB
NAND:  512 MiB
[*]-Video Link 0 (840 x 480)
Net:   eth1: ethernet@20b4000 [PRIME]
```

> NAND 容量以实机 `NAND: 512 MiB` 为准。早期文档按 256MiB 估算的
> rootfs 可用空间（192MiB）已作废，实际为 448MiB = `0x1C000000`。

U-Boot 加载地址与内核启动参数：

```text
loadaddr   = 0x80800000
fdt_addr   = 0x83000000
tee_addr   = 0x84000000
rootfs_addr= 0x85000000
bootargs   = console=ttymxc0,115200 ubi.mtd=nandrootfs root=ubi0:rootfs \
             rootfstype=ubifs mtdparts=gpmi-nand:8m(nandboot),4m(env), \
             32m(nandkernel),16m(nanddtb),4m(nandtee),-(nandrootfs)
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
| `9c1abf72` | 增加 `tftp_update` 命令（kernel/dtb/rootfs） | `build.sh deploy` 输出同名文件，供 TFTP 更新 |
| `285a7eaa` | 最终版 `build.sh`（环境变量覆盖、错误处理、耗时统计） | `build.sh` 按相同结构重写 |

## 4. 总体设计

Linux 侧不修改上游驱动的核心逻辑，优先通过设备树和内核配置完成板级适配：

1. **设备树**描述硬件差异（内存大小、LCD 时序、单网口、NAND 分区、引脚冲突）。
2. **defconfig** 选择板级驱动集合与默认启动参数。
3. **驱动**仅对 U-Boot 中有明确硬件动作、且内核缺少对应实现的部分做最小修改（LCD 复位脉冲）。
4. **构建脚本**统一编译、清理、配置、发布流程，产物命名与 U-Boot 环境变量一致。

## 5. 文件修改清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `arch/arm/configs/imx6ull_mini_nand_defconfig` | 新增 | 基于 `imx_v7_defconfig` 的板级配置 |
| `arch/arm/boot/dts/nxp/imx/imx6ull-14x14-evk_nand.dts` | 新增 | 板级设备树 |
| `arch/arm/boot/dts/nxp/imx/Makefile` | 修改 | 注册 `imx6ull-14x14-evk_nand.dtb` |
| `drivers/video/fbdev/mxsfb.c` | 修改 | 支持 LCD 复位脉冲（`enable-gpio`） |
| `build.sh` | 新增 | 内核构建脚本（对齐 U-Boot 最终版） |

生成的 dtb 文件名固定为 `imx6ull-14x14-evk_nand.dtb`，与 U-Boot 的 `dtb_file` 一致。

## 6. 设备树设计

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

ENET2 保留上游配置：`phy-mode = "rmii"`、`phy-handle = <&ethphy1>`、PHY 地址 1、`micrel,led-mode` 与 `rmii-ref` 时钟。

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
| `nandboot` | `0x00000000` | 8MB |
| `env` | `0x00800000` | 4MB |
| `nandkernel` | `0x00C00000` | 32MB |
| `nanddtb` | `0x02C00000` | 16MB |
| `nandtee` | `0x03C00000` | 4MB |
| `nandrootfs` | `0x04000000` | 剩余空间：512MiB NAND 时为 448MiB = `0x1C000000` |

设备树中定义 `fixed-partitions` 作为无 `mtdparts` 时的后备。`CONFIG_MTD_CMDLINE_PARTS=y` 时 `cmdlinepart` 优先于 `ofpart`，正常启动由 U-Boot 传入的 `mtdparts` 接管，rootfs 按 `-(nandrootfs)` 自动取剩余空间（512MiB 板为 448MiB）。

`fixed-partitions` 无法表达「占满剩余空间」，后备值只能按 512MiB 实机容量写死；这是整个设计里唯一残留的容量假设，已集中为 `NAND_ROOTFS_SIZE`，换用其它容量 NAND 时必须同步修改。`nandboot` / `env` 标记为 `read-only`，避免 Linux 侧误擦 bootloader 与环境变量：

```dts
#define NAND_ROOTFS_SIZE 0x1c000000  /* 448MiB = 512MiB NAND - 64MiB 前置分区 */
partition@0 {
	label = "nandboot";
	reg = <0x00000000 0x00800000>;
	read-only;
};
...
partition@4000000 {
	label = "nandrootfs";
	reg = <0x04000000 NAND_ROOTFS_SIZE>;
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

相对 `imx_v7_defconfig` 仅追加以下内容：

```text
CONFIG_LOCALVERSION="-imx6ull-mini-nand"
CONFIG_CMDLINE="noinitrd console=ttymxc0,115200 ubi.mtd=nandrootfs root=ubi0:rootfs rootfstype=ubifs mtdparts=gpmi-nand:8m(nandboot),4m(env),32m(nandkernel),16m(nanddtb),4m(nandtee),-(nandrootfs)"
CONFIG_CMDLINE_FROM_BOOTLOADER=y
CONFIG_FEC=y
CONFIG_SMSC_PHY=y
CONFIG_MTD_UBI_BEB_LIMIT=20
```

> 上面 `CONFIG_CMDLINE` 在 defconfig 中为同一行，此处仅为排版显示。

说明：

- `CONFIG_CMDLINE_FROM_BOOTLOADER=y`：优先使用 U-Boot 传入的 `bootargs`；上面的 `CONFIG_CMDLINE` 仅作为后备；
- `SMSC_PHY` 用于兼容板上可能出现 LAN8720A，`MICREL_PHY` 继续保留以兼容 KSZ8081；
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
| `CONFIG_MICREL_PHY` | `y` | KSZ8081 PHY |
| `CONFIG_SMSC_PHY` | `y` | LAN8720A 兼容 |
| `CONFIG_FB_MXS` | `y` | LCDIF framebuffer |
| `CONFIG_SERIAL_IMX_CONSOLE` | `y` | `ttymxc0` 控制台 |
| `CONFIG_CMDLINE_FROM_BOOTLOADER` | `y` | 使用 U-Boot 启动参数 |

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
- 完整内核构建使用独立输出目录 `O=/tmp/imx6ull_obuild`，保持源码树干净；
- 增量验证使用板级 defconfig 编译关键对象与 dtb；
- 对生成的 dtb 反编译检查关键属性，避免只验证“能编译”而不验证“内容正确”。

### 9.2 验证结果

| 验证项 | 命令 | 结果 |
|---|---|---|
| 脚本语法 | `bash -n build.sh` | 通过 |
| 配置应用 | `make imx6ull_mini_nand_defconfig` | 通过，无 override 警告 |
| 配置内容 | 检查 `.config` 关键项 | 全部符合预期 |
| 板级 dtb | `make nxp/imx/imx6ull-14x14-evk_nand.dtb` | 通过，37KB |
| dtb 属性 | `dtc -I dtb -O dts` 反编译 | 内存/分区/网络/GPIO 正确 |
| 驱动对象 | `mxsfb.o`、`gpmi-nand.o`、`fec_main.o`、`smsc.o`、`micrel.o` | 全部编译通过 |
| 完整内核 | `make O=/tmp/imx6ull_obuild -j8 zImage` | 通过，zImage 9.4MB |
| 内核版本 | `kernel.release` | `6.12.49-imx6ull-mini-nand` |
| 代码风格 | `checkpatch.pl` | 0 errors，0 warnings |
| 产物发布 | `./build.sh deploy` | 文件名与 U-Boot 环境变量一致 |

dtb 反编译确认：

```text
memory@80000000: reg = <0x80000000 0x10000000>
fec1:            status = "disabled"
ethernet-phy@2:  status = "disabled"
lcdif:           enable-gpio = <&gpio5 9 GPIO_ACTIVE_HIGH>
gpmi:            status = "okay"
分区:            nandboot/env/nandkernel/nanddtb/nandtee/nandrootfs
nandrootfs:      reg = <0x4000000 0x1c000000>  (448MiB)
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
nand read ${loadaddr} 0xC00000 0x2000000
nand read ${fdt_addr} 0x2C00000 0x100000
bootz ${loadaddr} - ${fdt_addr}
```

### 10.3 根文件系统

`nandrootfs` 分区使用 UBI + UBIFS：

```text
ubi.mtd=nandrootfs root=ubi0:rootfs rootfstype=ubifs
```

rootfs 镜像命名与 U-Boot 的 `rootfs_file` 保持一致：`rootfs_nand.ubi`。

## 11. 注意事项

1. **分区一致性**：分区布局共有四处描述，修改时必须同时更新：U-Boot
   `MFG_NAND_PARTITION`（`bootargs`）、U-Boot `CONFIG_MTDPARTS_DEFAULT`、
   内核 `CONFIG_CMDLINE`、内核设备树 `fixed-partitions`；`bootcmd` 中的
   `nand read` 偏移/长度也要跟着调整。默认环境变量改动后，板上需执行
   `env default -a; saveenv` 才会生效。
2. **rootfs 大小**：`-(nandrootfs)` 由 `cmdlinepart` 按 ONFI 探测容量动态计算，
   实机 512MiB NAND 下为 448MiB（`0x1C000000`），256MiB 下为 192MiB。
   设备树 `fixed-partitions` 无法表达「占满剩余空间」，其
   `NAND_ROOTFS_SIZE` 是本设计里**唯一写死的容量假设**（仅作后备），
   换用其它容量 NAND 时必须同步修改；它只在 cmdlinepart 未生效时起作用。
   UBI 还会扣除坏块与元数据开销，实际可用卷空间小于分区大小。
3. **UBI 镜像**：`rootfs_nand.ubi` 的体积必须小于 TFTP 下载时的可用 RAM
   （256MiB 板约 218MiB），卷使用 `autoresize=1` 在首次挂载时扩展到整个
   分区；U-Boot 侧 `tftp_update rootfs` 采用 `nand write.trimffs` 写入，
   并在擦除前校验镜像大小与 RAM 窗口。
4. **LCD 时序**：`hactive = 840` 来自 U-Boot 提交，若屏幕为 800x480 需两端同步修改。
5. **网络 PHY**：当前按 KSZ8081（`ethernet-phy-id0022.1560`）配置，同时启用 SMSC PHY 驱动以兼容 LAN8720A；若实际硬件为 LAN8720A，可根据需要把 compatible 改为 `ethernet-phy-id0007.c0f1`。
6. **`all` 会执行 `distclean`（`make mrproper`）**：自定义 `menuconfig` 配置请先执行 `./build.sh savedefconfig`，日常使用 `./build.sh build` 增量编译；`all` 结束会自动 `deploy` 到 `output/` 与 `$HOME/tftp`。
7. **DTB 命名**：内核 dtb 使用下划线 `imx6ull-14x14-evk_nand.dtb`，与 U-Boot 的 `dtb_file` 严格一致；U-Boot 自身内建 dtb 为 `imx6ull-14x14-evk-nand.dtb`（连字符，用于 U-Boot 驱动）。
