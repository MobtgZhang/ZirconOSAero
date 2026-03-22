#!/usr/bin/env bash
# Build a GPT-partitioned FAT32 ESP image for LoongArch QEMU UEFI.
# Superfloppy (mformat on whole disk) is often invisible to EDK2; GPT+EFI System is required.
#
# LoongArch64 在本仓库仅支持 ZBM + UEFI：BOOTLOONGARCH64.EFI 由 ZBM（Zig + GNU-EFI）生成。
# UEFI 默认可移动介质路径：\EFI\BOOT\BOOTLOONGARCH64.EFI；缺失则进入固件内置 Shell。
#
# Usage: mkesp_loongarch64.sh <out.img> <kernel.elf> [BOOTLOONGARCH64.EFI]
# Env:
#   ZBM_LOONGARCH64_EFI — 必选（与 Makefile 传入一致）；ZBM 构建的引导程序
#   ZIRCON_BUILD_TMP — 默认 <repo>/build/tmp
#   LOONGARCH_SHELL_EFI — 可选：复制到 EFI/BOOT/SHELL.EFI（默认与 firmware 中 Shell 相同）
#
# Requires: dd, sgdisk (gdisk), mkfs.fat (dosfstools), mtools (mcopy/mmd)

set -euo pipefail

OUT="${1:?output image path}"
KERNEL="${2:-}"
USER_BOOT_EFI="${3:-}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
_BUILD_TMP="${ZIRCON_BUILD_TMP:-${_ROOT}/build/tmp}"
mkdir -p "${_BUILD_TMP}"

BOOTLOADER="${BOOTLOADER:-zbm}"
ZBM_LOONGARCH64_EFI="${ZBM_LOONGARCH64_EFI:-}"

BOOT_EFI=""
if [ "${BOOTLOADER}" = "zbm" ] && [ -n "${ZBM_LOONGARCH64_EFI}" ] && [ -f "${ZBM_LOONGARCH64_EFI}" ]; then
	BOOT_EFI="${ZBM_LOONGARCH64_EFI}"
	echo "[ZirconOS] ESP: ZBM → BOOTLOONGARCH64.EFI (${BOOT_EFI})"
fi

if [ "${BOOTLOADER}" = "zbm" ] && [ -z "${BOOT_EFI}" ]; then
	echo "[ZirconOS] ERROR: LoongArch64 需要 ZBM EFI（本架构不支持 GRUB）。" >&2
	echo "  运行: make build-zbm-loongarch-uefi（需 zig + fetch-gnu-efi + 支持 efi-app-loongarch64 的 objcopy）" >&2
	echo "  或设置 ZBM_LOONGARCH64_EFI 为有效的 .efi 路径。" >&2
	exit 1
fi

# 可选：用户显式传入第三个参数作为引导 EFI
if [ -z "${BOOT_EFI}" ] && [ -n "${USER_BOOT_EFI}" ] && [ -f "${USER_BOOT_EFI}" ]; then
	BOOT_EFI="${USER_BOOT_EFI}"
fi

# 回退：固件目录中的 Shell（仅作辅助，非 ZBM）
if [ -z "${BOOT_EFI}" ]; then
	for f in \
		"${_ROOT}/firmware/BOOTLOONGARCH64.EFI" \
		"${HOME}/Firmware/LoongArchVirtMachine/BOOTLOONGARCH64.EFI"; do
		if [ -f "$f" ]; then
			BOOT_EFI="$f"
			echo "[ZirconOS] WARNING: 使用固件目录中的 BOOTLOONGARCH64.EFI（非 ZBM）: ${BOOT_EFI}" >&2
			break
		fi
	done
fi

SHELL_SRC="${LOONGARCH_SHELL_EFI:-}"
if [ -z "${SHELL_SRC}" ] || [ ! -f "${SHELL_SRC}" ]; then
	for f in \
		"${_ROOT}/firmware/BOOTLOONGARCH64.EFI" \
		"${HOME}/Firmware/LoongArchVirtMachine/BOOTLOONGARCH64.EFI"; do
		if [ -f "$f" ]; then
			SHELL_SRC="$f"
			break
		fi
	done
fi

DISK_MB="${ESP_DISK_MB:-64}"
TOTAL_SECTORS=$((DISK_MB * 1024 * 1024 / 512))

if ! command -v sgdisk >/dev/null 2>&1; then
	echo "[ZirconOS] sgdisk not found (install: gdisk / gptfdisk)" >&2
	exit 1
fi
if ! command -v mkfs.fat >/dev/null 2>&1; then
	echo "[ZirconOS] mkfs.fat not found (install: dosfstools)" >&2
	exit 1
fi

if [ -f "$OUT" ] && command -v fuser >/dev/null 2>&1; then
	if fuser -v "$OUT" 2>&1 | grep -qi qemu; then
		echo "[ZirconOS] ERROR: ${OUT} 仍被 QEMU 占用，请先结束 qemu-system-loongarch64 再执行 make build-esp。" >&2
		fuser -v "$OUT" 2>/dev/null || true
		exit 1
	fi
fi

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$DISK_MB" status=none
sgdisk -n "1:2048:0" -t "1:EF00" -c "1:EFI System" "$OUT" >/dev/null 2>&1

PART_KB=$(( (TOTAL_SECTORS - 2048) * 512 / 1024 ))
TMP="$(mktemp /tmp/mkesp.XXXXXX.fat)"
rm -f "$TMP"
mkfs.fat -C "$TMP" "$PART_KB"
dd if="$TMP" of="$OUT" bs=512 seek=2048 conv=notrunc status=none
rm -f "$TMP"

OFF=$((2048 * 512))
export MTOOLS_SKIP_CHECK=1

mmd -i "$OUT@@$OFF" ::/EFI 2>/dev/null || true
mmd -i "$OUT@@$OFF" ::/EFI/BOOT

if [ -n "${BOOT_EFI}" ] && [ -f "${BOOT_EFI}" ]; then
	mcopy -i "$OUT@@$OFF" "$BOOT_EFI" ::/EFI/BOOT/BOOTLOONGARCH64.EFI
	echo "[ZirconOS] ESP: installed BOOTLOONGARCH64.EFI from ${BOOT_EFI}"
else
	echo "[ZirconOS] WARNING: No BOOTLOONGARCH64.EFI — UEFI will not use default boot path." >&2
	echo "[ZirconOS] Run: make fetch-firmware   OR   make build-zbm-loongarch-uefi" >&2
fi

if [ -n "${SHELL_SRC}" ] && [ -f "${SHELL_SRC}" ]; then
	mcopy -i "$OUT@@$OFF" "$SHELL_SRC" ::/EFI/BOOT/SHELL.EFI
	echo "[ZirconOS] ESP: installed SHELL.EFI from ${SHELL_SRC}"
fi

if [ -n "${KERNEL}" ] && [ -f "${KERNEL}" ]; then
	_sz="$(du -h "${KERNEL}" 2>/dev/null | cut -f1 || echo "?")"
	echo "[ZirconOS] ESP: copying kernel → /boot/kernel.elf (${_sz}) ..."
	mmd -i "$OUT@@$OFF" ::/boot 2>/dev/null || true
	mcopy -i "$OUT@@$OFF" "$KERNEL" ::/boot/kernel.elf
	echo "[ZirconOS] ESP: kernel installed"
fi

# 与 x86 UEFI ESP 一致：不安装 startup.nsh；默认可移动介质路径 \EFI\BOOT\BOOTLOONGARCH64.EFI 由固件直接加载 ZBM。
