#!/usr/bin/env bash
# Check relative links in docs/*.md and root README*.md resolve to existing files.
# Usage: bash scripts/check-docs-links.sh  (from repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAILED=0

check_target() {
  local from_dir="$1"
  local target="$2"
  if [[ "$target" == http://* || "$target" == https://* || "$target" == mailto:* ]]; then
    return 0
  fi
  if [[ "$target" == /* ]]; then
    echo "FAIL: absolute path not allowed in docs: $target (from $from_dir)"
    FAILED=1
    return
  fi
  local path_only="${target%%#*}"
  [[ -z "$path_only" ]] && return 0
  local resolved
  if ! resolved="$(cd "$from_dir" && realpath -m --relative-to="$ROOT" "$path_only" 2>/dev/null)"; then
    echo "FAIL: could not resolve '$target' from $from_dir"
    FAILED=1
    return
  fi
  local full="$ROOT/$resolved"
  if [[ ! -e "$full" ]]; then
    echo "FAIL: missing '$target' (from $from_dir → $full)"
    FAILED=1
  fi
}

scan_md() {
  local md="$1"
  local from_dir
  from_dir="$(dirname "$md")"
  local raw
  while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    local target="${raw#](}"
    target="${target%)}"
    check_target "$from_dir" "$target"
  done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null || true)
}

export ROOT FAILED
while IFS= read -r -d '' md; do
  scan_md "$md"
done < <(find docs -name '*.md' -print0)

for md in README.md README_cn.md; do
  [[ -f "$md" ]] || continue
  scan_md "$md"
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "check-docs-links: failed"
  exit 1
fi
echo "check-docs-links: OK"
