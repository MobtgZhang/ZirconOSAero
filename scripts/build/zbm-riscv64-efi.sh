#!/usr/bin/env bash
# Link Zig 生成的 zbm_riscv64.o → BOOTRISCV64.EFI（GNU-EFI crt0 + 链接脚本 + objcopy）
#
# 编译器：优先 riscv64-linux-gnu-gcc，否则 zig cc。
# GNU-EFI 文件：/usr/lib/gnuefi、make fetch-gnu-efi 生成的 gnu-efi/riscv64-built/
#
# Usage:
#   zbm-riscv64-efi.sh <zbm_riscv64.o> <output.efi>

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

OBJ="${1:?Zig object (.o)}"
OUT="${2:?output .efi}"

# ── 选择编译器 ──
CC=()
if [ -n "${RISCV64_EFI_CC:-}" ]; then
    # shellcheck disable=SC2206
    CC=( ${RISCV64_EFI_CC} )
elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then
    CC=(riscv64-linux-gnu-gcc)
elif command -v zig >/dev/null 2>&1; then
    CC=(zig cc -target riscv64-linux-gnu)
    echo "[ZirconOS] Using: zig cc -target riscv64-linux-gnu"
else
    echo "[ZirconOS] ERROR: 需要 zig 或 riscv64-linux-gnu-gcc。" >&2
    exit 1
fi

# ── objcopy（efi-app-riscv64）──
OC=()
if [ -n "${RISCV64_EFI_OBJCOPY:-}" ]; then
    # shellcheck disable=SC2206
    OC=( ${RISCV64_EFI_OBJCOPY} )
elif command -v riscv64-linux-gnu-objcopy >/dev/null 2>&1; then
    OC=(riscv64-linux-gnu-objcopy)
else
    for cand in llvm-objcopy; do
        if command -v "${cand}" >/dev/null 2>&1; then
            OC=("${cand}")
            echo "[ZirconOS] Using ${cand} for efi-app-riscv64"
            break
        fi
    done
fi
if [ ${#OC[@]} -eq 0 ]; then
    echo "[ZirconOS] ERROR: 需要支持 UEFI 的 objcopy。" >&2
    echo "  请安装其一: sudo apt install binutils-riscv64-linux-gnu" >&2
    echo "            或: sudo apt install llvm   (提供 llvm-objcopy)" >&2
    exit 1
fi

GNUEFI_LIB_DIR="${GNUEFI_LIB_DIR:-}"
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-riscv64.o" ]; then
    GNUEFI_LIB_DIR=""
    for d in \
        "${_REPO_ROOT}/gnu-efi/riscv64-built" \
        /usr/lib/gnuefi \
        /usr/lib64/gnuefi
    do
        if [ -f "$d/crt0-efi-riscv64.o" ] && [ -f "$d/elf_riscv64_efi.lds" ] && [ -f "$d/libgnuefi.a" ] && [ -f "$d/libefi.a" ]; then
            GNUEFI_LIB_DIR="$d"
            echo "[ZirconOS] GNU-EFI: ${GNUEFI_LIB_DIR}"
            break
        fi
    done
fi
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-riscv64.o" ]; then
    echo "[ZirconOS] ERROR: 缺少 RISC-V GNU-EFI（crt0 / lds / libgnuefi / libefi）。" >&2
    echo "  在本仓库执行:  make fetch-gnu-efi" >&2
    echo "  （仅需 git + zig，会从源码构建到 gnu-efi/riscv64-built/）" >&2
    exit 1
fi

CRT0="${GNUEFI_LIB_DIR}/crt0-efi-riscv64.o"
LDS="${GNUEFI_LIB_DIR}/elf_riscv64_efi.lds"

TMP_SO="${OUT%.efi}.so"
rm -f "$TMP_SO" "$OUT"

# 链接 EFI .so 文件
if [[ "$(basename "${CC[0]}")" == riscv64-linux-gnu-gcc ]]; then
    LIBGCC="$("${CC[@]}" -print-libgcc-file-name)"
    echo "[ZirconOS] GNU-EFI link (gcc): ${CC[*]} + ${OBJ} → ${OUT}"
    "${CC[@]}" -o "$TMP_SO" -nostdlib -Wl,-shared -Wl,-Bsymbolic \
        -Wl,-T"$LDS" \
        -Wl,"$CRT0" \
        "$OBJ" \
        -L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
        "$LIBGCC"
elif command -v zig >/dev/null 2>&1; then
    LIBGCC="$(zig cc -target riscv64-linux-gnu -print-libgcc-file-name)"
    echo "[ZirconOS] GNU-EFI link (zig + ld): ${OBJ} → ${OUT}"
    if command -v riscv64-linux-gnu-ld >/dev/null 2>&1; then
        riscv64-linux-gnu-ld -shared -Bsymbolic \
            -T"$LDS" \
            "$CRT0" \
            "$OBJ" \
            -L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
            "$LIBGCC" \
            -o "$TMP_SO"
    else
        # 回退到 zig ld
        zig ld -shared -Bsymbolic \
            -T"$LDS" \
            "$CRT0" \
            "$OBJ" \
            -L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
            "$LIBGCC" \
            -o "$TMP_SO"
    fi
else
    echo "[ZirconOS] ERROR: 无法链接 EFI .so：需要 riscv64-linux-gnu-gcc，或 zig。" >&2
    exit 1
fi

# objcopy 转换为 EFI 应用
EFI_TARGET="efi-app-riscv64"
EFI_OBJCOPY_EXTRA=()
_PEI_TEST="$(mktemp)"
if "${OC[@]}" -j .text --target=pei-riscv64 "$TMP_SO" "$_PEI_TEST" 2>/dev/null; then
    EFI_TARGET="pei-riscv64"
    EFI_OBJCOPY_EXTRA=(--subsystem=efi-app -j .got -j .got.plt)
    echo "[ZirconOS] Using pei-riscv64 + --subsystem=efi-app"
fi
rm -f "$_PEI_TEST"

"${OC[@]}" \
    -j .text -j .sdata -j .data -j .dynamic -j .rodata \
    -j .rel -j .rela -j .rela.dyn -j .rela.plt \
    -j .reloc -j .dynsym -j .dynstr -j .hash -j .gnu.hash -j .eh_frame \
    "${EFI_OBJCOPY_EXTRA[@]}" \
    --target="$EFI_TARGET" \
    "$TMP_SO" "$OUT"

# 修正 PE Subsystem 为 EFI_APPLICATION
if [ -f "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" ]; then
    python3 "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" "$OUT" 2>/dev/null && echo "[ZirconOS] fix_pe_reloc: OK"
fi

rm -f "$TMP_SO"
ls -la "$OUT"
