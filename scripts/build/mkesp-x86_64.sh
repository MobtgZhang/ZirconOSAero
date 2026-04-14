#!/usr/bin/env bash
# 构建 x86_64 UEFI ESP 镜像（GPT + FAT32）
# 包含 ZBM (BOOTX64.EFI) 和内核 (kernel.elf)
#
# 用法: mkesp-x86_64.sh <out.img> <kernel.elf> <BOOTX64.EFI> [startup.nsh 内容]
# 环境变量:
#   ZIRCON_BUILD_TMP - 默认 <repo>/build/tmp
#
# 依赖: dd, sgdisk (gdisk), mkfs.fat (dosfstools), mtools (mmd/mcopy)

set -euo pipefail

OUT="${1:?输出镜像路径}"
KERNEL="${2:?内核 ELF 路径}"
BOOT_EFI="${3:?BOOTX64.EFI 路径}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
_BUILD_TMP="${ZIRCON_BUILD_TMP:-${_ROOT}/build/tmp}"
mkdir -p "${_BUILD_TMP}"

if [ ! -f "${KERNEL}" ]; then
    echo "[ZirconOS] ERROR: 内核不存在: ${KERNEL}" >&2
    exit 1
fi

if [ ! -f "${BOOT_EFI}" ]; then
    echo "[ZirconOS] ERROR: BOOTX64.EFI 不存在: ${BOOT_EFI}" >&2
    exit 1
fi

DISK_MB="${ESP_DISK_MB:-256}"
TOTAL_SECTORS=$((DISK_MB * 1024 * 1024 / 512))

if ! command -v sgdisk >/dev/null 2>&1; then
    echo "[ZirconOS] sgdisk 未找到 (安装: gdisk / gptfdisk)" >&2
    exit 1
fi
if ! command -v mkfs.fat >/dev/null 2>&1; then
    echo "[ZirconOS] mkfs.fat 未找到 (安装: dosfstools)" >&2
    exit 1
fi

# 检查镜像是否被 QEMU 占用
if [ -f "$OUT" ] && command -v fuser >/dev/null 2>&1; then
    if fuser -v "$OUT" 2>&1 | grep -qi qemu; then
        echo "[ZirconOS] ERROR: ${OUT} 仍被 QEMU 占用，请先结束 qemu-system-x86_64。" >&2
        fuser -v "$OUT" 2>/dev/null || true
        exit 1
    fi
fi

echo "[ZirconOS] 构建 ESP 镜像: ${OUT} (${DISK_MB}MB)"

# 创建临时 FAT32 镜像用于 mtools 操作
_TMP_FAT="$(mktemp /tmp/mkesp.XXXXXX.fat)"
rm -f "${_TMP_FAT}"

# 计算分区大小（KiB）
PART_KB=$(( (TOTAL_SECTORS - 2048) * 512 / 1024 ))

echo "[ZirconOS] 创建 FAT32 镜像..."
mkfs.fat -C "${_TMP_FAT}" "${PART_KB}"

# 配置 mtools 使用临时 FAT32 镜像
_MTOOLS_CONF="${_BUILD_TMP}/mtools.conf"
cat > "${_MTOOLS_CONF}" << EOF
drive a: file="${_TMP_FAT}"
mtools_skip_check=1
EOF

# 创建辅助函数来运行 mtools 命令（过滤无害警告）
run_mtools() {
    MTOOLSRC="${_MTOOLS_CONF}" "$@" 2>&1 | grep -v "Cannot create entry named \. or \.\." || true
}

# 创建目录结构（注意：mtools 的 mmd 需要父目录先存在）
echo "[ZirconOS] 创建目录结构..."
run_mtools mmd a: EFI
run_mtools mmd a: boot
run_mtools mmd a: EFI/BOOT

# 复制 ZBM 引导程序
echo "[ZirconOS] ESP: 复制 BOOTX64.EFI..."
run_mtools mcopy -p -n -i a: "$BOOT_EFI" a:/EFI/BOOT/BOOTX64.EFI
echo "[ZirconOS] ESP: 已安装 BOOTX64.EFI"

# 复制内核
_sz="$(du -h "${KERNEL}" 2>/dev/null | cut -f1 || echo "?")"
echo "[ZirconOS] ESP: 复制内核 → /boot/kernel.elf (${_sz}) ..."
run_mtools mcopy -p -n -i a: "$KERNEL" a:/boot/kernel.elf
echo "[ZirconOS] ESP: 内核已安装"

# 创建 startup.nsh 自动执行 ZBM
_STARTUP_NSH="$(mktemp)"
{
    printf '%s\r\n' 'fs0:'
    printf '%s\r\n' 'cd \EFI\BOOT'
    printf '%s\r\n' 'BOOTX64.EFI'
} > "${_STARTUP_NSH}"
run_mtools mcopy -p -n -i a: "${_STARTUP_NSH}" a:/startup.nsh
rm -f "${_STARTUP_NSH}"
echo "[ZirconOS] ESP: startup.nsh → ZBM 操作系统选择菜单"

# 清理临时 mtools 配置
rm -f "${_MTOOLS_CONF}"

# 创建目标磁盘镜像并写入分区表和 FAT32 镜像
echo "[ZirconOS] 写入磁盘镜像..."
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$DISK_MB" status=progress

# 创建 GPT 分区表，EFI 系统分区从扇区 2048 开始
sgdisk -n "1:2048:0" -t "1:EF00" -c "1:EFI System" "$OUT"

# 将 FAT32 镜像复制到分区位置
dd if="${_TMP_FAT}" of="$OUT" bs=512 seek=2048 conv=notrunc status=progress
rm -f "${_TMP_FAT}"

echo "[ZirconOS] ESP 镜像构建完成: ${OUT}"
