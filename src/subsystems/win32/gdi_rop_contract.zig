// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/gdi_rop_contract.zig
// Purpose: Documented subset of GDI raster ops implemented by gdi32 (host-testable).
//
// Clean-room. Ref: https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-bitblt (rop)

/// `SRCCOPY` — 本仓库 `BitBlt` / `StretchBlt` **唯一**实现完整语义的 ROP（其余返回 FALSE + `ERROR_INVALID_PARAMETER`）。
pub const SRCCOPY: u32 = 0x00CC0020;
/// `PATCOPY` / `BLACKNESS` / `WHITENESS` / `PATINVERT` — `PatBlt` 子集。
pub const PATCOPY: u32 = 0x00F00021;
pub const BLACKNESS: u32 = 0x00000042;
pub const WHITENESS: u32 = 0x00FF0062;
pub const PATINVERT: u32 = 0x005A0049;

pub fn isImplementedBitBltRop(rop: u32) bool {
    return rop == SRCCOPY;
}

pub fn isImplementedStretchBltRop(rop: u32) bool {
    return rop == SRCCOPY;
}

pub fn isImplementedPatBltRop(rop: u32) bool {
    return rop == PATCOPY or rop == BLACKNESS or rop == WHITENESS or rop == PATINVERT;
}

const std = @import("std");

test "BitBlt only SRCCOPY" {
    try std.testing.expect(isImplementedBitBltRop(SRCCOPY));
    try std.testing.expect(!isImplementedBitBltRop(0x00EE0086)); // SRCPAINT
}

test "PatBlt subset" {
    try std.testing.expect(isImplementedPatBltRop(PATCOPY));
    try std.testing.expect(isImplementedPatBltRop(BLACKNESS));
    try std.testing.expect(!isImplementedPatBltRop(0x00FB0A09)); // PATPAINT unsupported
}
