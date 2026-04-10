#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# NT 6.1 阶段 3：CPU 合成性能基线（**文档/人工**闸门；非 CI 硬性 60fps）。
# - 纯 GOP + 盒式模糊下 1080p 多窗可能无法稳定 60fps；本脚本只收集可重复步骤与指标名。
# - 内核侧计数：`display.getDesktopComposeTelemetry()`（full_scene_frames vs partial_frames）、
#   `display.getPresentTelemetry()`（desktop_frames / compositor_frames）。
# - 建议：`-Ddesktop_bisect=true`、`-Ddwm_blur_stats=true`、`-Dmouse_debug=true` 组合对照串口与
#   `mouse_debug` 中 `DesktopRenderPathKind` 占比。
#
# 用法:
#   bash scripts/qemu_desktop_perf_baseline.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[perf-baseline] ZirconOSAero desktop perf notes (see docs/cn/DesktopManagerSpec.md §8)"
echo "[perf-baseline] 1) Build: make build-zbm-disk ARCH=x86_64 DESKTOP=aero OPTIMIZE=ReleaseFast"
echo "[perf-baseline] 2) QEMU: bash scripts/ci-qemu-smoke.sh (或本地 smoke-qemu-mbr 延长 timeout)"
echo "[perf-baseline] 3) 目标：同机多次运行比较串口日志长度与 klog blur 统计行（若启用）"
echo "[perf-baseline] 4) 分项目标：提高 partial_frames / (partial+full) 比值；降低 full_scene 热路径占比"
echo "[perf-baseline] 5) 阶段 D 软烟测（可选）：串口日志中检索关键字 WM_DWM、get_message、present、flip_journal（grep -E 'WM_DWM|get_message|present|flip_journal'）"
echo "[perf-baseline] Root: $ROOT"
