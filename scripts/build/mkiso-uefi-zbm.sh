#!/usr/bin/env bash
# Build a UEFI-bootable ISO using an embedded FAT ESP image (ZBM / BOOTX64.EFI).
# Does not use GRUB. Requires: dd, mkfs.vfat (dosfstools), mcopy (mtools), xorriso.
# Optional: <arch> <version> <flavor> — flavor = debug|release (kernel log policy); written to UEFI_BOOT_INFO.txt.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <output.iso> <path/to/kernel.elf> <path/to/BOOTX64.EFI> [arch [version [flavor]]]" >&2
  exit 1
fi

OUT_ISO="$1"
KERNEL_ELF="$2"
BOOT_EFI="$3"
ARCH_LABEL="${4:-x86_64}"
PROJ_VERSION="${5:-unknown}"
FLAVOR="${6:-}"

if [ ! -f "$KERNEL_ELF" ] || [ ! -f "$BOOT_EFI" ]; then
  echo "error: missing kernel or EFI file" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ISO_ROOT="$WORKDIR/isofs"
mkdir -p "$ISO_ROOT"

# Visible when mounting the ISO in the host (not inside the ESP): architecture + VirtualBox UEFI hints.
UEFI_INFO="$ISO_ROOT/UEFI_BOOT_INFO.txt"
{
  echo "ZirconOSAero — UEFI bootable optical image (ZBM, no GRUB)"
  echo "Project version: ${PROJ_VERSION}"
  echo "Target CPU architecture: ${ARCH_LABEL}"
  if [ -n "${FLAVOR}" ]; then
    echo "Build flavor: ${FLAVOR}"
    if [ "${FLAVOR}" = "debug" ]; then
      echo "Kernel/ZBM: debug build — klog to serial AND on-screen (framebuffer/VGA text) while booting."
    elif [ "${FLAVOR}" = "release" ]; then
      echo "Kernel/ZBM: release build — no on-screen klog scroll (clean display for splash/logo); serial still gets ERR+."
    else
      echo "Kernel log policy: see project Makefile (iso-debug vs iso-release)."
    fi
    echo ""
  fi
  echo "ESP (embedded esp.img): FAT32 with \\EFI\\BOOT\\BOOTX64.EFI and \\boot\\kernel.elf"
  echo ""
  echo "This mkiso path is for x86_64 UEFI (BOOTX64.EFI). Other arches: use make build-esp + QEMU."
  echo ""
  echo "--- Oracle VirtualBox (UEFI) ---"
  echo "1) VM → Settings → System → Motherboard → Enable EFI (special OSes only)."
  echo "2) Storage → optical drive → choose this .iso"
  echo "3) Boot. Guest firmware should load \EFI\BOOT\BOOTX64.EFI (OVMF/UEFI)."
  echo ""
  echo "--- 中文简要 ---"
  echo "架构: ${ARCH_LABEL}  UEFI x86_64 光盘启动。"
  echo "VirtualBox: 系统→主板→勾选「启用 EFI」；存储→光驱→选择本 ISO。"
} >"$UEFI_INFO"

ESP_IMG="$ISO_ROOT/esp.img"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=64 status=none
mkfs.vfat "$ESP_IMG" >/dev/null

mmd -i "$ESP_IMG" ::/EFI ::/EFI/BOOT ::/boot 2>/dev/null || true
mcopy -i "$ESP_IMG" "$BOOT_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMG" "$KERNEL_ELF" ::/boot/kernel.elf

mkdir -p "$(dirname "$OUT_ISO")"
# ISO9660 volume id: short, d-characters; encodes UEFI + arch for media browsers
case "${ARCH_LABEL}" in
  x86_64) VOLID='ZIRCON_UEFI_X64' ;;
  *)      VOLID='ZIRCON_UEFI' ;;
esac
# -e path is relative to the directory tree passed as the last argument
xorriso -as mkisofs \
  -o "$OUT_ISO" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -R -J -joliet-long \
  -e esp.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$ISO_ROOT"

echo "[mkiso-uefi-zbm] wrote $OUT_ISO"
