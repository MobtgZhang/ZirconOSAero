#!/usr/bin/env bash
# 从 ncroxon/gnu-efi 构建 RISC-V64 的 lib + gnuefi（rhboot 主线无 riscv64 目录）。
# 输出到 gnu-efi/riscv64-built/（供 zbm-riscv64-efi.sh）。
#
# 需要: zig、riscv64-linux-gnu-gcc（或已安装的交叉工具链）
#
# Usage: fetch-gnu-efi-riscv64.sh [OUTPUT_DIR]

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
DEST="${1:-${_ROOT}/gnu-efi/riscv64-built}"
SRC="${_ROOT}/gnu-efi/ncroxon-gnu-efi"
OUT="${DEST}"

if ! command -v zig >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: zig not found in PATH." >&2
	exit 1
fi

if ! command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: riscv64-linux-gnu-gcc not found (e.g. sudo apt install gcc-riscv64-linux-gnu)." >&2
	exit 1
fi

mkdir -p "${_ROOT}/gnu-efi"
if [ ! -d "${SRC}/.git" ]; then
	echo "[ZirconOS] Cloning ncroxon/gnu-efi (RISC-V UEFI) → ${SRC} ..."
	rm -rf "${SRC}"
	_CLONE_OK=0
	for _url in "${GNU_EFI_NC_URL:-https://github.com/ncroxon/gnu-efi.git}"; do
		if git clone --depth 1 "${_url}" "${SRC}" 2>/dev/null; then
			_CLONE_OK=1
			break
		fi
	done
	if [ "${_CLONE_OK}" -ne 1 ]; then
		echo "[ZirconOS] ERROR: git clone failed. 可手动克隆 ncroxon/gnu-efi 到 ${SRC} 后重试，或设置 GNU_EFI_NC_URL。" >&2
		exit 1
	fi
fi

echo "[ZirconOS] Building gnu-efi (riscv64 lib + gnuefi)..."
cd "${SRC}"
make clean >/dev/null 2>&1 || true
make ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- lib gnuefi

mkdir -p "${OUT}"
cp -f "${SRC}/riscv64/gnuefi/crt0-efi-riscv64.o" "${OUT}/"
cp -f "${SRC}/gnuefi/elf_riscv64_efi.lds" "${OUT}/"
cp -f "${SRC}/riscv64/gnuefi/libgnuefi.a" "${OUT}/"
cp -f "${SRC}/riscv64/lib/libefi.a" "${OUT}/"

echo "[ZirconOS] GNU-EFI RISC-V64 构建产物:"
ls -la "${OUT}/crt0-efi-riscv64.o" "${OUT}/elf_riscv64_efi.lds" "${OUT}/libgnuefi.a" "${OUT}/libefi.a"
