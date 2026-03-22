#!/usr/bin/env bash
# Build a UEFI-bootable ISO using an embedded FAT ESP image (ZBM / BOOTX64.EFI).
# Does not use GRUB. Requires: dd, mkfs.vfat (dosfstools), mcopy (mtools), xorriso.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <output.iso> <path/to/kernel.elf> <path/to/BOOTX64.EFI>" >&2
  exit 1
fi

OUT_ISO="$1"
KERNEL_ELF="$2"
BOOT_EFI="$3"

if [ ! -f "$KERNEL_ELF" ] || [ ! -f "$BOOT_EFI" ]; then
  echo "error: missing kernel or EFI file" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ISO_ROOT="$WORKDIR/isofs"
mkdir -p "$ISO_ROOT"

ESP_IMG="$ISO_ROOT/esp.img"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=64 status=none
mkfs.vfat "$ESP_IMG" >/dev/null

mmd -i "$ESP_IMG" ::/EFI ::/EFI/BOOT ::/boot 2>/dev/null || true
mcopy -i "$ESP_IMG" "$BOOT_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$KERNEL_ELF" ::/boot/kernel.elf

mkdir -p "$(dirname "$OUT_ISO")"
# -e path is relative to the directory tree passed as the last argument
xorriso -as mkisofs \
  -o "$OUT_ISO" \
  -V 'ZIRCON_AERO' \
  -iso-level 3 \
  -full-iso9660-filenames \
  -R -J -joliet-long \
  -e esp.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$ISO_ROOT"

echo "[mkiso-uefi-zbm] wrote $OUT_ISO"
