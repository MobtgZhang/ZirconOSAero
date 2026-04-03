#!/usr/bin/env bash
# J12：多核 SMP 串口烟测（需已 `zig build`）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="${KERNEL:-$ROOT/zig-out/bin/kernel}"
if [[ ! -f "$KERNEL" ]]; then
  echo "missing kernel: $KERNEL (run: zig build)" >&2
  exit 1
fi
exec qemu-system-x86_64 \
  -cpu qemu64 \
  -smp 4 \
  -m 512M \
  -machine q35,accel=kvm:tcg \
  -serial stdio \
  -kernel "$KERNEL" \
  "$@"
