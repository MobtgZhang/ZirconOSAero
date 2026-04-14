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

//! MIPS64EL kernel framebuffer console — linear VRAM write via uncached MMIO.
//! Architecture-independent pixel operations; only the VRAM base address mapping is MIPS-specific.
//! On MIPS64, the framebuffer physical address is accessed through kseg1 (uncached):
//!   virtual = 0xFFFFFFFF_A0000000 + physical  (for phys < 512MB)
//! or through xkphys uncached segment for larger addresses.

var fb_addr: u64 = 0;
var fb_pitch: u32 = 0;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_bpp: u8 = 32;
var fb_initialized: bool = false;
var console_enabled: bool = true;

pub fn setConsoleEnabled(e: bool) void {
    console_enabled = e;
}

pub fn isConsoleEnabled() bool {
    return console_enabled;
}

/// 与 LoongArch/RISC-V `hal/*/framebuffer` 命名一致，供 `desktop_session` 等使用。
pub fn isReady() bool {
    return fb_initialized;
}

/// 参数顺序与其他架构统一: (addr, width, height, pitch, bpp)
pub fn init(addr: u64, width: u32, height: u32, pitch: u32, bpp: u8) void {
    fb_addr = addr;
    fb_pitch = pitch;
    fb_width = width;
    fb_height = height;
    fb_bpp = bpp;
    fb_initialized = true;
}

pub fn isInitialized() bool {
    return fb_initialized;
}

pub fn getInfo() struct { addr: u64, pitch: u32, width: u32, height: u32, bpp: u8 } {
    return .{
        .addr = fb_addr,
        .pitch = fb_pitch,
        .width = fb_width,
        .height = fb_height,
        .bpp = fb_bpp,
    };
}

pub fn clear(color: u32) void {
    if (!fb_initialized or !console_enabled) return;
    const base: [*]volatile u32 = @ptrFromInt(fb_addr);
    const pixels = @as(usize, fb_pitch) / 4 * @as(usize, fb_height);
    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        base[i] = color;
    }
}

pub fn putPixel(x: u32, y: u32, color: u32) void {
    if (!fb_initialized) return;
    if (x >= fb_width or y >= fb_height) return;
    const offset = @as(usize, y) * @as(usize, fb_pitch) / 4 + @as(usize, x);
    const base: [*]volatile u32 = @ptrFromInt(fb_addr);
    base[offset] = color;
}
