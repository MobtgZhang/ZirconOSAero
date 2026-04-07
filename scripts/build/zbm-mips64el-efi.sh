#!/usr/bin/env bash
# Link Zig 生成的 zbm_mips64el.o → BOOTMIPS64EL.EFI（GNU-EFI crt0 + 链接脚本 + objcopy）
#
# Usage:
#   zbm-mips64el-efi.sh <zbm_mips64el.o> <output.efi>

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

OBJ="${1:?Zig object (.o)}"
OUT="${2:?output .efi}"

if ! command -v mips64el-linux-gnu-gcc >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: 需要 mips64el-linux-gnu-gcc（sudo apt install gcc-mips64el-linux-gnuabi64）。" >&2
	exit 1
fi
CC=(mips64el-linux-gnu-gcc)

OC=()
if command -v mips64el-linux-gnu-objcopy >/dev/null 2>&1; then
	OC=(mips64el-linux-gnu-objcopy)
else
	for cand in llvm-objcopy llvm-objcopy-20 llvm-objcopy-19 llvm-objcopy-18; do
		if command -v "${cand}" >/dev/null 2>&1; then
			OC=("${cand}")
			echo "[ZirconOS] Using ${cand} for efi-app-mips64el"
			break
		fi
	done
fi
if [ ${#OC[@]} -eq 0 ]; then
	echo "[ZirconOS] ERROR: 需要 mips64el-linux-gnu-objcopy 或 llvm-objcopy。" >&2
	exit 1
fi

GNUEFI_LIB_DIR="${GNUEFI_LIB_DIR:-}"
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-mips64el.o" ]; then
	GNUEFI_LIB_DIR=""
	for d in \
		"${_REPO_ROOT}/gnu-efi/mips64el-built" \
		/usr/lib/gnuefi \
		/usr/lib64/gnuefi
	do
		if [ -f "$d/crt0-efi-mips64el.o" ] && [ -f "$d/elf_mips64el_efi.lds" ] && [ -f "$d/libgnuefi.a" ] && [ -f "$d/libefi.a" ]; then
			GNUEFI_LIB_DIR="$d"
			echo "[ZirconOS] GNU-EFI: ${GNUEFI_LIB_DIR}"
			break
		fi
	done
fi
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-mips64el.o" ]; then
	echo "[ZirconOS] ERROR: 缺少 MIPS64EL GNU-EFI（crt0 / lds / libgnuefi / libefi）。" >&2
	echo "  需要手动构建或从社区获取 mips64el GNU-EFI 支持文件。" >&2
	exit 1
fi

CRT0="${GNUEFI_LIB_DIR}/crt0-efi-mips64el.o"
LDS="${GNUEFI_LIB_DIR}/elf_mips64el_efi.lds"

TMP_SO="${OUT%.efi}.so"
rm -f "$TMP_SO" "$OUT"

LIBGCC="$("${CC[@]}" -print-libgcc-file-name)"
echo "[ZirconOS] GNU-EFI link (gcc): ${OBJ} → ${OUT}"
"${CC[@]}" -o "$TMP_SO" -nostdlib -Wl,-shared -Wl,-Bsymbolic \
	-Wl,-T"$LDS" \
	-Wl,"$CRT0" \
	"$OBJ" \
	-L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
	"$LIBGCC"

EFI_TARGET="efi-app-mips64el"
"${OC[@]}" \
	-j .text -j .sdata -j .data -j .dynamic -j .rodata \
	-j .rel -j .rela -j .rela.dyn -j .rela.plt \
	-j .reloc -j .dynsym -j .dynstr -j .hash -j .gnu.hash -j .eh_frame \
	--target="$EFI_TARGET" \
	"$TMP_SO" "$OUT"

if [ -f "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" ]; then
	python3 "${_REPO_ROOT}/scripts/tools/fix_pe_reloc.py" "$OUT" 2>/dev/null && echo "[ZirconOS] fix_pe_reloc: OK" || true
fi

rm -f "$TMP_SO"
ls -la "$OUT"
