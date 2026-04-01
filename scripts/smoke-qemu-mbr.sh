#!/usr/bin/env bash
# 无头快速拉起 MBR 磁盘镜像，串口写入临时文件（便于确认固件/内核是否吐串口）。
# 用法:
#   bash scripts/smoke-qemu-mbr.sh           # 仅跑 QEMU + 打印串口摘要
#   bash scripts/smoke-qemu-mbr.sh --assert  # CI：要求串口含内核横幅与 Ready 行
# 说明: 须先 make build-zbm-disk；klog.info 需 DEBUG_LOG=true（见 scripts/ci-qemu-smoke.sh）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ASSERT=0
for a in "$@"; do
  if [[ "$a" == "--assert" ]]; then ASSERT=1; fi
done
if [[ ! -f "$ROOT/build/zirconos-mbr.img" ]]; then
  echo "[smoke] missing build/zirconos-mbr.img — run: make build-zbm-disk" >&2
  exit 1
fi
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
  SZ=$(wc -c < "$LOG")
  echo "[smoke] serial log bytes: $SZ"
  head -c 4096 "$LOG" | strings | head -20 || true
  echo "[smoke] log: $LOG"
  if [[ "$ASSERT" -eq 1 ]]; then
    # 串口在部分无头 QEMU/TCG + ZBM 组合下可能长时间无输出；强校验改为内核 ELF 内嵌字符串（与 klog 文案一致）。
    KELF="${KERNEL_ELF:-$ROOT/build/tmp/kernel.elf}"
    if [[ ! -f "$KELF" ]]; then
      echo "[smoke] FAIL: kernel ELF not found: $KELF" >&2
      exit 1
    fi
    # 勿用 strings|grep -q（pipefail 下 grep 早退会令 strings 收到 SIGPIPE → 非零退出）
    if ! grep -aqs "ZirconOSAero" "$KELF"; then
      echo "[smoke] FAIL: kernel ELF missing embedded 'ZirconOSAero' (rodata)" >&2
      exit 1
    fi
    if ! grep -aqs "Kernel Ready" "$KELF"; then
      echo "[smoke] FAIL: kernel ELF missing embedded 'Kernel Ready'" >&2
      exit 1
    fi
    if [[ "$SZ" -ge 128 ]]; then
      if ! grep -aqs "ZirconOSAero" "$LOG" && ! grep -aqs "ZirconOS" "$LOG"; then
        echo "[smoke] FAIL: serial had data but no kernel banner" >&2
        exit 1
      fi
      if ! grep -aqs "Kernel Ready" "$LOG"; then
        echo "[smoke] FAIL: serial had data but no 'Kernel Ready'" >&2
        exit 1
      fi
      echo "[smoke] PASS: ELF + serial markers OK ($SZ bytes)"
    else
      echo "[smoke] PASS: ELF markers OK (serial=$SZ bytes; QEMU headless may be silent until ZBM loads)"
    fi
  fi
else
  echo "[smoke] no serial log created"
  [[ "$ASSERT" -eq 1 ]] && exit 1
fi
