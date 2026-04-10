#!/usr/bin/env bash
# 从 QEMU -serial stdio 复制 stdin：原样打印，并将 AGENT_LOG: 前缀行去掉前缀后追加到 NDJSON 日志。
# 用法: make run ARCH=x86_64 2>&1 | bash scripts/agent-ingest-serial.sh
# 或:   make run-loongarch64 2>&1 | bash scripts/agent-ingest-serial.sh
set -euo pipefail
LOG="${ZIRCON_AGENT_LOG_FILE:-$(dirname "$0")/../.cursor/debug-35ce7e.log}"
if [ -t 0 ]; then
	printf '%s\n' "[agent-ingest-serial] stdin 是终端，不会收到 QEMU 串口数据，无法生成 NDJSON 日志。" >&2
	printf '%s\n' "请把内核/QEMU 的标准输出接到本脚本，例如：" >&2
	printf '%s\n' "  make run 2>&1 | bash $(dirname "$0")/agent-ingest-serial.sh" >&2
	printf '%s\n' "（需内核以 -Dagent_ndjson=true 构建，串口才会出现 AGENT_LOG: 行）" >&2
	exit 1
fi
mkdir -p "$(dirname "$LOG")"
while IFS= read -r line || [[ -n "${line:-}" ]]; do
	printf '%s\n' "$line"
	case "$line" in
	AGENT_LOG:*) printf '%s\n' "${line#AGENT_LOG:}" >>"$LOG" ;;
	esac
done
