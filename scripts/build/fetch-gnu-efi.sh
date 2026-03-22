#!/usr/bin/env bash
# 从 rhboot/gnu-efi 源码仅构建 loongarch64 的 lib + gnuefi（不构建 apps），
# 使用 zig cc 作交叉编译器 + 宿主 ar/ranlib，无需安装 gcc-loongarch64-linux-gnu。
# 输出到 gnu-efi/loongarch64-built/（供 zbm-loongarch64-efi.sh）。
#
# Usage: fetch-gnu-efi.sh [OUTPUT_DIR]
#   OUTPUT_DIR 默认: <repo>/gnu-efi/loongarch64-built

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
DEST="${1:-${_ROOT}/gnu-efi/loongarch64-built}"
SRC="${_ROOT}/gnu-efi/src"
OUT="${DEST}"

if ! command -v zig >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: zig not found in PATH." >&2
	exit 1
fi

mkdir -p "${_ROOT}/gnu-efi"
if [ ! -d "${SRC}/.git" ]; then
	echo "[ZirconOS] Cloning gnu-efi → ${SRC} ..."
	rm -rf "${SRC}"
	git clone --depth 1 https://github.com/rhboot/gnu-efi.git "${SRC}"
fi

WRAPPER_DIR="$(mktemp -d)"
trap 'rm -rf "${WRAPPER_DIR}"' EXIT

cat > "${WRAPPER_DIR}/loongarch64-linux-gnu-gcc" <<'EOF'
#!/bin/bash
exec zig cc -target loongarch64-linux-gnu "$@"
EOF
chmod +x "${WRAPPER_DIR}/loongarch64-linux-gnu-gcc"

ln -sf "$(command -v ar)" "${WRAPPER_DIR}/loongarch64-linux-gnu-ar"
ln -sf "$(command -v ranlib)" "${WRAPPER_DIR}/loongarch64-linux-gnu-ranlib"
ln -sf "$(command -v nm)" "${WRAPPER_DIR}/loongarch64-linux-gnu-nm"

cat > "${WRAPPER_DIR}/loongarch64-linux-gnu-ld" <<'EOF'
#!/bin/bash
exec zig ld.lld "$@"
EOF
chmod +x "${WRAPPER_DIR}/loongarch64-linux-gnu-ld"

cat > "${WRAPPER_DIR}/loongarch64-linux-gnu-objcopy" <<'EOF'
#!/bin/bash
exec zig objcopy "$@"
EOF
chmod +x "${WRAPPER_DIR}/loongarch64-linux-gnu-objcopy"

export PATH="${WRAPPER_DIR}:${PATH}"

echo "[ZirconOS] Building gnu-efi (loongarch64 lib + gnuefi only)..."
cd "${SRC}"
make clean >/dev/null 2>&1 || true
make ARCH=loongarch64 CROSS_COMPILE=loongarch64-linux-gnu- lib gnuefi

mkdir -p "${OUT}"
cp -f "${SRC}/loongarch64/gnuefi/crt0-efi-loongarch64.o" "${OUT}/"
cp -f "${SRC}/gnuefi/elf_loongarch64_efi.lds" "${OUT}/"
cp -f "${SRC}/loongarch64/gnuefi/libgnuefi.a" "${OUT}/"
cp -f "${SRC}/loongarch64/lib/libefi.a" "${OUT}/"

echo "[ZirconOS] GNU-EFI LoongArch 构建产物:"
ls -la "${OUT}/crt0-efi-loongarch64.o" "${OUT}/elf_loongarch64_efi.lds" "${OUT}/libgnuefi.a" "${OUT}/libefi.a"
