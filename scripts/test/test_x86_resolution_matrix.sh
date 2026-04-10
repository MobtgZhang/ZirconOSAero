#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# 编译矩阵：x86_64 内核在 build.conf 注释表所列各档 WxHx32 下能否通过 `zig build kernel`
# （与 scripts/test_loongarch_resolution_matrix.sh 的 FULL_LIST 一致；不修改仓库内 desktop.conf，
#  通过 zig -Dzbm_preferred_fb_* 注入，与 build.zig 一致）。
#
# Usage:
#   ./scripts/test_x86_resolution_matrix.sh           # 全表 13 档 + 1600x900x32
#   ./scripts/test_x86_resolution_matrix.sh --quick   # CI 快检：1024×768 / 1080p / 4K
#
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
	echo "=== x86_64 resolution matrix: ${w}x${h} (kernel) ==="
	zig build kernel -Darch=x86_64 \
		-Dzbm_preferred_fb_width="$w" \
		-Dzbm_preferred_fb_height="$h"
done

echo "OK: x86_64 resolution matrix passed (${#REZS[@]} configs)."
