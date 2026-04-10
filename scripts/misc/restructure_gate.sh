#!/usr/bin/env bash
# Minimal merge gate after large refactors: host tests + one cross-target compile.
set -euo pipefail
cd "$(dirname "$0")/.."
zig build test
zig build -Darch=loongarch64
echo "restructure_gate: OK"
