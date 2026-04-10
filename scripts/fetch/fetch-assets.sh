#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate missing Aero wallpaper PNGs (1×1 placeholders) so `zig build` can run without
# checked-in binary art. Replace with real assets under your own license as needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/gen_wallpaper_placeholders.py"
