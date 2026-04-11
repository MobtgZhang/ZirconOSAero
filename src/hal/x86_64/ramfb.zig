// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: hal/x86_64/ramfb.zig
// Purpose: QEMU x86_64 ramfb via fw_cfg. 当 UEFI GOP 初始化完成后,
//          使用本模块将 ramfb 扫描输出指向 GOP 物理地址,避免 QEMU GTK
//          显示仍绑定到默认 ramfb 区域(GOP 区域无像素更新)导致的黑屏。
//
// 本实现遵循 clean-room 原则,不参照任何 Windows 或闭源实现。
// QEMU 参考: hw/display/ramfb.c, include/hw/nvram/fw_cfg.h
//
// x86_64 fw_cfg 地址由 PCI 0xCF8/0xCFC 或 MCFG/ECAM 映射,
// 常见 QEMU 默认: 0xE0000000 区域(可通过 qemu -machine dumpdtb 确认).
// 当前实现为存根,若 QEMU 环境无 fw_cfg ramfb 路径则返回 false,
// 不影响 GOP 主路径的正常运作。

pub const RamfbInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
};

/// x86_64 QEMU fw_cfg MMIO 基址(PCI 方式映射).
/// 注意: 与 LoongArch64(0x1e020000)、AArch64(0x09020000)、RISC-V(0x10100000)不同.
/// 当通过 fw_cfg 访问 ramfb 时使用此基址;若 QEMU 不支持 x86_64 fw_cfg ramfb
/// 则本实现退化为存根,仅记录日志而不执行实际配置.
pub const FW_CFG_BASE: usize = 0xE0000000;
pub const FW_CFG_SELECTOR: usize = FW_CFG_BASE + 8;
pub const FW_CFG_DMA: usize = FW_CFG_BASE + 16;

/// fw_cfg 文件目录 selector(与所有架构一致)
pub const FW_CFG_FILE_DIR: u16 = 0x0019;
pub const FW_CFG_DMA_CTL_SELECT: u32 = 1 << 3;
pub const FW_CFG_DMA_CTL_WRITE: u32 = 1 << 4;
pub const RAMFB_FOURCC_AR24: u32 = 0x34325241;

/// x86_64 ramfb 固定物理地址.
/// 与 LoongArch64(0x0F000000)、AArch64(0x48000000)、RISC-V(0x18000000)分离.
/// 须与内核帧分配器约定同一地址,避免页帧落入扫描输出缓冲区.
pub const RAMFB_PHYS: usize = 0x0D000000;

const RAMFBCfg = extern struct {
    addr: u64,
    fourcc: u32,
    flags: u32,
    width: u32,
    height: u32,
    stride: u32,
};

const FWCfgDmaAccess = extern struct {
    control: u32,
    length: u32,
    address: u64,
};

/// 引导期已预留的扫描输出字节数上限.
var guest_reserved_scanout_bytes: usize = 0;

pub fn noteGuestReservedScanout(bytes: usize) void {
    guest_reserved_scanout_bytes = @max(guest_reserved_scanout_bytes, bytes);
}

pub fn guestReservedScanoutBytes() usize {
    return guest_reserved_scanout_bytes;
}

/// 计算指定宽高的扫描输出字节数(32bpp 线性).
pub fn framebufferReservedBytesDims(width: u32, height: u32) usize {
    if (width == 0 or height == 0) return 0;
    return @as(usize, width) * 4 * @as(usize, height);
}

/// 最大标准扫描输出预留字节数(与 build_options.kernel_preferred_fb_* 一致).
pub fn maxStandardScanoutReservedBytes() usize {
    return framebufferReservedBytesDims(
        @import("build_options").kernel_preferred_fb_width,
        @import("build_options").kernel_preferred_fb_height,
    );
}

fn readU16Be(addr: usize) u16 {
    const p: *const [2]u8 = @ptrFromInt(addr);
    return @as(u16, p[0]) << 8 | @as(u16, p[1]);
}

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

var ramfb_dma_buf: [16]u8 align(8) = undefined;
var ramfb_cfg_buf: [32]u8 align(8) = undefined;

/// 通过 DMA 写入 RAMFBCfg(大端序字段).
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

/// 查找 fw_cfg 中 "etc/ramfb" 的 selector.
/// x86_64: 与 LoongArch/AArch64/RISC-V 相同的 DMA 查找协议.
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
    if (num_files > 128) {
        if (klog.DEBUG_MODE) klog.info("ramfb(x86_64): num_files=%u > 128", .{num_files});
        return null;
    }
    var i: u32 = 0;
    while (i < num_files) : (i += 1) {
        const entry = buf[4 + i * 64 ..][0..64];
        const select = @as(u16, entry[4]) << 8 | entry[5];
        const name = entry[8..64];
        if (std.mem.indexOf(u8, name, "ramfb") != null) return select;
    }
    if (klog.DEBUG_MODE) klog.info("ramfb(x86_64): no etc/ramfb found in fw_cfg", .{});
    return null;
}

/// 将 QEMU ramfb 扫描输出指向已有的客物理帧缓冲(GOP 地址等).
/// 与 LoongArch64/AArch64/RISC-V 的 pointRamfbToGuestPhys 语义一致.
/// 返回 true 当且仅当 fw_cfg ramfb 路径可用且配置成功;失败时退化为静默 NOOP.
pub fn pointRamfbToGuestPhys(phys: u64, width: u32, height: u32, stride: u32) bool {
    const key = findRamfbKey() orelse return false;
    const cfg_ptr = &ramfb_cfg_buf;
    writeRamfbCfgToBuf(cfg_ptr, phys, width, height, stride);
    return writeRamfbConfig(key, cfg_ptr);
}

/// 运行期 IOCTL 改分辨率: 将 ramfb 指向已有的客物理地址.
pub fn runtimeReconfigureAtGuestPhys(phys: u64, width: u32, height: u32) ?RamfbInfo {
    const need = framebufferReservedBytesDims(width, height);
    if (need == 0) return null;
    if (guest_reserved_scanout_bytes == 0 or need > guest_reserved_scanout_bytes) return null;
    if (width == 0 or height == 0) return null;
    const stride = width * 4;
    const key = findRamfbKey() orelse return null;
    const cfg_ptr = &ramfb_cfg_buf;
    writeRamfbCfgToBuf(cfg_ptr, phys, width, height, stride);
    if (!writeRamfbConfig(key, cfg_ptr)) return null;
    return RamfbInfo{
        .addr = phys,
        .pitch = stride,
        .width = width,
        .height = height,
        .bpp = 32,
        .fb_type = 1,
    };
}
