#!/usr/bin/env bash
# Build ZirconOS C boot stub (AevOS-style) for LoongArch64 UEFI.
# No gnu-efi - produces EFI that loads on QEMU_EFI.fd.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
STUB_DIR="${_REPO_ROOT}/boot/stub"
OUT="${1:-${_REPO_ROOT}/build/tmp/zbm-loongarch64.efi}"

if command -v loongarch64-linux-gnu-gcc &>/dev/null; then
	CC="loongarch64-linux-gnu-gcc"
elif command -v zig &>/dev/null; then
	CC="zig cc -target loongarch64-linux-gnu"
else
	echo "[ZirconOS] ERROR: need loongarch64-linux-gnu-gcc or zig" >&2
	exit 1
fi
LD="${LOONGARCH64_LD:-loongarch64-linux-gnu-ld}"
OC="${LOONGARCH64_OBJCOPY:-loongarch64-linux-gnu-objcopy}"

for cmd in "$LD" "$OC"; do
	if ! command -v $cmd &>/dev/null; then
		echo "[ZirconOS] ERROR: $cmd not found. Install: sudo apt install binutils-loongarch64-linux-gnu" >&2
		exit 1
	fi
done

BUILD_DIR="$(dirname "$OUT")"
mkdir -p "$BUILD_DIR"
# 头文件固定由 sync 写在仓库 build/tmp（与 OUT 所在目录无关）
PREF_DIR="${_REPO_ROOT}/build/tmp"
PREF_H="${PREF_DIR}/zircon_pref_fb.h"

echo "[ZirconOS] Building C stub (AevOS-style) for LoongArch64 UEFI..."

if [[ ! -f "$PREF_H" ]]; then
	echo "[ZirconOS] ERROR: missing $PREF_H" >&2
	echo "  Run: make build   (sync_resolution_config.py generates it from build.conf or RESOLUTION=)" >&2
	exit 1
fi

# zig cc 需要 -fPIC 用于 shared object；gcc 可用 -fno-pic（AevOS 风格）
PIC_FLAG="-fno-pic"
if [[ "$CC" == *"zig"* ]]; then
	PIC_FLAG="-fPIC"
fi
$CC -std=c17 -O2 -Wall -Wextra \
	-ffreestanding -fno-stack-protector $PIC_FLAG -fshort-wchar \
	-mno-lsx -mno-lasx \
	-I"$PREF_DIR" -I"$STUB_DIR" \
	-c "$STUB_DIR/efi_stub.c" -o "$BUILD_DIR/efi_stub.o"
$CC -c "$STUB_DIR/reloc_dummy.S" -o "$BUILD_DIR/reloc_dummy.o"

"$LD" -nostdlib -znocombreloc -shared -Bsymbolic \
	-T "$STUB_DIR/linker_stub.lds" \
	"$BUILD_DIR/efi_stub.o" "$BUILD_DIR/reloc_dummy.o" \
	-o "$BUILD_DIR/stub.so"

$OC -j .text -j .sdata -j .data -j .rodata \
	-j .dynamic -j .dynsym -j .rel -j .rela -j .reloc \
	-j .got -j .got.plt \
	--target=pei-loongarch64 --subsystem=efi-app -S \
	"$BUILD_DIR/stub.so" "$OUT"

if [ -f "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" ]; then
	python3 "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" "$OUT" 2>/dev/null && echo "[ZirconOS] fix_pe_reloc: OK"
fi

rm -f "$BUILD_DIR/efi_stub.o" "$BUILD_DIR/reloc_dummy.o" "$BUILD_DIR/stub.so"
ls -la "$OUT"
echo "[ZirconOS] C stub EFI: $OUT"
