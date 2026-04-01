#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Probe whether `zig cc` can link a trivial shared library for loongarch64-windows-gnu (Tier 2 PE DLL).
# Usage: probe-loongarch-windows-gnu-shared.sh /path/to/zig
# Exit 0 if supported; non-zero if unsupported (expected until Zig/LLVM COFF matures).
set -euo pipefail
ZIG="${1:?zig executable path}"
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
printf 'void zircon_la_windows_pe_probe(void){}\n' >"$d/p.c"
exec "$ZIG" cc -target loongarch64-windows-gnu -shared "$d/p.c" -o "$d/out.dll"
