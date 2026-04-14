// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/gdi_rop_contract.zig
// Purpose: Documented subset of GDI raster ops implemented by gdi32 (host-testable).
//
// Clean-room. Ref: https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-bitblt (rop)

/// `SRCCOPY` — 本仓库 `BitBlt` / `StretchBlt` **唯一**实现完整语义的 ROP（其余返回 FALSE + `ERROR_INVALID_PARAMETER`）。
///
/// 与 `kernel32.ERROR_INVALID_PARAMETER` 数值一致；供主机测试锁定矩阵 §5。
pub const bitblt_unsupported_rop_last_error: u32 = 87;
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

/// Ref: Learn — `BLENDFUNCTION` / `AC_SRC_OVER`（`AlphaBlend` 子集）。
pub const AC_SRC_OVER: u8 = 0x00;

pub fn isImplementedAlphaBlendOp(blend_op: u8) bool {
    return blend_op == AC_SRC_OVER;
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

test "AlphaBlend AC_SRC_OVER only" {
    try std.testing.expect(isImplementedAlphaBlendOp(AC_SRC_OVER));
    try std.testing.expect(!isImplementedAlphaBlendOp(1));
}
