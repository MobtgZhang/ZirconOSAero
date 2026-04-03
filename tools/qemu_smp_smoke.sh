#!/usr/bin/env bash
# J12：QEMU 多核冒烟示例（需本地镜像/内核构建产物路径）。
# 用法：KERNEL=/path/to/zirconaero ./tools/qemu_smp_smoke.sh
set -euo pipefail
: "${KERNEL:=zig-out/bin/zirconaero}"
exec qemu-system-x86_64 -kernel "${KERNEL}" -m 512M -smp 4 -serial stdio -no-reboot
