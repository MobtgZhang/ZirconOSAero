#!/usr/bin/env bash
set -euo pipefail
# 兼容入口：实际逻辑在仓库根目录 download-edk2-nightly.sh
# 上游: https://retrage.github.io/edk2-nightly/

_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$_REPO/download-edk2-nightly.sh" "$@"
