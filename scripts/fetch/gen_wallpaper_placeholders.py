#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Emit tiny valid PNGs for Aero wallpaper paths listed in build.zig (keep list in sync)."""
from __future__ import annotations

import os
import struct
import zlib
from pathlib import Path

# Keep in sync with wallpaper_png_inputs in build.zig
PATHS = [
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_harmony.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_default.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_crystal.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_aurora.png",
    "src/desktop/aero/resources/wallpapers/Characters/zircon_characters.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_nature.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_scenes.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscapes.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_architecture.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_ocean.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_nebula.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscape.png",
]


def png_rgba_1x1(r: int, g: int, b: int, a: int) -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = bytes([0, r, g, b, a])
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    px = png_rgba_1x1(0x2E, 0x4A, 0x7F, 0xFF)
    for rel in PATHS:
        path = root / rel
        if path.is_file():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(px)
        print(f"placeholder: {rel}")


if __name__ == "__main__":
    main()
