#!/usr/bin/env bash
set -euo pipefail

OUT="${1:?输出根目录}"
KERNEL="${2:?winload.efi 路径}"

_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rm -rf "$OUT"
bash "${_ROOT}/scripts/build/populate-nt61-esp.sh" "$OUT" /dev/null "$KERNEL" "X64"

echo "[ZirconOS] Windows NT 6.1 文件系统目录结构生成完成: $OUT"
