#!/usr/bin/env bash
# 桌面 / DWM 相关快速回归：内核构建 + Aero 库单元测试。
# 截图与实机对比见 docs/cn/DesktopQA.md。
# 指针/VirtIO 问题：见 docs/cn/AeroDesktopRuntime.md §3；建议 MOUSE_DEBUG=true 或 AGENT_NDJSON=true。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
zig build kernel
(cd src/desktop/aero && zig build test)
echo "desktop-qa: OK"
echo "  Optional: make build MOUSE_DEBUG=true   # serial mouseDbg + ptr overlay"
echo "  Optional: make build AGENT_NDJSON=true && make run 2>&1 | bash scripts/agent-ingest-serial.sh"
echo "  Pointer stuck: docs/cn/AeroDesktopRuntime.md §3 + §3.1; try INTEL_IGPU=false or DESKTOP_IDLE_SPIN=true"
echo "  Matrix: vary GOP res (QEMU -vga), display.double_buffer in config; check 'double_buf=' / 'heap back buffer' in log"
