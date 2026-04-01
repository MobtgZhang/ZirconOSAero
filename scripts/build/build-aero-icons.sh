#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ZirconOS — Rasterize Aero SVG icons to multi-size ICO (host toolchain).
# Requires: inkscape OR rsvg-convert; ImageMagick magick OR convert.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SVG_DIR="$REPO_ROOT/src/desktop/aero/resources/icons"
ICO_OUT="$REPO_ROOT/src/desktop/aero/resources/win32/ico"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ICONS=(
  computer documents recycle_bin terminal network browser settings calculator
  text_editor pictures music folder control_panel file user lock shutdown
  recycle_bin_full drive_fixed drive_removable drive_optical printer
  info warning error
)

svg_to_png() {
  local svg=$1
  local png=$2
  local w=$3
  if command -v inkscape >/dev/null 2>&1; then
    if inkscape "$svg" --export-type=png --export-filename="$png" -w "$w" -h "$w" 2>/dev/null; then
      return 0
    fi
    inkscape "$svg" -o "$png" -w "$w" -h "$w"
  elif command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$w" -h "$w" "$svg" -o "$png"
  else
    echo "build-aero-icons: need inkscape or rsvg-convert" >&2
    exit 1
  fi
}

mkdir -p "$ICO_OUT"

for name in "${ICONS[@]}"; do
  svg="$SVG_DIR/${name}.svg"
  if [[ ! -f "$svg" ]]; then
    echo "build-aero-icons: missing $svg" >&2
    exit 1
  fi
  for sz in 16 32 48 256; do
    svg_to_png "$svg" "$TMP/${name}-${sz}.png" "$sz"
  done
  if command -v magick >/dev/null 2>&1; then
    magick \
      "$TMP/${name}-16.png" "$TMP/${name}-32.png" \
      "$TMP/${name}-48.png" "$TMP/${name}-256.png" \
      "$ICO_OUT/${name}.ico"
  elif command -v convert >/dev/null 2>&1; then
    convert \
      "$TMP/${name}-16.png" "$TMP/${name}-32.png" \
      "$TMP/${name}-48.png" "$TMP/${name}-256.png" \
      "$ICO_OUT/${name}.ico"
  else
    echo "build-aero-icons: need ImageMagick (magick or convert)" >&2
    exit 1
  fi
  echo "build-aero-icons: wrote $ICO_OUT/${name}.ico"
done

echo "build-aero-icons: done ($ICO_OUT)"
