#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# 串口同时进终端 + serial_dbg_to_cursor_log.py（避免 `| python` 时终端无输出）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec make run-loongarch64 ARCH=loongarch64 2>&1 | tee >(python3 -u "$ROOT/scripts/serial_dbg_to_cursor_log.py")
