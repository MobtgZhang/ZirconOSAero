#!/usr/bin/env bash
# LoongArch UEFI：在固件退回内置 Shell 后自动输入路径启动 ZBM。
# 优先使用 Python3 + pty（标准库，无需 expect）；若未装 python3 可装 expect 作为后备。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ESP="${ZIRCON_ESP:-$ROOT/build/esp-loongarch64.img}"
CODE="${LOONGARCH64_EFI_CODE:-$HOME/Firmware/LoongArchVirtMachine/QEMU_EFI.fd}"
if [ ! -f "$CODE" ]; then
	CODE="$ROOT/firmware/QEMU_EFI-loongarch64.fd"
fi
if [ ! -f "$ESP" ] || [ ! -f "$CODE" ]; then
	echo "[ZirconOS] ERROR: 缺少 ESP 或固件。先执行: make build-esp ARCH=loongarch64" >&2
	exit 1
fi
export ZIRCON_ESP="$ESP"
export LOONGARCH64_EFI_CODE="$CODE"
export QEMU_MEM_LOONGARCH64="${QEMU_MEM_LOONGARCH64:-1536M}"

if command -v python3 >/dev/null 2>&1; then
	exec python3 -u "$ROOT/scripts/qemu/loongarch-uefi-autorun.py"
fi

if ! command -v expect >/dev/null 2>&1; then
	echo "[ZirconOS] ERROR: 需要 python3 或 expect。" >&2
	exit 1
fi

exec expect <<'EOS'
set timeout 120
spawn qemu-system-loongarch64 -M virt -cpu la464 -m $env(QEMU_MEM_LOONGARCH64) -serial stdio -display none -no-reboot -bios $env(LOONGARCH64_EFI_CODE) -drive if=none,id=zircon-esp0,file=$env(ZIRCON_ESP),format=raw -device virtio-blk-pci,drive=zircon-esp0,bootindex=0 -boot order=d
expect {
	-re {Shell>} { send "fs0:\r" }
	timeout { exit 1 }
}
expect {
	-re {FS0:.*>} { send "EFI/BOOT/BOOTLOONGARCH64.EFI\r" }
	timeout { exit 1 }
}
interact
EOS
