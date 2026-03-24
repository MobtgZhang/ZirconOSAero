#!/usr/bin/env bash
# 无头快速拉起 MBR 磁盘镜像，串口写入临时文件（便于确认固件/内核是否吐串口）。
# 用法: bash scripts/smoke-qemu-mbr.sh
# 说明: ZBM/内核是否写 COM1 取决于当前构建配置；本脚本仅作 CI/本地烟测入口。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
make build-zbm-disk
LOG="${TMPDIR:-/tmp}/zirconos-qemu-smoke-$$.log"
rm -f "$LOG"
# 固定 pc + 8259，与 Makefile 中 QEMU_COMMON_X86 一致
timeout 18 qemu-system-x86_64 \
  -machine pc \
  -m 512M \
  -display none \
  -serial file:"$LOG" \
  -no-reboot \
  -no-shutdown \
  -drive format=raw,file="$ROOT/build/zirconos-mbr.img" \
  2>/dev/null || true
if [[ -f "$LOG" ]]; then
  echo "[smoke] serial log bytes: $(wc -c < "$LOG")"
  head -c 4096 "$LOG" | strings | head -20 || true
  echo "[smoke] log: $LOG"
else
  echo "[smoke] no serial log created"
fi
