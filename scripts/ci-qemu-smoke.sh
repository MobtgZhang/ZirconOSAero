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
