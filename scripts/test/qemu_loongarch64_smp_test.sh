#!/usr/bin/env bash
# ZirconOSAero 阶段3：LoongArch64 SMP 烟测
# 验证 LoongArch64 AP 启动、ASID 分配、调度器工作窃取。
# 用法: ./scripts/qemu_loongarch64_smp_test.sh [--smp N]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP="${ZIRCON_ESP:-$ROOT/build/esp-loongarch64.img}"
CODE="${LOONGARCH64_EFI_CODE:-$HOME/Firmware/LoongArchVirtMachine/QEMU_EFI.fd}"
SMP="${SMP:-2}"
if [ ! -f "$ESP" ] || [ ! -f "$CODE" ]; then
	echo "[ZirconOS] ERROR: 缺少 ESP 或固件。先执行: make build-esp ARCH=loongarch64" >&2
	exit 1
fi
echo "[ZirconOS] 启动 LoongArch64 SMP=$SMP 烟测..."
echo "[ZirconOS] ESP=$ESP"
echo "[ZirconOS] FIRMWARE=$CODE"
exec qemu-system-loongarch64 \
	-M virt \
	-cpu max \
	-smp "$SMP" \
	-m 1536M \
	-serial stdio \
	-display none \
	-no-reboot \
	-bios "$CODE" \
	-drive if=none,id=zircon-esp0,file="$ESP",format=raw \
	-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
	-boot order=d
