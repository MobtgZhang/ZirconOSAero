#!/usr/bin/env bash
set -euo pipefail

# ZirconOS — Fetch EDK2 nightly firmware for QEMU
# Downloads OVMF/UEFI firmware for x86_64, aarch64, and loongarch64
# Source: https://retrage.github.io/edk2-nightly/

_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FIRMWARE_DIR="${1:-${_REPO}/firmware}"
BASE_URL="https://retrage.github.io/edk2-nightly/bin"

mkdir -p "$FIRMWARE_DIR"

echo "[ZirconOS] Downloading EDK2 nightly firmware to $FIRMWARE_DIR ..."

# ── x86_64 OVMF ──
echo "  [x86_64] Downloading OVMF..."
curl -fSL -o "$FIRMWARE_DIR/OVMF_CODE-x86_64.fd" "$BASE_URL/RELEASEX64_OVMF_CODE.fd"
curl -fSL -o "$FIRMWARE_DIR/OVMF_VARS-x86_64.fd" "$BASE_URL/RELEASEX64_OVMF_VARS.fd"
echo "  [x86_64] Done."

# ── AArch64 QEMU_EFI ──
echo "  [aarch64] Downloading QEMU_EFI..."
curl -fSL -o "$FIRMWARE_DIR/QEMU_EFI-aarch64.fd" "$BASE_URL/RELEASEAARCH64_QEMU_EFI.fd"
curl -fSL -o "$FIRMWARE_DIR/QEMU_VARS-aarch64.fd" "$BASE_URL/RELEASEAARCH64_QEMU_VARS.fd"
echo "  [aarch64] Done."

# ── LoongArch64 QEMU_EFI ──
echo "  [loongarch64] Downloading QEMU_EFI..."
curl -fSL -o "$FIRMWARE_DIR/QEMU_EFI-loongarch64.fd" "$BASE_URL/RELEASELOONGARCH64_QEMU_EFI.fd"
curl -fSL -o "$FIRMWARE_DIR/QEMU_VARS-loongarch64.fd" "$BASE_URL/RELEASELOONGARCH64_QEMU_VARS.fd"
echo "  [loongarch64] Done."

# ── LoongArch64 默认引导程序（UEFI 标准路径 \EFI\BOOT\BOOTLOONGARCH64.EFI）──
# 无此文件时固件会直接进入 Shell，表现为「未识别到 EFI 应用」。此处使用 EDK2 UEFI Shell（PE）。
echo "  [loongarch64] Downloading BOOTLOONGARCH64.EFI (UEFI Shell)..."
curl -fSL -o "$FIRMWARE_DIR/BOOTLOONGARCH64.EFI" "$BASE_URL/RELEASELOONGARCH64_Shell.efi"
echo "  [loongarch64] BOOTLOONGARCH64.EFI done."

# ── RISC-V 64 VIRT ──
echo "  [riscv64] Downloading VIRT firmware..."
curl -fSL -o "$FIRMWARE_DIR/VIRT-riscv64.fd" "$BASE_URL/RELEASERISCV64_VIRT.fd"
echo "  [riscv64] Done."

echo ""
echo "[ZirconOS] All firmware downloaded successfully."
echo "  FIRMWARE_DIR = $FIRMWARE_DIR"
echo ""
echo "  x86_64:      OVMF_CODE-x86_64.fd + OVMF_VARS-x86_64.fd"
echo "  aarch64:     QEMU_EFI-aarch64.fd + QEMU_VARS-aarch64.fd"
echo "  loongarch64:  QEMU_EFI-loongarch64.fd + QEMU_VARS-loongarch64.fd + BOOTLOONGARCH64.EFI (Shell)"
echo "  riscv64:     VIRT-riscv64.fd"
