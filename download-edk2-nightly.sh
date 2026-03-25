#!/usr/bin/env bash
# 下载 https://retrage.github.io/edk2-nightly/ 的 QEMU UEFI 固件；详见 --help。

set -euo pipefail

BASE_URL="https://retrage.github.io/edk2-nightly/bin"
UPSTREAM_PAGE="https://retrage.github.io/edk2-nightly/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# 命令行目录参数（优先于环境变量 FIRMWARE_DIR）
CLI_OUTPUT=""
ARCH_FILTER="all"
VARIANT="${EDK2_VARIANT:-RELEASE}"

usage() {
	cat <<'EOF'
从 retrage 非官方 EDK2 夜间构建站下载 QEMU 用 UEFI 固件。
上游: https://retrage.github.io/edk2-nightly/
二进制: https://retrage.github.io/edk2-nightly/bin/

用法:
  ./download-edk2-nightly.sh [选项] [输出目录]

选项:
  -h, --help           显示本说明
  -a, --arch ARCH      只下载: x86_64 | aarch64 | loongarch64 | riscv64 | all（默认 all）
  --debug              等价于 EDK2_VARIANT=DEBUG

环境变量:
  EDK2_VARIANT         DEBUG 或 RELEASE（默认 RELEASE）
  FIRMWARE_DIR         未指定输出目录时使用（否则默认 仓库/firmware/）

依赖: curl, bash
EOF
}

die() {
	echo "[edk2-nightly] 错误: $*" >&2
	exit 1
}

require_curl() {
	command -v curl >/dev/null 2>&1 || die "需要安装 curl"
}

dl() {
	local out="$1"
	local name="$2"
	local url="${BASE_URL}/${name}"
	echo "  下载 ${name} -> $(basename "$out")"
	curl -fSL --connect-timeout 30 --retry 3 --retry-delay 2 -o "$out" "$url"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-a | --arch)
			[[ $# -ge 2 ]] || die "--arch 需要参数"
			ARCH_FILTER="$2"
			shift 2
			;;
		--debug)
			VARIANT="DEBUG"
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			die "未知选项: $1（用 --help 查看用法）"
			;;
		*)
			[[ -z "$CLI_OUTPUT" ]] || die "多余参数: $1"
			CLI_OUTPUT="$1"
			shift
			;;
		esac
	done
}

want_arch() {
	local a="$1"
	[[ "$ARCH_FILTER" == "all" || "$ARCH_FILTER" == "$a" ]]
}

fetch_x86_64() {
	echo "[edk2-nightly] x86_64 OVMF (${VARIANT})..."
	dl "$FIRMWARE_DIR/OVMF_CODE-x86_64.fd" "${VARIANT}X64_OVMF_CODE.fd"
	dl "$FIRMWARE_DIR/OVMF_VARS-x86_64.fd" "${VARIANT}X64_OVMF_VARS.fd"
	echo "  完成."
}

fetch_aarch64() {
	echo "[edk2-nightly] AArch64 QEMU_EFI (${VARIANT})..."
	dl "$FIRMWARE_DIR/QEMU_EFI-aarch64.fd" "${VARIANT}AARCH64_QEMU_EFI.fd"
	dl "$FIRMWARE_DIR/QEMU_VARS-aarch64.fd" "${VARIANT}AARCH64_QEMU_VARS.fd"
	echo "  完成."
}

fetch_loongarch64() {
	echo "[edk2-nightly] LoongArch64 QEMU_EFI (${VARIANT})..."
	dl "$FIRMWARE_DIR/QEMU_EFI-loongarch64.fd" "${VARIANT}LOONGARCH64_QEMU_EFI.fd"
	dl "$FIRMWARE_DIR/QEMU_VARS-loongarch64.fd" "${VARIANT}LOONGARCH64_QEMU_VARS.fd"
	echo "  [loongarch64] UEFI Shell -> BOOTLOONGARCH64.EFI（固件无应用时的备用引导）"
	dl "$FIRMWARE_DIR/BOOTLOONGARCH64.EFI" "${VARIANT}LOONGARCH64_Shell.efi"
	echo "  完成."
}

fetch_riscv64() {
	echo "[edk2-nightly] RISC-V64 VIRT (${VARIANT})..."
	dl "$FIRMWARE_DIR/VIRT-riscv64.fd" "${VARIANT}RISCV64_VIRT.fd"
	echo "  完成."
}

main() {
	parse_args "$@"

	# 目录：参数 > 环境变量 FIRMWARE_DIR > 仓库 firmware/
	FIRMWARE_DIR="${CLI_OUTPUT:-${FIRMWARE_DIR:-${SCRIPT_DIR}/firmware}}"

	case "$ARCH_FILTER" in
	all | x86_64 | aarch64 | loongarch64 | riscv64) ;;
	*) die "无效的 --arch: $ARCH_FILTER" ;;
	esac

	case "$VARIANT" in
	DEBUG | RELEASE) ;;
	*) die "EDK2_VARIANT 必须是 DEBUG 或 RELEASE" ;;
	esac

	require_curl
	mkdir -p "$FIRMWARE_DIR"

	echo "[edk2-nightly] 源: ${UPSTREAM_PAGE}"
	echo "[edk2-nightly] 输出目录: ${FIRMWARE_DIR}"
	echo "[edk2-nightly] 变体: ${VARIANT}"
	echo ""

	want_arch x86_64 && fetch_x86_64
	want_arch aarch64 && fetch_aarch64
	want_arch loongarch64 && fetch_loongarch64
	want_arch riscv64 && fetch_riscv64

	echo ""
	echo "[edk2-nightly] 全部完成."
	echo "  可将 Makefile 变量设为: FIRMWARE_DIR=${FIRMWARE_DIR}"
}

main "$@"
