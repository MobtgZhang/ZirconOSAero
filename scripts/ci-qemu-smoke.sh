#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# CI / local: build ZBM MBR disk + headless QEMU, assert serial markers.
# Requires: make, qemu-system-x86_64, binutils (as/ld/objcopy), python3, zig.
# ReleaseSafe + DEBUG_LOG=false would suppress klog.info — smoke uses Debug + logs on.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DESKTOP="${CI_SMOKE_DESKTOP:-none}"
export OPTIMIZE="${CI_SMOKE_OPTIMIZE:-Debug}"
export DEBUG_LOG="${CI_SMOKE_DEBUG_LOG:-true}"

echo "[ci-qemu-smoke] DESKTOP=$DESKTOP OPTIMIZE=$OPTIMIZE DEBUG_LOG=$DEBUG_LOG"
make build-zbm-disk ARCH=x86_64 DESKTOP="$DESKTOP" OPTIMIZE="$OPTIMIZE" DEBUG_LOG="$DEBUG_LOG"
exec bash "$ROOT/scripts/smoke-qemu-mbr.sh" --assert
