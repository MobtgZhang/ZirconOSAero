#!/usr/bin/env bash
# 桌面 / DWM 相关快速回归：内核构建 + Aero 库单元测试。
# 截图与实机对比见 docs/cn/DesktopQA.md。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
zig build kernel
(cd src/desktop/aero && zig build test)
echo "desktop-qa: OK (optional: zig build kernel -Dmouse_debug=true for pointer / VirtIO ring traces)"
