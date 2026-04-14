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
// Module: hal/riscv64/ramfb.zig
// Purpose: QEMU `riscv64` `virt` ramfb via fw_cfg when UEFI GOP is BLT-only or missing.
//
// This is an independent clean-room implementation.
// QEMU: RISC-V virt maps fw_cfg MMIO at 0x10100000 (see QEMU hw/riscv/virt.c, fw_cfg device).

pub const RamfbInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
};

/// QEMU RISC-V virt：fw_cfg MMIO（与 AArch64 寄存器布局相同：data @ base, selector @+8, DMA @+16）
pub const FW_CFG_BASE: usize = 0x10100000;
pub const FW_CFG_SELECTOR: usize = FW_CFG_BASE + 8;
pub const FW_CFG_DMA: usize = FW_CFG_BASE + 16;

pub const FW_CFG_FILE_DIR: u16 = 0x0019;
pub const FW_CFG_DMA_CTL_SELECT: u32 = 1 << 3;
pub const FW_CFG_DMA_CTL_WRITE: u32 = 1 << 4;
pub const RAMFB_FOURCC_AR24: u32 = 0x34325241;

const FB_WIDTH: u32 = @import("build_options").kernel_preferred_fb_width;
const FB_HEIGHT: u32 = @import("build_options").kernel_preferred_fb_height;
const FB_STRIDE: u32 = FB_WIDTH * 4;

/// Guest DRAM 自 `0x8000_0000` 起；取固定高位避免与内核映像重叠。
pub const RAMFB_PHYS: usize = 0x8300_0000;

pub fn framebufferReservedBytes() usize {
    if (FB_WIDTH == 0 or FB_HEIGHT == 0) return 0;
    return @as(usize, FB_STRIDE) * @as(usize, FB_HEIGHT);
}

const RAMFBCfg = extern struct {
    addr: u64,
    fourcc: u32,
    flags: u32,
    width: u32,
    height: u32,
    stride: u32,
};

fn readU32Be(addr: usize) u32 {
    const p: *const [4]u8 = @ptrFromInt(addr);
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | @as(u32, p[3]);
}

fn writeU32Be(addr: usize, v: u32) void {
    const p: *[4]u8 = @ptrFromInt(addr);
    p[0] = @truncate(v >> 24);
    p[1] = @truncate(v >> 16);
    p[2] = @truncate(v >> 8);
    p[3] = @truncate(v);
}

fn writeU64Be(addr: usize, v: u64) void {
    writeU32Be(addr, @truncate(v >> 32));
    writeU32Be(addr + 4, @truncate(v));
}

fn findRamfbKey() ?u16 {
    const std = @import("std");
    const klog = @import("../../rtl/klog.zig");
    const selector_be: *volatile u16 = @ptrFromInt(FW_CFG_SELECTOR);
    const data: *volatile u64 = @ptrFromInt(FW_CFG_BASE);
    const be_key = @byteSwap(FW_CFG_FILE_DIR);
    selector_be.* = be_key;
    var buf: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < buf.len) : (off += 8) {
        const v = data.*;
        @memcpy(buf[off..][0..8], &@as([8]u8, @bitCast(v)));
    }
    const num_files = (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | buf[3];
    if (num_files > 64) {
        if (klog.DEBUG_MODE) klog.info("ramfb(rv): findRamfbKey num_files=%u > 64", .{num_files});
        return null;
    }
    var i: u32 = 0;
    while (i < num_files) : (i += 1) {
        const entry = buf[4 + i * 64 ..][0..64];
        const select = @as(u16, entry[4]) << 8 | entry[5];
        const name = entry[8..64];
        if (std.mem.indexOf(u8, name, "ramfb") != null) return select;
    }
    if (klog.DEBUG_MODE) klog.info("ramfb(rv): no etc/ramfb in fw_cfg (add -device ramfb)", .{});
    return null;
}

var ramfb_dma_buf: [16]u8 align(8) = undefined;
var ramfb_cfg_buf: [32]u8 align(8) = undefined;

fn writeRamfbConfig(key: u16, cfg_ptr: [*]const u8) bool {
    const dma_phys = @intFromPtr(&ramfb_dma_buf);
    const ctrl = (FW_CFG_DMA_CTL_SELECT | FW_CFG_DMA_CTL_WRITE) | (@as(u32, key) << 16);
    writeU32Be(dma_phys, ctrl);
    writeU32Be(dma_phys + 4, @sizeOf(RAMFBCfg));
    writeU64Be(dma_phys + 8, @intFromPtr(cfg_ptr));
    const dma_reg: *volatile u64 = @ptrFromInt(FW_CFG_DMA);
    dma_reg.* = dma_phys;
    var timeout: u32 = 1000000;
    while (timeout > 0) : (timeout -= 1) {
        if ((readU32Be(dma_phys) & 1) == 0) return true;
    }
    return false;
}

fn writeRamfbCfgToBuf(cfg_ptr: *align(8) [32]u8, phys: u64, width: u32, height: u32, stride: u32) void {
    writeU64Be(@intFromPtr(cfg_ptr), phys);
    writeU32Be(@intFromPtr(cfg_ptr) + 8, RAMFB_FOURCC_AR24);
    writeU32Be(@intFromPtr(cfg_ptr) + 12, 0);
    writeU32Be(@intFromPtr(cfg_ptr) + 16, width);
    writeU32Be(@intFromPtr(cfg_ptr) + 20, height);
    writeU32Be(@intFromPtr(cfg_ptr) + 24, stride);
}

pub fn setup() ?RamfbInfo {
    const klog = @import("../../rtl/klog.zig");
    if (FB_WIDTH == 0 or FB_HEIGHT == 0) return null;
    const key = findRamfbKey() orelse return null;
    const cfg_ptr = &ramfb_cfg_buf;
    writeRamfbCfgToBuf(cfg_ptr, RAMFB_PHYS, FB_WIDTH, FB_HEIGHT, FB_STRIDE);
    if (!writeRamfbConfig(key, cfg_ptr)) return null;
    klog.info("ramfb(rv): QEMU cfg %ux%u stride=%u @0x%x", .{
        FB_WIDTH, FB_HEIGHT, FB_STRIDE, RAMFB_PHYS,
    });
    return RamfbInfo{
        .addr = RAMFB_PHYS,
        .pitch = FB_STRIDE,
        .width = FB_WIDTH,
        .height = FB_HEIGHT,
        .bpp = 32,
        .fb_type = 1,
    };
}

pub fn pointRamfbToGuestPhys(phys: u64, width: u32, height: u32, stride: u32) bool {
    const key = findRamfbKey() orelse return false;
    const cfg_ptr = &ramfb_cfg_buf;
    writeRamfbCfgToBuf(cfg_ptr, phys, width, height, stride);
    return writeRamfbConfig(key, cfg_ptr);
}
