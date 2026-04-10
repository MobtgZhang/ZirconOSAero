#!/usr/bin/env bash
# B5：对照 Linux amdgpu_drv.c 中 Polaris12 等片段，辅助维护 `src/drivers/video/vendor/amd/dids.zig`。
set -euo pipefail
URL="https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c"
echo "Fetching pciid hints from upstream (Polaris12 / Polaris10 / Polaris11)..."
curl -fsSL "$URL" | grep -E "CHIP_POLARIS(10|11|12)|0x699F|0x6987" | head -n 40
