#!/usr/bin/env bash
# E3：对 NT61 合同矩阵的轻量「存在性」扫描（grep 级）；扩展为结构化报告时可替换为 Zig/Python。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAT="$ROOT/docs/cn/NT61_CONTRACT_MATRIX.md"
echo "contract_matrix_scan: matrix=$MAT"
test -f "$MAT"
echo "  sections (##):" && grep -c '^##' "$MAT" || true
echo "  NtOpenFile mentions:" && grep -c 'NtOpenFile' "$MAT" || true
echo "OK (stub report; see NT61_CONTRACT_MATRIX.md for authoritative list)"
