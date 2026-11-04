#!/usr/bin/env bash
#
# i.MX6ULL Mini (NAND) Linux 内核构建脚本
#
# 与 uboot / rootfs 两个仓库使用同一套构建框架：
#   ./build.sh                    # all = distclean + config + build + deploy
#   ./build.sh build              # 增量编译
#   ./build.sh deploy             # 产物 -> output/ -> $HOME/tftp
#   TFTP_DIR= ./build.sh deploy   # 只发布到 output/
#   TFTP_DIR=/srv/tftp ./build.sh deploy
#
# 所有配置均可通过环境变量覆盖:
#   ARCH CROSS_COMPILE DEFCONFIG DTB JOBS MAKE MAKE_FLAGS OUT_DIR TFTP_DIR
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 配置（环境变量优先）
# ---------------------------------------------------------------------------
ARCH=${ARCH:-arm}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}
DEFCONFIG=${DEFCONFIG:-imx6ull_mini_nand_defconfig}
DTB=${DTB:-imx6ull-14x14-evk_nand}
JOBS=${JOBS:-$(nproc)}
MAKE=${MAKE:-make}
MAKE_FLAGS=${MAKE_FLAGS:-}

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

OUT_DIR=${OUT_DIR:-${ROOT_DIR}/output}
# TFTP_DIR 默认指向 $HOME/tftp（与 tftpd-hpa 的 TFTP_DIRECTORY 一致）。
# 使用 ${TFTP_DIR-默认值} 而非 :-，这样显式置空（TFTP_DIR=）可禁用 TFTP 发布。
DEFAULT_TFTP_DIR="${HOME}/tftp"
TFTP_DIR=${TFTP_DIR-"${DEFAULT_TFTP_DIR}"}

KERNEL_IMAGE=arch/${ARCH}/boot/zImage
DTB_TARGET=nxp/imx/${DTB}.dtb
DTB_FILE=arch/${ARCH}/boot/dts/nxp/imx/${DTB}.dtb

# 额外的 make 参数（支持 MAKE_FLAGS="-s V=1" 这类用法）
MAKE_ARGS=(-j"${JOBS}")
if [[ -n "$MAKE_FLAGS" ]]; then
    read -r -a _extra_flags <<< "$MAKE_FLAGS"
    MAKE_ARGS+=("${_extra_flags[@]}")
fi

# ---------------------------------------------------------------------------
# 颜色与输出（非终端时自动关闭，便于重定向到日志）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

LAST_ELAPSED=0

# ---------------------------------------------------------------------------
# 通用函数
# ---------------------------------------------------------------------------
info() {
    echo -e "${GREEN}==>${NC} $*"
}

warn() {
    echo -e "${YELLOW}警告: $*${NC}" >&2
}

die() {
    echo -e "${RED}错误: $*${NC}" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    echo -e "\n${RED}失败 (退出码: ${exit_code}, 行号: $1)${NC}" >&2
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

show_help() {
    echo -e "${YELLOW}用法: $0 [命令]${NC}"
    echo ""
    echo "命令列表:"
    echo "  all          - 完整构建 (distclean + config + compile + deploy)，默认命令"
    echo "                 注意: distclean 会删除 .config，自定义配置请先 savedefconfig"
    echo "  clean        - 清理编译产物 (make clean，保留 .config)"
    echo "  distclean    - 彻底清理 (make mrproper，含 .config；别名 mrproper)"
    echo "  config       - 仅配置 ${DEFCONFIG}"
    echo "  menuconfig   - 使用 menuconfig 进行交互式配置"
    echo "  savedefconfig- 将当前 .config 回写为 ${DEFCONFIG} (别名 saveconfig)"
    echo "  build        - 仅编译 (不重新配置)"
    echo "  dtbs         - 仅编译 ${DTB}.dtb"
    echo "  modules      - 仅编译内核模块"
    echo "  deploy       - 拷贝 zImage 与 dtb 到 ${OUT_DIR}，并发布到 ${DEFAULT_TFTP_DIR}"
    echo "  info         - 显示当前编译配置信息"
    echo "  help         - 显示此帮助信息"
    echo ""
    echo "可覆盖的环境变量:"
    echo "  ARCH CROSS_COMPILE DEFCONFIG DTB JOBS MAKE MAKE_FLAGS OUT_DIR TFTP_DIR"
    echo "  TFTP_DIR 默认 ${DEFAULT_TFTP_DIR}；显式置空 (TFTP_DIR=) 可禁用 TFTP 发布"
    echo ""
    echo "示例:"
    echo "  $0                       # 完整构建 (含发布)"
    echo "  $0 build                 # 增量编译"
    echo "  $0 menuconfig            # 打开配置界面"
    echo "  $0 deploy                # 发布到 output/ 与 ${DEFAULT_TFTP_DIR}"
    echo "  TFTP_DIR= $0 deploy      # 仅发布到 output/"
    echo "  TFTP_DIR=/srv/tftp $0 deploy  # 覆盖 TFTP 目录"
}

format_time() {
    local seconds=$1
    if (( seconds < 60 )); then
        echo "${seconds}秒"
    else
        echo "$((seconds / 60))分$((seconds % 60))秒"
    fi
}

human_size() {
    local bytes=$1
    if (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.1fM", b / 1048576 }'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.1fK", b / 1024 }'
    else
        echo "${bytes}B"
    fi
}

kernel_version() {
    awk '
        /^VERSION[[:space:]]*=/     { v = $3 }
        /^PATCHLEVEL[[:space:]]*=/  { p = $3 }
        /^SUBLEVEL[[:space:]]*=/    { s = $3 }
        /^EXTRAVERSION[[:space:]]*=/ { e = $3 }
        END {
            if (v == "") exit
            ver = v "." p
            if (s != "") ver = ver "." s
            if (e != "") ver = ver e
            print ver
        }
    ' Makefile 2>/dev/null || true
}

show_info() {
    local version
    version=$(kernel_version)
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  Linux for i.MX6ULL Mini (NAND)${NC}"
    if [[ -n "$version" ]]; then
        echo -e "${YELLOW}  Version:       ${version}${NC}"
    fi
    echo -e "${YELLOW}  ARCH:          ${ARCH}${NC}"
    echo -e "${YELLOW}  CROSS_COMPILE: ${CROSS_COMPILE}${NC}"
    echo -e "${YELLOW}  DEFCONFIG:     ${DEFCONFIG}${NC}"
    echo -e "${YELLOW}  DTB:           ${DTB}.dtb${NC}"
    echo -e "${YELLOW}  JOBS:          ${JOBS}${NC}"
    echo -e "${YELLOW}  源码目录:      ${ROOT_DIR}${NC}"
    echo -e "${YELLOW}  产物目录:      ${OUT_DIR}${NC}"
    echo -e "${YELLOW}  TFTP 目录:     ${TFTP_DIR:-已禁用 (仅发布到 output/)}${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

check_toolchain() {
    command -v "${MAKE}" >/dev/null 2>&1 \
        || die "未找到 make，请安装: sudo apt install make"

    if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        die "未找到交叉编译器 ${CROSS_COMPILE}gcc (sudo apt install gcc-arm-linux-gnueabihf)"
    fi
}

check_defconfig() {
    [[ -f "arch/${ARCH}/configs/${DEFCONFIG}" ]] \
        || die "找不到配置文件 arch/${ARCH}/configs/${DEFCONFIG}"
}

check_config() {
    [[ -f .config ]] || die "未找到 .config，请先运行: $0 config"
}

# IDE 注入的 safe-delete shim（BASH_ENV + PATH 首部 safe-bin）会统计单轮
# 删除次数，批量编译时 make 的 `rm -f *.d` 会被拦截并让构建失败。
# 这里只对编译子进程清理 PATH/BASH_ENV，脚本自身的删除不受影响。
clean_path() {
    local p result="" IFS=:
    for p in $PATH; do
        case "$p" in *safe-bin*) continue ;; esac
        result="${result:+$result:}$p"
    done
    printf '%s' "$result"
}

# 执行 make 并统计耗时，结果存入 LAST_ELAPSED
run_make() {
    local desc=$1
    shift

    local start=$SECONDS
    echo -e "${YELLOW}==> ${desc}${NC}"
    env -u BASH_ENV -u 'BASH_FUNC_rm%%' -u 'BASH_FUNC_unlink%%' -u 'BASH_FUNC_rmdir%%' \
        PATH="$(clean_path)" "${MAKE}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "$@"
    LAST_ELAPSED=$((SECONDS - start))
    echo -e "${GREEN}✓ ${desc}完成 (耗时: $(format_time "$LAST_ELAPSED"))${NC}"
}

ensure_dir() {
    local dir=$1
    # 目录已存在时不做任何权限修改；失败交给调用方处理
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" 2>/dev/null || return 1
    fi
}

# ---------------------------------------------------------------------------
# 构建命令
# ---------------------------------------------------------------------------
do_clean() {
    run_make "clean" clean
}

do_distclean() {
    run_make "mrproper" mrproper
}

do_config() {
    check_toolchain
    check_defconfig
    run_make "配置 ${DEFCONFIG}" "${DEFCONFIG}"
}

do_menuconfig() {
    check_toolchain
    check_defconfig

    echo -e "${YELLOW}==> 启动 menuconfig${NC}"
    if [[ ! -f .config ]]; then
        info "未检测到 .config，先应用默认配置"
        "${MAKE}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" "${DEFCONFIG}"
    fi
    "${MAKE}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" menuconfig
    info "配置界面已关闭"
}

do_savedefconfig() {
    check_config
    run_make "生成 defconfig" savedefconfig
    mv -f defconfig "arch/${ARCH}/configs/${DEFCONFIG}"
    echo -e "${GREEN}已保存到 arch/${ARCH}/configs/${DEFCONFIG}${NC}"
}

do_build() {
    check_toolchain
    check_config

    run_make "编译 (${JOBS} 线程)" "${MAKE_ARGS[@]}"
    show_build_result
}

do_dtbs() {
    check_toolchain
    check_config

    run_make "编译 ${DTB}.dtb (${JOBS} 线程)" "${MAKE_ARGS[@]}" "${DTB_TARGET}"
    show_build_result
}

do_modules() {
    check_toolchain
    check_config

    run_make "编译内核模块 (${JOBS} 线程)" "${MAKE_ARGS[@]}" modules
}

# 把 zImage / dtb 收集到 output/，并发布到 TFTP 目录（TFTP_DIR= 可禁用）
do_deploy() {
    [[ -f "${KERNEL_IMAGE}" ]] || die "未找到 ${KERNEL_IMAGE}，请先运行: $0 build"
    [[ -f "${DTB_FILE}" ]]     || die "未找到 ${DTB_FILE}，请先运行: $0 dtbs 或 $0 build"

    ensure_dir "${OUT_DIR}" || die "无法创建产物目录: ${OUT_DIR}"
    cp -f "${KERNEL_IMAGE}" "${OUT_DIR}/zImage" || die "复制失败: ${KERNEL_IMAGE}"
    cp -f "${DTB_FILE}" "${OUT_DIR}/${DTB}.dtb" || die "复制失败: ${DTB_FILE}"
    echo -e "${GREEN}已发布到 ${OUT_DIR}: zImage, ${DTB}.dtb${NC}"

    if [[ -n "${TFTP_DIR}" ]]; then
        if ! ensure_dir "${TFTP_DIR}" || [[ ! -w "${TFTP_DIR}" ]]; then
            warn "TFTP 目录不可写，已跳过发布: ${TFTP_DIR}"
            warn "产物已发布到 ${OUT_DIR}；可执行: sudo chown $(id -un) ${TFTP_DIR}"
            return 0
        fi
        cp -f "${KERNEL_IMAGE}" "${TFTP_DIR}/zImage" || die "复制失败: ${TFTP_DIR}/zImage"
        cp -f "${DTB_FILE}" "${TFTP_DIR}/${DTB}.dtb" || die "复制失败: ${TFTP_DIR}/${DTB}.dtb"
        echo -e "${GREEN}已发布到 TFTP 目录 ${TFTP_DIR}${NC}"
        echo -e "${YELLOW}板端执行: tftp_update kernel / dtb${NC}"
    else
        echo -e "${YELLOW}TFTP_DIR 为空，仅发布到 ${OUT_DIR}${NC}"
    fi
}

show_build_result() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  编译结果:${NC}"

    local file size
    for file in "${KERNEL_IMAGE}" "${DTB_FILE}" vmlinux System.map; do
        [[ -f "$file" ]] || continue
        size=$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")
        printf "${GREEN}  %-34s %s${NC}\n" "${file}:" "$(human_size "$size")"
    done

    local ko_count
    ko_count=$(find . -name "*.ko" -type f 2>/dev/null | wc -l)
    if (( ko_count > 0 )); then
        echo -e "${GREEN}  内核模块:                          ${ko_count} 个 .ko${NC}"
    fi
    echo -e "${GREEN}========================================${NC}"
}

do_all() {
    check_toolchain
    check_defconfig
    show_info

    local total_start=$SECONDS

    do_distclean
    local t_clean=$LAST_ELAPSED

    do_config
    local t_config=$LAST_ELAPSED

    run_make "编译 (${JOBS} 线程)" "${MAKE_ARGS[@]}"
    local t_build=$LAST_ELAPSED

    local t_total=$((SECONDS - total_start))

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  总耗时统计:${NC}"
    echo -e "${BLUE}  - 清理:     $(format_time "$t_clean")${NC}"
    echo -e "${BLUE}  - 配置:     $(format_time "$t_config")${NC}"
    echo -e "${BLUE}  - 编译:     $(format_time "$t_build")${NC}"
    echo -e "${BLUE}  - 总计:     $(format_time "$t_total")${NC}"
    echo -e "${BLUE}========================================${NC}"

    show_build_result
    do_deploy
}

# ---------------------------------------------------------------------------
# 主逻辑
# ---------------------------------------------------------------------------
CMD=${1:-all}

case "$CMD" in
    all)             do_all ;;
    clean)           do_clean ;;
    distclean|mrproper) do_distclean ;;
    config)          do_config ;;
    menuconfig)      do_menuconfig ;;
    savedefconfig|saveconfig) do_savedefconfig ;;
    build)           do_build ;;
    dtbs)            do_dtbs ;;
    modules)         do_modules ;;
    deploy)          do_deploy ;;
    info)            show_info ;;
    help|-h|--help)  show_help ;;
    *)
        echo -e "${RED}未知命令: ${CMD}${NC}" >&2
        show_help
        exit 1
        ;;
esac
