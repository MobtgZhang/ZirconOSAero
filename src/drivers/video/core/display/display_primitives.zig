// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared geometry / clamp helpers for the desktop compositor (`display.zig`).

const std = @import("std");
const theme_mod = @import("../../../../desktop/kernel/theme/root.zig");

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub fn clampI32FromI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// 矩形宽/高：非负，且可安全落回 i32（用于 rectUnion 等 i64 差分）。
pub fn clampRectDimI64(d: i64) i32 {
    if (d <= 0) return 0;
    if (d > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(d);
}

/// 轴对齐矩形命中：`x ∈ [rx, rx+rw)`、`y ∈ [ry, ry+rh)`，加法在 i64 上避免 i32 溢出。
pub fn pointInRectI32(px: i32, py: i32, rx: i32, ry: i32, rw: i32, rh: i32) bool {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const x0 = @as(i64, rx);
    const y0 = @as(i64, ry);
    const w0 = @as(i64, rw);
    const h0 = @as(i64, rh);
    return pxi >= x0 and pyi >= y0 and pxi < x0 + w0 and pyi < y0 + h0;
}
