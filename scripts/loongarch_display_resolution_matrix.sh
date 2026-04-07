#!/usr/bin/env bash
# LoongArch QEMU：显示分辨率 IOCTL 烟测矩阵（手工 / CI 可选）
# 依赖：已构建内核与 ESP；参见 docs/specs/DisplayModeChange_NT61.md §6
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "[loongarch-display-matrix] ROOT=$ROOT"
echo "1) 启动：make run-loongarch64（或 serial-debug）"
echo "2) 桌面就绪后 IOCTL_DISPLAY_SET_MODE：1024x768 -> 1280x720（须在 ramfb 预留内）"
echo "3) 可选：VirtIO-GPU 组合下重复 §4 顺序（tearDown → ramfb）"
echo "参考：scripts/dwm_blur_resolution_matrix.sh、docs/cn/NT61_PR_GATES.md"
