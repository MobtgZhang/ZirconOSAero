#!/usr/bin/env bash
set -euo pipefail

OUT_ISO="${1:?输出 ISO 路径}"
ESP_IMAGE="${2:?ESP 镜像路径}"

if [ ! -f "${ESP_IMAGE}" ]; then
    echo "[ZirconOS] ERROR: ESP 镜像不存在: ${ESP_IMAGE}" >&2
    exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
    echo "[ZirconOS] ERROR: xorriso 未找到 (安装: xorriso)" >&2
    exit 1
fi

mkdir -p "$(dirname "${OUT_ISO}")"
rm -f "${OUT_ISO}"

# The ESP helpers create a GPT disk image whose FAT partition starts at LBA 2048.
# El Torito UEFI expects the FAT filesystem image itself, not the GPT wrapper.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zirconos-iso.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
FAT_IMAGE="${WORK_DIR}/efiboot.img"
dd if="${ESP_IMAGE}" of="${FAT_IMAGE}" bs=512 skip=2048 status=none

if [ ! -s "${FAT_IMAGE}" ]; then
    echo "[ZirconOS] ERROR: 无法从 ESP 镜像提取 FAT 分区: ${ESP_IMAGE}" >&2
    exit 1
fi

# Keep the boot image in the ISO tree so xorriso can resolve the -e path.
ISO_TREE="${WORK_DIR}/iso-tree"
mkdir -p "${ISO_TREE}"
cp "${FAT_IMAGE}" "${ISO_TREE}/efiboot.img"

xorriso -as mkisofs \
    -iso-level 3 \
    -volid ZIRCONOS_UEFI \
    -e efiboot.img \
    -no-emul-boot \
    -o "${OUT_ISO}" \
    "${ISO_TREE}"

echo "[ZirconOS] UEFI ISO 构建完成: ${OUT_ISO}"
