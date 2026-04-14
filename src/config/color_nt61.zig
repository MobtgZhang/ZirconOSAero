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
// Module: src/config/color_nt61.zig
// Purpose: Canonical packed color helpers — bridge Win32 COLORREF / registry DWORDs and kernel framebuffer packing.
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/windows/win32/gdi/colorref (low byte = red intensity)

const std = @import("std");

/// ## Canonical 内部色策略（content2.4 / DesktopManagerSpec §4）
/// **方案 1（本仓库选定）**：**内核帧缓冲与合成管线**以 **`KernelBgr888Low24`** 为唯一 canonical 打包形式（低 24 位 BGR，与 `desktop/kernel/theme/theme.zig` 一致）。
/// **跨界输入**（注册表、`WM_DWMCOLORIZATIONCOLORCHANGED`、用户态 Aero）使用 **`ColorrefLow24`**（MS Learn COLORREF 低 24，R 最低字节），**仅允许**经本模块 `kernelDwmTintFromColorrefLow24` / `colorrefLow24FromKernelBgr24` 等命名函数进出内核路径。
/// **不引入全路径 ARGB u32 中间层**（避免与帧缓冲 B8G8R8X8 写入再混序）；若将来需要 ARGB，仅允许在 **单函数边界** 内临时展开，不得作为跨模块 API 的裸 `u32`。
/// 内核帧缓冲 / `theme.rgb`（desktop/kernel/theme）低 24 位：**BGR**（B 最低字节）。勿与裸 `u32` 混用跨界 API。
pub const KernelBgr888Low24 = u32;
/// 注册表 DWORD / `WM_DWMCOLORIZATIONCOLORCHANGED` / Aero `theme.rgb`：**COLORREF** 低 24（R 最低字节，MS Learn）。
pub const ColorrefLow24 = u32;

/// **Packed u32 颜色策略（本树）**
/// - **帧缓冲 / 内核 `theme.rgb`**：低 24 位为 **BGR**（B 在 bit0–7），与 MS **COLORREF**（R 在 bit0–7）**相反**；`putPixel32` 按线性 B8G8R8X8 或等价写入。
/// - **用户态 Aero `theme.rgb`**：**COLORREF** 低 24（R 最低字节，见 MS Learn）。
/// - 文档化 **0xAARRGGBB** 仅作「含 alpha 时」的惯例说明；当前 Shell 大量路径仍用低 24 位。跨界、注册表 DWORD、`WM_DWMCOLORIZATIONCOLORCHANGED` 载荷请只用本模块转换函数，勿混用字面量。
pub fn bgrPacked24FromRgbBytes(r: u8, g: u8, b: u8) KernelBgr888Low24 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16);
}

/// MS Learn COLORREF low24 helper (`r | (g<<8) | (b<<16)`).
pub fn colorrefPacked24FromRgbBytes(r: u8, g: u8, b: u8) ColorrefLow24 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

/// Convert Aero/userland **COLORREF-style** low 24 bits (`r | (g<<8) | (b<<16)`) to kernel `theme.rgb`-compatible dword (same numeric remap).
pub fn kernelDwmTintFromColorrefLow24(colorref: ColorrefLow24) KernelBgr888Low24 {
    const r: u8 = @truncate(colorref & 0xFF);
    const g: u8 = @truncate((colorref >> 8) & 0xFF);
    const b: u8 = @truncate((colorref >> 16) & 0xFF);
    return bgrPacked24FromRgbBytes(r, g, b);
}

/// Inverse: kernel BGR-low24 → COLORREF-style low24 (for `WM_DWMCOLORIZATIONCOLORCHANGED` wParam-style payloads).
pub fn colorrefLow24FromKernelBgr24(kernel_bgr: KernelBgr888Low24) ColorrefLow24 {
    const b: u8 = @truncate(kernel_bgr & 0xFF);
    const g: u8 = @truncate((kernel_bgr >> 8) & 0xFF);
    const r: u8 = @truncate((kernel_bgr >> 16) & 0xFF);
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

test "color round-trip kernel BGR24 <-> COLORREF low24" {
    const k = bgrPacked24FromRgbBytes(0x12, 0x38, 0x62);
    const c = colorrefLow24FromKernelBgr24(k);
    try std.testing.expectEqual(kernelDwmTintFromColorrefLow24(c), k);
}

comptime {
    // 文档化不变量：内核 BGR 低 24 与 COLORREF 低 24 互为分量置换。
    const k = bgrPacked24FromRgbBytes(0xAA, 0xBB, 0xCC);
    const c = colorrefLow24FromKernelBgr24(k);
    if (kernelDwmTintFromColorrefLow24(c) != k) @compileError("color_nt61: kernel<->COLORREF round-trip broken");
}

test "kernel BGR low24 is not bitwise equal to COLORREF low24 for same RGB tuple" {
    const k = bgrPacked24FromRgbBytes(0x10, 0x20, 0x30);
    const cref_style = @as(u32, 0x10) | (@as(u32, 0x20) << 8) | (@as(u32, 0x30) << 16);
    try std.testing.expect(k != cref_style);
    try std.testing.expectEqual(kernelDwmTintFromColorrefLow24(cref_style), k);
}

test "COLORREF byte order matches Aero theme.rgb (MS Learn R in low byte)" {
    // Same layout as `src/desktop/aero/src/theme.zig` `rgb()`.
    const cref: u32 = 0x00CC8844; // r=0x44 g=0x88 b=0xCC in COLORREF low 24
    const r: u8 = @truncate(cref & 0xFF);
    const g: u8 = @truncate((cref >> 8) & 0xFF);
    const b: u8 = @truncate((cref >> 16) & 0xFF);
    try std.testing.expectEqual(bgrPacked24FromRgbBytes(r, g, b), kernelDwmTintFromColorrefLow24(cref));
}
