// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/virtio_gpu_pci.zig
// Purpose: VirtIO-GPU PCI (1af4:1050) modern transport；`GET_DISPLAY_INFO` + `RESOURCE_CREATE_2D` + `TRANSFER_*` scratch 自检与可选帧缓冲往返。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html (GPU device, PCI)

const builtin = @import("builtin");
const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const pcie = @import("../bus/pcie.zig");
const vm = @import("../../mm/vm.zig");
const fb = @import("framebuffer.zig");
const spec = @import("virtio_gpu_spec.zig");

const VIRTIO_PCI_CAP: u8 = 0x09;
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;

const VIRTIO_F_VERSION_1: u32 = 1;
const STATUS_ACK: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 128;
const STATUS_DRIVER_OK: u8 = 4;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

var probed_gpu: bool = false;
var gpu_loc: ?pcie.PciLoc = null;
var gpu_offload_ready: bool = false;

var common_base: usize = 0;
var notify_base: usize = 0;
var notify_mult: u32 = 0;
var queue_notify_off: u16 = 0;
var queue_size: u16 = 0;

var ring_page: [4096]u8 align(4096) = undefined;
/// Guest RAM backing for `CMD_RESOURCE_ATTACH_BACKING` (32×32 B8G8R8X8 → 4096 bytes).
var gpu_scratch_mem: [4096]u8 align(4096) = undefined;
var desc_off: usize = 0;
var avail_off: usize = 0;
var used_off: usize = 0;
var local_avail_idx: u16 = 0;
var last_used_idx: u16 = 0;

const gpu_scratch_res_id: u32 = 1;
const gpu_scratch_dim: u32 = 32;

/// True after PCI locate of 1af4:1050（MMIO 尚未就绪时亦为 true）。
pub fn isPresent() bool {
    return probed_gpu;
}

fn pciReadLe32(loc: pcie.PciLoc, off: u16) u32 {
    var v: u32 = 0;
    var i: u16 = 0;
    while (i < 4) : (i += 1) {
        const sh: u5 = @intCast(i * 8);
        v |= @as(u32, pcie.readConfigByte(loc.bus, loc.dev, loc.func, off + i)) << sh;
    }
    return v;
}

fn barMmioPhys(loc: pcie.PciLoc, idx: u8) ?u64 {
    const raw = pcie.readConfigDword(loc.bus, loc.dev, loc.func, @as(u16, 0x10) + @as(u16, idx) * 4);
    if (raw == 0xFFFFFFFF) return null;
    if ((raw & 1) != 0) return null;
    const typ = (raw >> 1) & 3;
    if (typ == 2) {
        const hi = pcie.readConfigDword(loc.bus, loc.dev, loc.func, @as(u16, 0x10) + @as(u16, idx + 1) * 4);
        return (@as(u64, hi) << 32) | (@as(u64, raw) & 0xFFFF_FFF0);
    }
    return @as(u64, raw) & 0xFFFF_FFF0;
}

fn mapBarIfNeeded(phys: u64) bool {
    if (phys == 0) return false;
    return vm.mapDeviceMmioIdentity(phys, 0x10000);
}

fn fullMemoryFence() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        .loongarch64 => asm volatile ("dbar 0" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

fn mmio_w8(base: usize, off: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(base + off)).* = v;
}

fn mmio_r8(base: usize, off: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(base + off)).*;
}

fn mmio_w16(base: usize, off: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(base + off)).* = v;
}

fn mmio_r16(base: usize, off: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(base + off)).*;
}

fn mmio_w32(base: usize, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}

fn mmio_r32(base: usize, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}

fn pciEnableMmioMaster(loc: pcie.PciLoc) void {
    const cmd = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x04);
    const lo: u16 = @truncate(cmd);
    const new_lo = lo | 0x6; // memory space + bus master
    if (new_lo == lo) return;
    pcie.writeConfigDword(loc.bus, loc.dev, loc.func, 0x04, (@as(u32, cmd) & 0xFFFF0000) | new_lo);
}

fn failGpu(st: u8) void {
    if (common_base != 0) {
        mmio_w8(common_base, 0x14, st | STATUS_FAILED);
    }
    klog.warn("VirtIO-GPU: init failed (status=0x%x)", .{st});
}

fn descTable() [*]VirtqDesc {
    return @as([*]VirtqDesc, @ptrFromInt(@intFromPtr(&ring_page) + desc_off));
}

fn readUsedIdx() u16 {
    const p = @intFromPtr(&ring_page) + used_off;
    return @as(*volatile u16, @ptrFromInt(p + 2)).*;
}

fn writeAvailIdx(val: u16) void {
    const p = @intFromPtr(&ring_page) + avail_off;
    @as(*volatile u16, @ptrFromInt(p + 2)).* = val;
}

fn availRingIndex(i: u16) *volatile u16 {
    const p = @intFromPtr(&ring_page) + avail_off + 4 + @as(usize, @intCast(i)) * 2;
    return @as(*volatile u16, @ptrFromInt(p));
}

fn kickControlQueue() void {
    if (notify_base == 0) return;
    mmio_w16(common_base, 0x16, 0);
    fullMemoryFence();
    const port: usize = if (notify_mult == 0)
        notify_base
    else
        notify_base + @as(usize, notify_mult) * @as(usize, queue_notify_off);
    @as(*volatile u16, @ptrFromInt(port)).* = 0;
}

pub fn probe() void {
    if (!pcie.supports_pci_config) return;
    const ids = [_]u16{spec.pci_device_gpu};
    if (pcie.findDevicePci0(spec.pci_vendor_virtio, &ids)) |loc| {
        probed_gpu = true;
        gpu_loc = loc;
        klog.info("VirtIO-GPU PCI: 1af4:1050 detected (MMIO bring-up deferred to desktop init)", .{});
    }
}

/// 在帧缓冲与 `mapDeviceMmioIdentity` 可用后调用（如 `display.initAeroDwm`）；2D 自检通过则 `compositorOffloadAvailable()==true`。
pub fn bringupMmioIfProbed() void {
    if (!probed_gpu) return;
    if (gpu_offload_ready) return;
    const loc = gpu_loc orelse return;
    if (tryGpuBringup(loc)) {
        gpu_offload_ready = true;
        klog.info("VirtIO-GPU: GET_DISPLAY_INFO + RESOURCE_CREATE_2D + TRANSFER_* scratch loop ok (offload active)", .{});
        klog.info("VirtIO-GPU: full-frame Aero blur/composite remains CPU; ≤32×32 present PoC + roadmap: SOFTWARE_COMPOSITOR_WDDM.md", .{});
    }
}

/// Submit one control-queue command (`req` copied to the fixed guest page); returns response `type` or `null` on timeout.
fn submitControl(req: []const u8, rsp_len: u32) ?u32 {
    if (req.len > 0xF0) return null;
    @memcpy(ring_page[0x200..][0..req.len], req);
    @memset(ring_page[0x300..][0..512], 0);

    const page_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&ring_page)));
    const req_phys: u64 = page_phys + 0x200;
    const rsp_phys: u64 = page_phys + 0x300;

    descTable()[0] = .{ .addr = req_phys, .len = @intCast(req.len), .flags = VRING_DESC_F_NEXT, .next = 1 };
    descTable()[1] = .{ .addr = rsp_phys, .len = rsp_len, .flags = VRING_DESC_F_WRITE, .next = 0 };

    const ai = local_avail_idx % queue_size;
    availRingIndex(ai).* = 0;
    local_avail_idx +%= 1;
    writeAvailIdx(local_avail_idx);
    fullMemoryFence();
    kickControlQueue();

    var poll: u32 = 0;
    while (poll < 200_000) : (poll += 1) {
        fullMemoryFence();
        if (readUsedIdx() != last_used_idx) {
            last_used_idx = readUsedIdx();
            return std.mem.readInt(u32, ring_page[0x300..][0..4], .little);
        }
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return null;
}

fn tryGpuScratch2dValidate() bool {
    var cmd: [64]u8 = undefined;
    spec.writeResourceCreate2D(cmd[0..spec.resource_create_2d_req_len], gpu_scratch_res_id, spec.FORMAT_B8G8R8X8_UNORM, gpu_scratch_dim, gpu_scratch_dim);
    const rt0 = submitControl(cmd[0..spec.resource_create_2d_req_len], 64) orelse return false;
    if (rt0 != spec.RESP_OK_NODATA) return false;

    const phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_scratch_mem)));
    spec.writeResourceAttachBacking1(cmd[0..spec.resource_attach_backing_1_req_len], gpu_scratch_res_id, phys, gpu_scratch_mem.len);
    const rt1 = submitControl(cmd[0..spec.resource_attach_backing_1_req_len], 64) orelse return false;
    if (rt1 != spec.RESP_OK_NODATA) return false;

    const pat: u32 = 0xCAFE_BABE;
    var i: usize = 0;
    while (i < gpu_scratch_mem.len) : (i += 4) {
        std.mem.writeInt(u32, gpu_scratch_mem[i..][0..4], pat, .little);
    }

    spec.writeTransferHost2D(cmd[0..spec.transfer_host_2d_req_len], spec.CMD_TRANSFER_FROM_HOST_2D, gpu_scratch_res_id, 0, 0, gpu_scratch_dim, gpu_scratch_dim, 0);
    const rt2 = submitControl(cmd[0..spec.transfer_host_2d_req_len], 64) orelse return false;
    if (rt2 != spec.RESP_OK_NODATA) return false;

    @memset(&gpu_scratch_mem, 0x5A);

    spec.writeTransferHost2D(cmd[0..spec.transfer_host_2d_req_len], spec.CMD_TRANSFER_TO_HOST_2D, gpu_scratch_res_id, 0, 0, gpu_scratch_dim, gpu_scratch_dim, 0);
    const rt3 = submitControl(cmd[0..spec.transfer_host_2d_req_len], 64) orelse return false;
    if (rt3 != spec.RESP_OK_NODATA) return false;

    i = 0;
    while (i < gpu_scratch_mem.len) : (i += 4) {
        const v = std.mem.readInt(u32, gpu_scratch_mem[i..][0..4], .little);
        if (v != pat) return false;
    }
    return true;
}

/// 将帧缓冲子矩形经 VirtIO-GPU 传输到同一 scratch 并读回（恒等校验）。`pw`/`ph` ≤ 32，且须为 32bpp（与 scratch 格式一致）。
pub fn compositorTryRoundTripFramebufferRect(px: u32, py: u32, pw: u32, ph: u32) bool {
    if (!gpu_offload_ready) return false;
    if (pw > gpu_scratch_dim or ph > gpu_scratch_dim or pw == 0 or ph == 0) return false;
    if (!fb.isInitialized()) return false;
    if (fb.getBpp() != 32) return false;

    const dx: i32 = @intCast(px);
    const dy: i32 = @intCast(py);
    const w: i32 = @intCast(pw);
    const h: i32 = @intCast(ph);

    const row_bytes: usize = @as(usize, @intCast(pw)) * 4;
    const need: usize = @as(usize, @intCast(ph)) * row_bytes;
    if (need > gpu_scratch_mem.len) return false;

    const n = fb.copyDrawBufferRectBytes(dx, dy, w, h, &gpu_scratch_mem);
    if (n != need) return false;

    var saved: [4096]u8 = undefined;
    @memcpy(saved[0..need], gpu_scratch_mem[0..need]);

    var cmd: [64]u8 = undefined;
    spec.writeTransferHost2D(cmd[0..spec.transfer_host_2d_req_len], spec.CMD_TRANSFER_FROM_HOST_2D, gpu_scratch_res_id, 0, 0, pw, ph, 0);
    const rt0 = submitControl(cmd[0..spec.transfer_host_2d_req_len], 64) orelse return false;
    if (rt0 != spec.RESP_OK_NODATA) return false;

    @memset(gpu_scratch_mem[0..gpu_scratch_mem.len], 0x77);

    spec.writeTransferHost2D(cmd[0..spec.transfer_host_2d_req_len], spec.CMD_TRANSFER_TO_HOST_2D, gpu_scratch_res_id, 0, 0, pw, ph, 0);
    const rt1 = submitControl(cmd[0..spec.transfer_host_2d_req_len], 64) orelse return false;
    if (rt1 != spec.RESP_OK_NODATA) return false;

    return std.mem.eql(u8, gpu_scratch_mem[0..need], saved[0..need]);
}

fn tryGpuBringup(loc: pcie.PciLoc) bool {
    pciEnableMmioMaster(loc);

    var common_bar: u8 = 0xFF;
    var common_off: u32 = 0;
    var notify_bar: u8 = 0xFF;
    var notify_off: u32 = 0;
    var notify_mult_local: u32 = 0;

    const st_word = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x04);
    const status_hi: u16 = @truncate(st_word >> 16);
    if ((status_hi & 0x10) == 0) return false;

    var cap_ptr: u16 = pcie.readConfigByte(loc.bus, loc.dev, loc.func, 0x34);
    while (cap_ptr != 0) {
        const cap_id = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr);
        const next = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 1);
        const cap_len = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 2);
        if (cap_id == VIRTIO_PCI_CAP and cap_len >= 16) {
            const cfg_t = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 3);
            const bar = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 4);
            const off = pciReadLe32(loc, cap_ptr + 8);
            _ = pciReadLe32(loc, cap_ptr + 12);
            switch (cfg_t) {
                VIRTIO_PCI_CAP_COMMON_CFG => {
                    common_bar = bar;
                    common_off = off;
                },
                VIRTIO_PCI_CAP_NOTIFY_CFG => {
                    notify_bar = bar;
                    notify_off = off;
                    if (cap_len >= 20) {
                        notify_mult_local = pciReadLe32(loc, cap_ptr + 16);
                    }
                },
                else => {},
            }
        }
        cap_ptr = next;
    }

    if (common_bar >= 6 or notify_bar >= 6) return false;

    const b_phys_c = barMmioPhys(loc, common_bar) orelse return false;
    const b_phys_n = barMmioPhys(loc, notify_bar) orelse return false;
    if (!mapBarIfNeeded(b_phys_c)) return false;
    if (b_phys_n != b_phys_c) {
        if (!mapBarIfNeeded(b_phys_n)) return false;
    }

    common_base = @intCast(b_phys_c + common_off);
    notify_base = @intCast(b_phys_n + notify_off);
    notify_mult = notify_mult_local;

    mmio_w8(common_base, 0x14, 0);
    mmio_w8(common_base, 0x14, STATUS_ACK | STATUS_DRIVER);

    mmio_w32(common_base, 0x0, 1);
    const dev_hi = mmio_r32(common_base, 0x4);
    if ((dev_hi & VIRTIO_F_VERSION_1) != 0) {
        mmio_w32(common_base, 0x8, 1);
        mmio_w32(common_base, 0xc, VIRTIO_F_VERSION_1);
    }

    mmio_w8(common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    const st = mmio_r8(common_base, 0x14);
    if ((st & STATUS_FEATURES_OK) == 0) {
        failGpu(st);
        return false;
    }

    mmio_w16(common_base, 0x16, 0);
    fullMemoryFence();
    const qs = mmio_r16(common_base, 0x18);
    if (qs < 2 or qs > 1024) {
        failGpu(mmio_r8(common_base, 0x14));
        return false;
    }
    queue_size = @min(qs, 8);
    mmio_w16(common_base, 0x18, queue_size);
    mmio_w16(common_base, 0x1a, 0xFFFF);

    desc_off = 0;
    avail_off = 16 * @as(usize, @intCast(queue_size));
    var u_tmp = avail_off + 4 + 2 * @as(usize, @intCast(queue_size));
    u_tmp = (u_tmp + 3) & ~@as(usize, 3);
    used_off = u_tmp;
    const used_end = used_off + 4 + 8 * @as(usize, @intCast(queue_size));
    if (used_end > ring_page.len) {
        failGpu(mmio_r8(common_base, 0x14));
        return false;
    }

    @memset(&ring_page, 0);
    local_avail_idx = 0;
    last_used_idx = 0;

    const page_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&ring_page)));

    mmio_w32(common_base, 0x20, @truncate(page_phys));
    mmio_w32(common_base, 0x24, @truncate(page_phys >> 32));
    mmio_w32(common_base, 0x28, @truncate(page_phys + avail_off));
    mmio_w32(common_base, 0x2c, @truncate((page_phys + avail_off) >> 32));
    mmio_w32(common_base, 0x30, @truncate(page_phys + used_off));
    mmio_w32(common_base, 0x34, @truncate((page_phys + used_off) >> 32));

    queue_notify_off = mmio_r16(common_base, 0x1e);
    mmio_w16(common_base, 0x1c, 1);

    mmio_w8(common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    fullMemoryFence();

    var hdr: [24]u8 = undefined;
    spec.writeCtrlHdrType(&hdr, spec.CMD_GET_DISPLAY_INFO);
    const rt_info = submitControl(&hdr, 512) orelse return false;
    if (rt_info != spec.RESP_OK_DISPLAY_INFO) return false;

    return tryGpuScratch2dValidate();
}

/// `true` 当控制队列完成 `GET_DISPLAY_INFO` 且 scratch 上 `CREATE_2D` + `TRANSFER_*` 自检通过。
pub fn compositorOffloadAvailable() bool {
    return gpu_offload_ready;
}

/// 帧缓冲子矩形经 scratch `RESOURCE` 做 **FROM_HOST + TO_HOST** 恒等校验（与 `compositorTryRoundTripFramebufferRect` 同路径）。
/// 尚非真实 scanout 纹理；`w,h` 须 ≤32 且与 scratch 格式一致。失败时调用方仍走 CPU `flip`/`flipDirty`。
/// 见 `SOFTWARE_COMPOSITOR_WDDM.md` 第七阶段与 `display.present` 注释。
pub fn trySubmitFramebufferDirtyRect(
    scr_w: u32,
    scr_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) bool {
    _ = scr_w;
    _ = scr_h;
    if (!gpu_offload_ready) return false;
    if (w == 0 or h == 0) return false;
    if (w > gpu_scratch_dim or h > gpu_scratch_dim) return false;
    return compositorTryRoundTripFramebufferRect(x, y, w, h);
}
