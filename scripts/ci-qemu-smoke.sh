#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# CI / local: build ZBM MBR disk + headless QEMU, assert serial markers.
# Requires: make, qemu-system-x86_64, binutils (as/ld/objcopy), python3, zig.
# ReleaseSafe + DEBUG_LOG=false would suppress klog.info — smoke uses Debug + logs on.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# DESKTOP=aero 时内核走完整壳层/DWM 路径；CI 默认 none 以缩短构建。收紧时可设 CI_SMOKE_DESKTOP=aero
# 并加大 `scripts/smoke-qemu-mbr.sh` timeout，串口应出现 Framebuffer / DWM 初始化类 klog（依 DEBUG_LOG）。
# 手工桌面烟测（非本脚本硬性）：Flip3D 串口文案 **Flip3D (Alt+Tab)**、**Esc close**；VirGL+QEMU 可出现 **CMD_SUBMIT_3D size=0 ok** 与 **Desktop display phase** → **virgl_submit3d_noop_ok**（见 MVT_NT61.md）。
# Phase3 若卡在「VM: allocating PML4」之后无进展：多为 PFN 误分配 GOP 显存；见 docs/cn/PHYS_ALLOC_AUDIT.md（GOP 保留）与串口 **GOP framebuffer excluded** 行。
# 对照 smp：UEFI 烟测可设 QEMU_SMP_UEFI=1（Makefile）排除早期 AP/串口交错；若 -m 超过编译期 phys_track_gb，请 zig build -Dphys_track_gb=16|32|64。
# Phase3 复发且 GOP 已排除：核对 PFN 保留是否基于链接器 _kernel_end（x86_64：kernel_end.s；nm stack_top / _kernel_end / g_kernel_frame_storage）。
# 手工 A/B：QEMU_SMP_UEFI=1；QEMU_X86_UEFI_ACCEL=tcg QEMU_X86_UEFI_CPU=-cpu max（Makefile UEFI 变量）。
export DESKTOP="${CI_SMOKE_DESKTOP:-none}"
export OPTIMIZE="${CI_SMOKE_OPTIMIZE:-Debug}"
export DEBUG_LOG="${CI_SMOKE_DEBUG_LOG:-true}"

echo "[ci-qemu-smoke] DESKTOP=$DESKTOP OPTIMIZE=$OPTIMIZE DEBUG_LOG=$DEBUG_LOG CI_SMOKE_MIN_SERIAL=${CI_SMOKE_MIN_SERIAL:-}"
make build-zbm-disk ARCH=x86_64 DESKTOP="$DESKTOP" OPTIMIZE="$OPTIMIZE" DEBUG_LOG="$DEBUG_LOG"
SMOKE_EXTRA=()
if [[ -n "${CI_SMOKE_MIN_SERIAL:-}" ]]; then
  SMOKE_EXTRA+=(--min-serial-bytes="${CI_SMOKE_MIN_SERIAL}")
fi
exec bash "$ROOT/scripts/smoke-qemu-mbr.sh" --assert "${SMOKE_EXTRA[@]}"
