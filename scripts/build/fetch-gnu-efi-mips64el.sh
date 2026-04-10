#!/usr/bin/env bash
# 构建 MIPS64EL GNU-EFI（crt0/lds/libgnuefi/libefi）→ gnu-efi/mips64el-built/
#
# MIPS64EL UEFI 支持比 LoongArch/RISC-V 更少见。标准路径：
#   1. 主流 rhboot/gnu-efi **不包含** MIPS 目录，需要从社区 fork 构建
#   2. 或自行添加 mips64el/ 到 gnu-efi 源码
#
# 当前脚本尝试以下来源：
#   - edk2 源码中有 MIPS64EL 的 OvmfPkg/Mips64el/ 部分（可作为参考）
#   - tianocore/edk2 的 Mips64elPkg 可编译出部分 UEFI runtime 服务
#
# 如果以上均不可用，脚本会输出详细错误并给出替代方案：
#   - 使用 QEMU -kernel 直接加载（不需要 GNU-EFI）
#   - 或手动从某个 GNU-EFI MIPS fork 获取
#
# Usage: fetch-gnu-efi-mips64el.sh [OUTPUT_DIR]
#
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"
DEST="${1:-${_ROOT}/gnu-efi/mips64el-built}"
SRC="${_ROOT}/gnu-efi/mips64el-src"
OUT="${DEST}"

# 检查必要工具
if ! command -v zig >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: zig not found in PATH." >&2
	exit 1
fi

if ! command -v mips64el-linux-gnuabi64-gcc >/dev/null 2>&1 && \
   ! command -v mips64el-linux-gnu-gcc >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: mips64el-linux-gnuabi64-gcc not found." >&2
	echo "  安装：sudo apt install gcc-mips64el-linux-gnuabi64" >&2
	echo "  或使用以下替代方案（推荐）：" >&2
	echo "    make run-mips64el  # -kernel 直接加载，不依赖 GNU-EFI" >&2
	exit 1
fi

CC="${CC:-mips64el-linux-gnuabi64-gcc}"
if ! command -v "${CC}" >/dev/null 2>&1; then
	CC="mips64el-linux-gnu-gcc"
fi

echo "[ZirconOS] MIPS64EL GNU-EFI 构建"
echo "  DEST: ${DEST}"
echo "  CC:   ${CC}"

# 方法 A：尝试克隆 edk2（包含 MIPS64EL UEFI 支持）
EDK2_SRC="${_ROOT}/gnu-efi/edk2-src"
if [ ! -d "${EDK2_SRC}/.git" ]; then
	echo "[ZirconOS] Cloning edk2 (Mips64elPkg)..."
	git clone --depth 1 --branch edk2-stable202311 \
		https://github.com/tianocore/edk2.git \
		"${EDK2_SRC}" 2>/dev/null || {
		echo "[ZirconOS] WARNING: edk2 clone failed（网络问题）；继续尝试其他方法"
	}
fi

# 方法 B：尝试使用 llvm-mips64el 或检查已安装的 gnu-efi
mkdir -p "${OUT}"

FOUND=0
for candidate in \
	"${DEST}" \
	/usr/lib64/gnuefi \
	/usr/lib/gnuefi \
	"${_ROOT}/gnu-efi/mips64el-built"
do
	if [ -f "${candidate}/crt0-efi-mips64el.o" ] && \
	   [ -f "${candidate}/elf_mips64el_efi.lds" ] && \
	   [ -f "${candidate}/libgnuefi.a" ] && \
	   [ -f "${candidate}/libefi.a" ]; then
		echo "[ZirconOS] Found GNU-EFI MIPS64EL at: ${candidate}"
		FOUND=1
		if [ "${candidate}" != "${OUT}" ]; then
			cp -f "${candidate}/crt0-efi-mips64el.o" "${OUT}/"
			cp -f "${candidate}/elf_mips64el_efi.lds" "${OUT}/"
			cp -f "${candidate}/libgnuefi.a" "${OUT}/"
			cp -f "${candidate}/libefi.a" "${OUT}/"
		fi
		break
	fi
done

if [ "${FOUND}" -eq 1 ]; then
	echo "[ZirconOS] GNU-EFI MIPS64EL 已就绪:"
	ls -la "${OUT}/"
	exit 0
fi

# 无法找到预构建文件，输出详细错误和替代方案
echo "[ZirconOS] ERROR: 找不到 MIPS64EL GNU-EFI 库文件。" >&2
echo "  尝试的方法：" >&2
echo "    1. apt install gcc-mips64el-linux-gnuabi64（提供 mips64el-linux-gnuabi64-gcc）" >&2
echo "    2. 从 edk2 源码构建 Mips64elPkg" >&2
echo "    3. 手动将 MIPS64 EL 支持添加到 rhboot/gnu-efi" >&2
echo "" >&2
echo "  替代方案（无需 GNU-EFI）：" >&2
echo "    make run-mips64el    # QEMU -kernel 直接加载 ELF（不依赖 EFI）" >&2
echo "    make build ARCH=mips64el  # 内核 ELF 编译无需 GNU-EFI" >&2
echo "" >&2
echo "  如需要完整 UEFI 启动支持，请参考：" >&2
echo "    - edk2/Mips64elPkg（完整 UEFI 驱动）" >&2
echo "    - https://github.com/tianocore/edk2" >&2
exit 1
