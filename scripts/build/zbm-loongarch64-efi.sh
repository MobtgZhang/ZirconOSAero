#!/usr/bin/env bash
# Link Zig 生成的 zbm_loongarch64.o → BOOTLOONGARCH64.EFI（GNU-EFI crt0 + 链接脚本 + objcopy）
#
# 编译器：优先 loongarch64-linux-gnu-gcc，否则 zig cc（与 make 一致，无需单独安装交叉 gcc）。
# GNU-EFI 文件：/usr/lib/gnuefi、make fetch-gnu-efi 生成的 gnu-efi/loongarch64-built/
#
# objcopy 必须支持 --target=efi-app-loongarch64（zig objcopy 不支持）：优先
#   loongarch64-linux-gnu-objcopy，其次 llvm-objcopy。
#
# Usage:
#   build_zbm_loongarch64_efi.sh <zbm_loongarch64.o> <output.efi>

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

OBJ="${1:?Zig object (.o)}"
OUT="${2:?output .efi}"

# ── 选择编译器 ──
CC=()
if [ -n "${LOONGARCH64_EFI_CC:-}" ]; then
	# shellcheck disable=SC2206
	CC=( ${LOONGARCH64_EFI_CC} )
elif command -v loongarch64-linux-gnu-gcc >/dev/null 2>&1; then
	CC=(loongarch64-linux-gnu-gcc)
elif command -v zig >/dev/null 2>&1; then
	CC=(zig cc -target loongarch64-linux-gnu)
	echo "[ZirconOS] Using: zig cc -target loongarch64-linux-gnu (libgcc 路径；EFI .so 由 gnu-ld 链接)"
else
	echo "[ZirconOS] ERROR: 需要 zig 或 loongarch64-linux-gnu-gcc。" >&2
	exit 1
fi

# ── objcopy（efi-app-loongarch64）──
OC=()
if [ -n "${LOONGARCH64_EFI_OBJCOPY:-}" ]; then
	# shellcheck disable=SC2206
	OC=( ${LOONGARCH64_EFI_OBJCOPY} )
elif command -v loongarch64-linux-gnu-objcopy >/dev/null 2>&1; then
	OC=(loongarch64-linux-gnu-objcopy)
else
	for cand in llvm-objcopy llvm-objcopy-20 llvm-objcopy-19 llvm-objcopy-18 llvm-objcopy-17; do
		if command -v "${cand}" >/dev/null 2>&1; then
			OC=("${cand}")
			echo "[ZirconOS] Using ${cand} for efi-app-loongarch64"
			break
		fi
	done
fi
if [ ${#OC[@]} -eq 0 ]; then
	echo "[ZirconOS] ERROR: 需要支持 UEFI 的 objcopy。" >&2
	echo "  请安装其一: sudo apt install binutils-loongarch64-linux-gnu" >&2
	echo "            或: sudo apt install llvm   (提供 llvm-objcopy)" >&2
	exit 1
fi

GNUEFI_LIB_DIR="${GNUEFI_LIB_DIR:-}"
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-loongarch64.o" ]; then
	GNUEFI_LIB_DIR=""
	for d in \
		"${_REPO_ROOT}/gnu-efi/loongarch64-built" \
		/usr/lib/gnuefi \
		/usr/lib64/gnuefi
	do
		if [ -f "$d/crt0-efi-loongarch64.o" ] && [ -f "$d/elf_loongarch64_efi.lds" ] && [ -f "$d/libgnuefi.a" ] && [ -f "$d/libefi.a" ]; then
			GNUEFI_LIB_DIR="$d"
			echo "[ZirconOS] GNU-EFI: ${GNUEFI_LIB_DIR}"
			break
		fi
	done
fi
if [ -z "${GNUEFI_LIB_DIR}" ] || [ ! -f "${GNUEFI_LIB_DIR}/crt0-efi-loongarch64.o" ]; then
	echo "[ZirconOS] ERROR: 缺少 LoongArch GNU-EFI（crt0 / lds / libgnuefi / libefi）。" >&2
	echo "  在本仓库执行:  make fetch-gnu-efi" >&2
	echo "  （仅需 git + zig，会从源码构建到 gnu-efi/loongarch64-built/）" >&2
	exit 1
fi

CRT0="${GNUEFI_LIB_DIR}/crt0-efi-loongarch64.o"
LDS="${GNUEFI_LIB_DIR}/elf_loongarch64_efi.lds"

TMP_SO="${OUT%.efi}.so"
rm -f "$TMP_SO" "$OUT"

# zig cc 在 loongarch 上会拒绝 -Wl,-shared（unsupported linker arg: -shared）。
# 有 loongarch64-linux-gnu-gcc 时用 gcc 驱动传 -shared；否则用系统 GNU ld 直接链接（需 binutils-loongarch64-linux-gnu）。
if [[ "$(basename "${CC[0]}")" == loongarch64-linux-gnu-gcc ]]; then
	LIBGCC="$("${CC[@]}" -print-libgcc-file-name)"
	echo "[ZirconOS] GNU-EFI link (gcc): ${CC[*]} + ${OBJ} → ${OUT}"
	"${CC[@]}" -o "$TMP_SO" -nostdlib -Wl,-shared -Wl,-Bsymbolic \
		-Wl,-T"$LDS" \
		-Wl,"$CRT0" \
		"$OBJ" \
		-L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
		"$LIBGCC"
elif command -v loongarch64-linux-gnu-ld >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
	LIBGCC="$(zig cc -target loongarch64-linux-gnu -print-libgcc-file-name)"
	echo "[ZirconOS] GNU-EFI link (gnu-ld + zig libgcc): ${OBJ} → ${OUT}"
	loongarch64-linux-gnu-ld -shared -Bsymbolic \
		-T"$LDS" \
		"$CRT0" \
		"$OBJ" \
		-L"$GNUEFI_LIB_DIR" -lgnuefi -lefi \
		"$LIBGCC" \
		-o "$TMP_SO"
else
	echo "[ZirconOS] ERROR: 无法链接 EFI .so：需要 loongarch64-linux-gnu-gcc，或 loongarch64-linux-gnu-ld + zig。" >&2
	echo "  例如: sudo apt install gcc-loongarch64-linux-gnu" >&2
	echo "    或: sudo apt install binutils-loongarch64-linux-gnu   (提供 gnu-ld)" >&2
	exit 1
fi

"${OC[@]}" --target=efi-app-loongarch64 -O binary "$TMP_SO" "$OUT"

rm -f "$TMP_SO"
ls -la "$OUT"
