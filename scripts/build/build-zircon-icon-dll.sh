#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ZirconOS — Build zircon_shell32_res.dll (PE, icon resources + DllMain).
# Uses: MinGW windres for .rc → COFF; `zig cc -target x86_64-windows-gnu` (MinGW ABI) to link.
# Override: WINDRES, ZIG
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WIN32_RES="$REPO_ROOT/src/desktop/aero/resources/win32"
OUT_DIR="$REPO_ROOT/zig-out/assets"
WINDRES="${WINDRES:-x86_64-w64-mingw32-windres}"
ZIG="${ZIG:-zig}"

if [[ "${SKIP_AERO_ICO_BUILD:-}" != "1" ]]; then
  "$REPO_ROOT/scripts/build/build-aero-icons.sh"
else
  echo "build-zircon-icon-dll: skipping ICO regeneration (SKIP_AERO_ICO_BUILD=1)"
fi

if ! command -v "$WINDRES" >/dev/null 2>&1; then
  echo "build-zircon-icon-dll: windres not found: $WINDRES" >&2
  exit 1
fi
if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "build-zircon-icon-dll: zig not found: $ZIG" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OBJ="$OUT_DIR/zircon_shell32_res.o"
STUB_SRC="$WIN32_RES/zircon_shell32_res_stub.c"

(cd "$WIN32_RES" && "$WINDRES" -i zircon_shell32_res.rc -o "$OBJ")
"$ZIG" cc -target x86_64-windows-gnu -shared \
  "$OBJ" "$STUB_SRC" \
  -o "$OUT_DIR/zircon_shell32_res.dll" \
  -Wl,--subsystem,windows

echo "build-zircon-icon-dll: wrote $OUT_DIR/zircon_shell32_res.dll (zig cc x86_64-windows-gnu)"
