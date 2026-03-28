#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Compile-check LoongArch64 kernel + ZBM for multiple RESOLUTION-style WxH (build.conf 注释表).
# 不修改仓库内 desktop.conf：通过 zig -Dzbm_preferred_fb_* 注入，与 build.zig 一致。
#
# Usage:
#   ./scripts/test_loongarch_resolution_matrix.sh           # 全表（与 build.conf 41–53 行列举一致）
#   ./scripts/test_loongarch_resolution_matrix.sh --quick   # CI 快检：3 档代表分辨率
#
# QEMU 运行时抽样（本脚本仅做编译矩阵）：对 1024x768 / 1920x1080 / 4K 等档分别
# make run-loongarch64（或等价命令），串口应无 Debug integer overflow；验收关键字见
# docs/cn/AeroDesktopRuntime.md「正式验收标准」。
#
# 建议本地记录表（每档分辨率 × 两种 GPU 线）：
#   LOONGARCH64_QEMU_VIRTIO_GPU=0  → 仅 ramfb；串口关键字 + 主窗是否见像素
#   LOONGARCH64_QEMU_VIRTIO_GPU=1  → ramfb+virtio-gpu（Makefile 默认）；同上
# 主窗仍像 UEFI 文案但串口已有 first frame → 按 Makefile「实验矩阵」与 AeroDesktopRuntime §4.2.1.2 调整 -display / GDK_BACKEND。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FULL_LIST=(
	640x480x32
	1024x768x32
	1280x800x32
	1280x1024x32
	1366x768x32
	1440x900x32
	1600x900x32
	1680x1050x32
	1920x1080x32
	1920x1200x32
	2560x1440x32
	2560x1600x32
	3840x2160x32
)

if [[ "${1:-}" == "--quick" ]]; then
	REZS=(1024x768x32 1920x1080x32 3840x2160x32)
else
	REZS=("${FULL_LIST[@]}")
fi

for triple in "${REZS[@]}"; do
	w="${triple%%x*}"
	rest="${triple#*x}"
	h="${rest%%x*}"
	depth="${rest#*x}"
	if [[ "$depth" != "32" ]]; then
		echo "skip non-32bpp: $triple" >&2
		continue
	fi
	echo "=== LoongArch resolution matrix: ${w}x${h} (kernel + zbm-loongarch-uefi) ==="
	zig build -Darch=loongarch64 \
		-Dzbm_preferred_fb_width="$w" \
		-Dzbm_preferred_fb_height="$h"
	zig build zbm-loongarch-uefi -Darch=loongarch64 \
		-Dzbm_preferred_fb_width="$w" \
		-Dzbm_preferred_fb_height="$h"
done

echo "OK: LoongArch resolution matrix passed (${#REZS[@]} configs)."
