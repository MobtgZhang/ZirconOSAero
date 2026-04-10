#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# 阶段 C：模糊预算 / Aero 路径在 **1920×1080** 与 **800×600** 下的可重复 QEMU 烟测矩阵（人工/CI 辅助）。
# - 与 `scripts/qemu_desktop_perf_baseline.sh`、`build.conf` / `sync_resolution_config.py` 的 RESOLUTION 对齐。
# - 建议构建：`make build-zbm-disk ARCH=x86_64 DESKTOP=aero OPTIMIZE=ReleaseFast` 后分别改分辨率再跑 `scripts/ci-qemu-smoke.sh`。
# - 观测：`-Ddwm_blur_stats=true` 下 `dwm blur frame:` 行；超预算时 `tint_only_calls` 应可见；`-Dmouse_debug=true` 对照 [AeroDesktopRuntime.md](../docs/cn/AeroDesktopRuntime.md) `render_cap` vs `render_full`、拖窗 `render_drag`。
#
# 用法:
#   bash scripts/dwm_blur_resolution_matrix.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[dwm-blur-matrix] 阶段 C：请在以下分辨率各跑一轮 QEMU + 串口日志归档"
echo "[dwm-blur-matrix] 1) 1920x1080 — 高像素下 blur 预算降级（tint-only）与帧时"
echo "[dwm-blur-matrix] 2) 800x600  — 低分辨率对照，确认默认阈值不误伤"
echo "[dwm-blur-matrix] 配置：编辑 build.conf / 运行 python3 scripts/sync_resolution_config.py 后重建"
echo "[dwm-blur-matrix] 参考：`docs/cn/MVT_NT61.md` 阶段 C 行、`src/config/nt61_aero_defaults.zig`、`src/config/dwm_blur_budget.zig`"
echo "[dwm-blur-matrix] Root: $ROOT"
