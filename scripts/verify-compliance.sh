#!/usr/bin/env bash
# Optional maintainer check: flag suspicious substrings in *source* (not docs discussing policy).
# Does not prove absence of infringement; see THIRD_PARTY.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BAD=0
while IFS= read -r -d '' f; do
  if grep -qE 'Microsoft Corporation|PROPRIETARY AND CONFIDENTIAL' "$f" 2>/dev/null; then
    echo "verify-compliance: suspicious phrase in $f" >&2
    BAD=1
  fi
done < <(find src boot -type f \( -name '*.zig' -o -name '*.c' -o -name '*.h' -o -name '*.S' -o -name '*.s' \) -print0 2>/dev/null)
if [[ "$BAD" -ne 0 ]]; then
  echo "verify-compliance: FAILED (review manually)" >&2
  exit 1
fi
echo "verify-compliance: no flagged phrases under src/ boot/ (source-only scan OK)"
