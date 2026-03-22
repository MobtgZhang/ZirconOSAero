//! QEMU ramfb setup for LoongArch virt machine
//! fw_cfg @ 0x1e020000 (VIRT_FWCFG_BASE), guest writes RAMFBCfg to enable display

pub const RamfbInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
};

pub const FW_CFG_BASE: usize = 0x1e020000;
pub const FW_CFG_SELECTOR: usize = FW_CFG_BASE + 8;
pub const FW_CFG_DMA: usize = FW_CFG_BASE + 16;

pub const FW_CFG_FILE_DIR: u16 = 0x0019;
pub const FW_CFG_DMA_CTL_SELECT: u32 = 1 << 3;
pub const FW_CFG_DMA_CTL_WRITE: u32 = 1 << 4;
pub const RAMFB_FOURCC_AR24: u32 = 0x34325241;

const FB_WIDTH: u32 = 1024;
const FB_HEIGHT: u32 = 768;
const FB_BPP: u32 = 32;
const FB_STRIDE: u32 = 1024 * 4;
const FB_SIZE: usize = FB_STRIDE * FB_HEIGHT;

/// 固定物理地址：15MB 偏移，避免与内核重叠（内核 ~0x200000..0x400000）
pub const RAMFB_PHYS: usize = 0x0F000000;

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

fn readU16Be(addr: usize) u16 {
    const p: *const [2]u8 = @ptrFromInt(addr);
    return @as(u16, p[0]) << 8 | @as(u16, p[1]);
}

fn readU32Be(addr: usize) u32 {
    const p: *const [4]u8 = @ptrFromInt(addr);
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | @as(u32, p[3]);
}

fn writeU16Be(addr: usize, v: u16) void {
    const p: *[2]u8 = @ptrFromInt(addr);
    p[0] = @truncate(v >> 8);
    p[1] = @truncate(v);
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

/// 查找 fw_cfg 中 "etc/ramfb" 的 selector
fn findRamfbKey() ?u16 {
    const std = @import("std");
    const klog = @import("../../rtl/klog.zig");
    const selector_be: *volatile u16 = @ptrFromInt(FW_CFG_SELECTOR);
    const data: *volatile u64 = @ptrFromInt(FW_CFG_BASE);
    // LoongArch fw_cfg MMIO 使用大端 selector；0x0019 -> 写 0x1900
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
        if (klog.DEBUG_MODE) klog.info("ramfb: findRamfbKey num_files=%u > 64", .{num_files});
        return null;
    }
    var i: u32 = 0;
    while (i < num_files) : (i += 1) {
        const entry = buf[4 + i * 64 ..][0..64];
        const select = @as(u16, entry[4]) << 8 | entry[5];
        const name = entry[8..64];
        if (std.mem.indexOf(u8, name, "ramfb") != null) return select;
    }
    if (klog.DEBUG_MODE) klog.info("ramfb: findRamfbKey no etc/ramfb in %u files", .{num_files});
    return null;
}

/// DMA 控制结构与配置：全局静态，保证落在 identity-map 低 512MB 内且地址稳定
var ramfb_dma_buf: [16]u8 align(8) = undefined;
var ramfb_cfg_buf: [32]u8 align(8) = undefined;

/// 通过 DMA 写入 RAMFBCfg（control 需 Select|Write，字段大端序）
/// DMA 寄存器为 DEVICE_BIG_ENDIAN，LoongArch(LE) 写入时 QEMU 会交换字节，故需预先 byteSwap
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

/// 尝试初始化 ramfb，返回 RamfbInfo 或 null
pub fn setup() ?RamfbInfo {
    const key = findRamfbKey() orelse return null;
    const cfg_ptr = &ramfb_cfg_buf;
    writeU64Be(@intFromPtr(cfg_ptr), RAMFB_PHYS);
    writeU32Be(@intFromPtr(cfg_ptr) + 8, RAMFB_FOURCC_AR24);
    writeU32Be(@intFromPtr(cfg_ptr) + 12, 0);
    writeU32Be(@intFromPtr(cfg_ptr) + 16, FB_WIDTH);
    writeU32Be(@intFromPtr(cfg_ptr) + 20, FB_HEIGHT);
    writeU32Be(@intFromPtr(cfg_ptr) + 24, FB_STRIDE);
    if (!writeRamfbConfig(key, cfg_ptr)) return null;
    return RamfbInfo{
        .addr = RAMFB_PHYS,
        .pitch = FB_STRIDE,
        .width = FB_WIDTH,
        .height = FB_HEIGHT,
        .bpp = 32,
        .fb_type = 1,
    };
}
