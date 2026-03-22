#!/usr/bin/env bash
# Build ZirconOS Zig ZBM as LoongArch64 UEFI (AevOS-style: linker_stub.lds, no gnu-efi).
# Replaces C stub - produces EFI that loads on QEMU_EFI.fd.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
OUT="${1:-${_REPO_ROOT}/build/tmp/zbm-loongarch64.efi}"

BUILD_DIR="$(dirname "$OUT")"
mkdir -p "$BUILD_DIR"

# Use existing zbm_loongarch64.o from make build, or build it
ZIG_O="${_REPO_ROOT}/build/tmp/kernel-prefix/zbm_loongarch64.o"
if [ ! -f "$ZIG_O" ]; then
    ZIG_O="${_REPO_ROOT}/zig-out/zbm_loongarch64.o"
fi
if [ ! -f "$ZIG_O" ]; then
    echo "[ZirconOS] Building zbm_loongarch64.o..."
    cd "$_REPO_ROOT" && zig build -Darch=loongarch64 -Ddefault_desktop=aero
    ZIG_O="${_REPO_ROOT}/build/tmp/kernel-prefix/zbm_loongarch64.o"
    [ ! -f "$ZIG_O" ] && ZIG_O="${_REPO_ROOT}/zig-out/zbm_loongarch64.o"
fi
if [ ! -f "$ZIG_O" ]; then
    echo "[ZirconOS] ERROR: zbm_loongarch64.o not found. Run: make build ARCH=loongarch64" >&2
    exit 1
fi

# Link with AevOS-style linker script (no gnu-efi crt0)
LD="${LOONGARCH64_LD:-loongarch64-linux-gnu-ld}"
OC="${LOONGARCH64_OBJCOPY:-loongarch64-linux-gnu-objcopy}"
STUB_DIR="${_REPO_ROOT}/boot/stub"

for cmd in "$LD" "$OC"; do
    if ! command -v $cmd &>/dev/null; then
        echo "[ZirconOS] ERROR: $cmd not found. Install: sudo apt install binutils-loongarch64-linux-gnu" >&2
        exit 1
    fi
done

echo "[ZirconOS] Building Zig ZBM stub (AevOS-style) for LoongArch64 UEFI..."

# Assemble reloc_dummy for .reloc section
if command -v loongarch64-linux-gnu-gcc &>/dev/null; then
    loongarch64-linux-gnu-gcc -c "$STUB_DIR/reloc_dummy.S" -o "$BUILD_DIR/reloc_dummy.o"
elif command -v zig &>/dev/null; then
    zig cc -target loongarch64-linux-gnu -c "$STUB_DIR/reloc_dummy.S" -o "$BUILD_DIR/reloc_dummy.o"
elif command -v loongarch64-linux-gnu-as &>/dev/null; then
    loongarch64-linux-gnu-as -o "$BUILD_DIR/reloc_dummy.o" "$STUB_DIR/reloc_dummy.S"
else
    echo "[ZirconOS] ERROR: need loongarch64-linux-gnu-gcc, zig, or loongarch64-linux-gnu-as" >&2
    exit 1
fi

"$LD" -nostdlib -znocombreloc -shared -Bsymbolic \
    -T "$STUB_DIR/linker_stub.lds" \
    "$ZIG_O" "$BUILD_DIR/reloc_dummy.o" \
    -o "$BUILD_DIR/zbm_stub.so"

$OC -j .text -j .sdata -j .data -j .rodata \
    -j .dynamic -j .dynsym -j .rel -j .rela -j .reloc \
    -j .got -j .got.plt \
    --target=pei-loongarch64 --subsystem=efi-app -S \
    "$BUILD_DIR/zbm_stub.so" "$OUT"

if [ -f "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" ]; then
    python3 "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" "$OUT" 2>/dev/null && echo "[ZirconOS] fix_pe_reloc: OK"
fi

rm -f "$BUILD_DIR/reloc_dummy.o" "$BUILD_DIR/zbm_stub.so"
ls -la "$OUT"
echo "[ZirconOS] Zig ZBM EFI: $OUT"
