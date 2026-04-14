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
// Module: src/drivers/video/virtio/virtio_gpu_pci.zig
// Purpose: VirtIO-GPU PCI (1af4:1050) modern transport；控制队列、`GET_DISPLAY_INFO`、scratch `TRANSFER_*` 自检、**SET_SCANOUT**（guest 帧缓冲 backing + `RESOURCE_FLUSH` 减设备侧陈旧像素）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html (GPU device, PCI)

const builtin = @import("builtin");
const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const pcie = @import("../../bus/pcie.zig");
const vm = @import("../../../mm/vm.zig");
const fb = @import("../core/framebuffer.zig");
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
/// 屏前缓冲已 attach 且 `CMD_SET_SCANOUT` 成功；`present` 后仅需 `RESOURCE_FLUSH`（无需整屏 `TRANSFER`，CPU 仍负责 back→front memcpy）。
var scanout_active: bool = false;
var scanout_w: u32 = 0;
var scanout_h: u32 = 0;

var common_base: usize = 0;
var notify_base: usize = 0;
var notify_mult: u32 = 0;
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
const gpu_scanout_res_id: u32 = 2;
const gpu_scratch_dim: u32 = 32;

/// 控制队列请求/响应分置于低 4KiB 与高 4KiB，满足设备对描述符 GPA 的常见对齐假设。
const gpu_cmd_io_split: usize = 4096;
var gpu_cmd_io: [8192]u8 align(4096) = undefined;
/// 大块 `RESOURCE_ATTACH_BACKING`（多 mem_entry）请求体；响应仍用 `gpu_cmd_io` 高半区。长度与 `virtio_gpu_spec.max_attach_backing_wire_bytes`（4K@32bpp 最坏页散列）一致。
var gpu_attach_blob: [spec.max_attach_backing_wire_bytes]u8 align(4096) = undefined;

/// 设备特性 low（`device_feature_select=0` 读回）；bit0 = VirGL（Linux `VIRTIO_GPU_F_VIRGL`）。
var device_features_low: u32 = 0;
var virgl_feature_negotiated: bool = false;
var virgl_ctx_alive: bool = false;
/// `CMD_SUBMIT_3D` 空载荷至少一次得到 `RESP_OK_NODATA`（VirGL MVP；不表示可用模糊卸载）。
var virgl_submit3d_noop_ok: bool = false;
const virgl_gpu_ctx_id: u32 = 1;
var scanout_multipage_backing: bool = false;

/// `present()` 内控制队列操作预算，避免单帧过量 MMIO 轮询（见 `beginPresentVirtioBudget`）。
var present_virtio_budget: u32 = 0;
var present_virtio_budget_active: bool = false;

var ring_cursor: [4096]u8 align(4096) = undefined;
var queue_size_cursor: u16 = 0;
var desc_off_c: usize = 0;
var avail_off_c: usize = 0;
var used_off_c: usize = 0;
var local_avail_idx_c: u16 = 0;
var last_used_idx_c: u16 = 0;
var cursor_queue_ready: bool = false;
var gpu_cursor_io: [4096]u8 align(4096) = undefined;
const gpu_cursor_io_split: usize = 2048;
var hardware_cursor_move_ok: bool = false;

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

fn descTableCursor() [*]VirtqDesc {
    return @as([*]VirtqDesc, @ptrFromInt(@intFromPtr(&ring_cursor) + desc_off_c));
}

fn readUsedIdxCursor() u16 {
    const p = @intFromPtr(&ring_cursor) + used_off_c;
    return @as(*volatile u16, @ptrFromInt(p + 2)).*;
}

fn writeAvailIdxCursor(val: u16) void {
    const p = @intFromPtr(&ring_cursor) + avail_off_c;
    @as(*volatile u16, @ptrFromInt(p + 2)).* = val;
}

fn availRingIndexCursor(i: u16) *volatile u16 {
    const p = @intFromPtr(&ring_cursor) + avail_off_c + 4 + @as(usize, @intCast(i)) * 2;
    return @as(*volatile u16, @ptrFromInt(p));
}

fn kickCursorQueue() void {
    if (notify_base == 0 or !cursor_queue_ready) return;
    mmio_w16(common_base, 0x16, spec.vq_cursor);
    fullMemoryFence();
    const notify_off_c = mmio_r16(common_base, 0x1e);
    const port: usize = if (notify_mult == 0)
        notify_base
    else
        notify_base + @as(usize, notify_mult) * @as(usize, notify_off_c);
    @as(*volatile u16, @ptrFromInt(port)).* = spec.vq_cursor;
}

fn kickControlQueue() void {
    if (notify_base == 0) return;
    mmio_w16(common_base, 0x16, spec.vq_control);
    fullMemoryFence();
    const no = mmio_r16(common_base, 0x1e);
    const port: usize = if (notify_mult == 0)
        notify_base
    else
        notify_base + @as(usize, notify_mult) * @as(usize, no);
    @as(*volatile u16, @ptrFromInt(port)).* = spec.vq_control;
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
        if (trySetupScanoutFromFramebuffer()) {
            klog.info("VirtIO-GPU: SET_SCANOUT + guest-RAM backing (flip + RESOURCE_FLUSH); see SOFTWARE_COMPOSITOR_WDDM.md", .{});
        } else if (klog.DEBUG_MODE) {
            klog.debug("VirtIO-GPU: scanout off (pitch/contiguity); scratch TRANSFER PoC only", .{});
        }
    }
}

pub fn beginPresentVirtioBudget() void {
    present_virtio_budget = 32;
    present_virtio_budget_active = true;
}

pub fn endPresentVirtioBudget() void {
    present_virtio_budget_active = false;
}

/// Submit one control-queue command；`req_phys` 指向请求 GPA，`rsp` 仍写入 `gpu_cmd_io` 高半区。
fn submitControlRaw(req_phys: u64, req_len: u32, rsp_len: u32) ?u32 {
    if (rsp_len > 3800 or rsp_len < 4) return null;
    if (present_virtio_budget_active) {
        if (present_virtio_budget == 0) return null;
        present_virtio_budget -= 1;
    }
    @memset(gpu_cmd_io[gpu_cmd_io_split..][0..rsp_len], 0);
    const rsp_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_cmd_io)) + @as(u64, gpu_cmd_io_split));

    descTable()[0] = .{ .addr = req_phys, .len = req_len, .flags = VRING_DESC_F_NEXT, .next = 1 };
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
            return std.mem.readInt(u32, gpu_cmd_io[gpu_cmd_io_split..][0..4], .little);
        }
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return null;
}

/// 小请求：`req` 拷入 `gpu_cmd_io` 低半区。
fn submitControl(req: []const u8, rsp_len: u32) ?u32 {
    if (req.len > gpu_cmd_io_split - 64) return null;
    @memcpy(gpu_cmd_io[0..req.len], req);
    const page_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_cmd_io)));
    return submitControlRaw(page_phys, @intCast(req.len), rsp_len);
}

/// 大块 attach 等：请求已在 `gpu_attach_blob`（或调用方保证 GPA 连续可 DMA）。
fn submitControlFromAttachBlob(req_len: usize, rsp_len: u32) ?u32 {
    if (req_len > gpu_attach_blob.len) return null;
    const phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_attach_blob)));
    return submitControlRaw(phys, @intCast(req_len), rsp_len);
}

/// 光标队列：`req` 置于 `gpu_cursor_io` 低半区，响应高半区。
fn submitCursor(req_len: u32, rsp_len: u32) ?u32 {
    if (!cursor_queue_ready) return null;
    if (req_len > gpu_cursor_io_split - 64 or rsp_len > gpu_cursor_io_split - 64 or rsp_len < 4) return null;
    if (present_virtio_budget_active) {
        if (present_virtio_budget == 0) return null;
        present_virtio_budget -= 1;
    }
    @memset(gpu_cursor_io[gpu_cursor_io_split..][0..rsp_len], 0);
    const req_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_cursor_io)));
    const rsp_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&gpu_cursor_io)) + @as(u64, gpu_cursor_io_split));

    descTableCursor()[0] = .{ .addr = req_phys, .len = req_len, .flags = VRING_DESC_F_NEXT, .next = 1 };
    descTableCursor()[1] = .{ .addr = rsp_phys, .len = rsp_len, .flags = VRING_DESC_F_WRITE, .next = 0 };

    const ai = local_avail_idx_c % queue_size_cursor;
    availRingIndexCursor(ai).* = 0;
    local_avail_idx_c +%= 1;
    writeAvailIdxCursor(local_avail_idx_c);
    fullMemoryFence();
    kickCursorQueue();

    var poll: u32 = 0;
    while (poll < 200_000) : (poll += 1) {
        fullMemoryFence();
        if (readUsedIdxCursor() != last_used_idx_c) {
            last_used_idx_c = readUsedIdxCursor();
            return std.mem.readInt(u32, gpu_cursor_io[gpu_cursor_io_split..][0..4], .little);
        }
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return null;
}

pub fn trySetupScanoutFromFramebuffer() bool {
    scanout_active = false;
    scanout_w = 0;
    scanout_h = 0;
    scanout_multipage_backing = false;
    if (!gpu_offload_ready) return false;
    if (!fb.isInitialized()) return false;
    const w = fb.getWidth();
    const h = fb.getHeight();
    if (w == 0 or h == 0) return false;

    var local_entries: [spec.max_virtio_backing_mem_entries]fb.VirtioBackingMemEntry = undefined;
    const n: usize = blk: {
        if (fb.getFrontBufferPhysContiguousForVirtio()) |span| {
            local_entries[0] = .{ .addr = span.base, .length = @intCast(span.len) };
            break :blk 1;
        }
        const m = fb.fillFrontBufferVirtioBackingEntries(&local_entries) orelse return false;
        if (m == 0) return false;
        break :blk m;
    };
    scanout_multipage_backing = n > 1;

    var spec_entries: [spec.max_virtio_backing_mem_entries]spec.GpuMemEntry = undefined;
    for (0..n) |i| {
        spec_entries[i] = .{ .addr = local_entries[i].addr, .length = local_entries[i].length };
    }
    const attach_len = spec.resourceAttachBackingReqLen(n);
    if (attach_len > gpu_attach_blob.len) return false;

    var cmd: [512]u8 = undefined;
    spec.writeResourceCreate2D(cmd[0..spec.resource_create_2d_req_len], gpu_scanout_res_id, spec.FORMAT_B8G8R8X8_UNORM, w, h);
    const rt0 = submitControl(cmd[0..spec.resource_create_2d_req_len], 64) orelse return false;
    if (rt0 != spec.RESP_OK_NODATA) return false;

    spec.writeResourceAttachBackingN(gpu_attach_blob[0..attach_len], gpu_scanout_res_id, spec_entries[0..n]);
    const rt1 = submitControlFromAttachBlob(attach_len, 64) orelse return false;
    if (rt1 != spec.RESP_OK_NODATA) return false;

    spec.writeSetScanout(cmd[0..spec.set_scanout_req_len], 0, gpu_scanout_res_id, 0, 0, w, h);
    const rt2 = submitControl(cmd[0..spec.set_scanout_req_len], 64) orelse return false;
    if (rt2 != spec.RESP_OK_NODATA) return false;

    spec.writeResourceFlush(cmd[0..spec.resource_flush_req_len], gpu_scanout_res_id, 0, 0, w, h);
    _ = submitControl(cmd[0..spec.resource_flush_req_len], 64) orelse return false;

    scanout_active = true;
    scanout_w = w;
    scanout_h = h;
    klog.info("VirtIO-GPU: scanout resource=%u %ux%u mem_entries=%u multipage=%s (guest RAM + RESOURCE_FLUSH)", .{
        gpu_scanout_res_id, w, h, @as(u32, @truncate(n)), if (n > 1) "yes" else "no",
    });
    return true;
}

/// 释放 scanout 资源以便在帧缓冲尺寸变化后重建（`CMD_SET_SCANOUT` resource=0 → detach → unref）。
pub fn tearDownScanoutResource() void {
    const had_scanout = scanout_active;
    scanout_active = false;
    scanout_w = 0;
    scanout_h = 0;
    scanout_multipage_backing = false;
    if (!gpu_offload_ready or !had_scanout) return;

    var cmd: [64]u8 = undefined;
    spec.writeSetScanout(cmd[0..spec.set_scanout_req_len], 0, 0, 0, 0, 0, 0);
    _ = submitControl(cmd[0..spec.set_scanout_req_len], 64);

    spec.writeResourceDetachBacking(cmd[0..spec.resource_detach_backing_req_len], gpu_scanout_res_id);
    _ = submitControl(cmd[0..spec.resource_detach_backing_req_len], 64);

    spec.writeResourceUnref(cmd[0..spec.resource_unref_req_len], gpu_scanout_res_id);
    _ = submitControl(cmd[0..spec.resource_unref_req_len], 64);
}

/// 帧缓冲 `fb.init` 改几何后重建 guest-RAM scanout（失败则保持 `scanout_active=false`）。
pub fn refreshScanoutAfterFramebufferResize() void {
    if (!gpu_offload_ready) return;
    tearDownScanoutResource();
    if (trySetupScanoutFromFramebuffer()) {
        klog.info("VirtIO-GPU: scanout refreshed after framebuffer resize", .{});
    }
}

/// `true` 当 `SET_SCANOUT` 已绑定屏前缓冲；与 `compositorOffloadAvailable`（scratch 自检）独立。
pub fn isScanoutActive() bool {
    return scanout_active;
}

/// 在 `flip`/`flipDirty` 将像素写入屏前 RAM **之后**调用；`dirty_opt` 为 `peekDirtyUnionPx` 在外包（`null` 则整屏 flush）。
pub fn notifyScanoutFrontUpdated(dirty_opt: ?fb.Rect) void {
    if (!scanout_active) return;
    const w = scanout_w;
    const h = scanout_h;
    if (w == 0 or h == 0) return;

    var rx: u32 = 0;
    var ry: u32 = 0;
    var rw: u32 = w;
    var rh: u32 = h;
    if (dirty_opt) |r| {
        if (r.w > 0 and r.h > 0) {
            const fw: i32 = @intCast(w);
            const fh: i32 = @intCast(h);
            const x0 = std.math.clamp(r.x, 0, fw -| 1);
            const y0 = std.math.clamp(r.y, 0, fh -| 1);
            const x1 = std.math.clamp(r.x + r.w, 0, fw);
            const y1 = std.math.clamp(r.y + r.h, 0, fh);
            if (x1 > x0 and y1 > y0) {
                rx = @intCast(x0);
                ry = @intCast(y0);
                rw = @intCast(x1 - x0);
                rh = @intCast(y1 - y0);
            }
        }
    }

    var cmd: [64]u8 = undefined;
    spec.writeResourceFlush(cmd[0..spec.resource_flush_req_len], gpu_scanout_res_id, rx, ry, rw, rh);
    _ = submitControl(cmd[0..spec.resource_flush_req_len], 64);

    const flip_journal = @import("../core/display_flip_journal.zig");
    flip_journal.noteVirtioResourceFlush(rw >= w and rh >= h);
    // 单 scanout 资源一次 flush；第二平面（overlay）落地后在此传入累计次数 >1。
    flip_journal.noteVirtioPresentFlushBatch(1);
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

    mmio_w32(common_base, 0x0, 0);
    const dev_lo = mmio_r32(common_base, 0x4);
    device_features_low = dev_lo;
    virgl_feature_negotiated = (dev_lo & spec.FEATURE_MASK_VIRGL) != 0;
    var driver_lo: u32 = 0;
    if (virgl_feature_negotiated) {
        driver_lo |= spec.FEATURE_MASK_VIRGL;
        klog.info("VirtIO-GPU: device offers VIRGL (feature low bit0); negotiating", .{});
    }
    mmio_w32(common_base, 0x8, 0);
    mmio_w32(common_base, 0xc, driver_lo);

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
    if (qs < 1 or qs > 1024) {
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

    mmio_w16(common_base, 0x1c, 1);

    cursor_queue_ready = false;
    mmio_w16(common_base, 0x16, spec.vq_cursor);
    fullMemoryFence();
    const qs1 = mmio_r16(common_base, 0x18);
    if (qs1 >= 1 and qs1 <= 1024) {
        queue_size_cursor = @min(qs1, 8);
        mmio_w16(common_base, 0x18, queue_size_cursor);
        mmio_w16(common_base, 0x1a, 0xFFFF);

        desc_off_c = 0;
        avail_off_c = 16 * @as(usize, @intCast(queue_size_cursor));
        var uc = avail_off_c + 4 + 2 * @as(usize, @intCast(queue_size_cursor));
        uc = (uc + 3) & ~@as(usize, 3);
        used_off_c = uc;
        const used_end_c = used_off_c + 4 + 8 * @as(usize, @intCast(queue_size_cursor));
        if (used_end_c <= ring_cursor.len) {
            @memset(&ring_cursor, 0);
            local_avail_idx_c = 0;
            last_used_idx_c = 0;
            const page_phys_c: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&ring_cursor)));
            mmio_w32(common_base, 0x20, @truncate(page_phys_c));
            mmio_w32(common_base, 0x24, @truncate(page_phys_c >> 32));
            mmio_w32(common_base, 0x28, @truncate(page_phys_c + avail_off_c));
            mmio_w32(common_base, 0x2c, @truncate((page_phys_c + avail_off_c) >> 32));
            mmio_w32(common_base, 0x30, @truncate(page_phys_c + used_off_c));
            mmio_w32(common_base, 0x34, @truncate((page_phys_c + used_off_c) >> 32));
            mmio_w16(common_base, 0x1c, 1);
            cursor_queue_ready = true;
            klog.info("VirtIO-GPU: cursor queue enabled (vq=%u size=%u)", .{ spec.vq_cursor, queue_size_cursor });
        }
    }
    mmio_w16(common_base, 0x16, 0);
    fullMemoryFence();

    mmio_w8(common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    fullMemoryFence();

    var hdr: [24]u8 = undefined;
    spec.writeCtrlHdrType(&hdr, spec.CMD_GET_DISPLAY_INFO);
    const rt_info = submitControl(&hdr, 512) orelse return false;
    if (rt_info != spec.RESP_OK_DISPLAY_INFO) return false;

    if (!tryGpuScratch2dValidate()) return false;

    virgl_ctx_alive = false;
    virgl_submit3d_noop_ok = false;
    if (virgl_feature_negotiated) {
        var cbuf: [spec.ctx_create_req_len]u8 = undefined;
        spec.writeCtxCreate(&cbuf, virgl_gpu_ctx_id, "zircon");
        if (submitControl(&cbuf, 64)) |rt_ctx| {
            if (rt_ctx == spec.RESP_OK_NODATA) {
                virgl_ctx_alive = true;
                klog.info("VirtIO-GPU: CMD_CTX_CREATE ok (ctx_id=%u); attempting SUBMIT_3D MVP noop", .{virgl_gpu_ctx_id});
                var s3d: [spec.submit_3d_hdr_len]u8 = undefined;
                spec.writeSubmit3dHdr(&s3d, virgl_gpu_ctx_id, 0);
                if (submitControl(&s3d, 64)) |rt_s3| {
                    if (rt_s3 == spec.RESP_OK_NODATA) {
                        virgl_submit3d_noop_ok = true;
                        klog.info("VirtIO-GPU: CMD_SUBMIT_3D size=0 ok (VirGL MVP noop)", .{});
                    } else {
                        klog.debug("VirtIO-GPU: CMD_SUBMIT_3D size=0 rsp=0x%x (non-fatal)", .{rt_s3});
                    }
                } else {
                    klog.debug("VirtIO-GPU: CMD_SUBMIT_3D noop transport skip", .{});
                }
            } else {
                klog.warn("VirtIO-GPU: CMD_CTX_CREATE unexpected rsp=0x%x", .{rt_ctx});
            }
        } else {
            klog.warn("VirtIO-GPU: CMD_CTX_CREATE timeout or transport fail (non-fatal)", .{});
        }
    }
    return true;
}

/// `true` 当控制队列完成 `GET_DISPLAY_INFO` 且 scratch 上 `CREATE_2D` + `TRANSFER_*` 自检通过。
pub fn compositorOffloadAvailable() bool {
    return gpu_offload_ready;
}

pub fn getDeviceFeaturesLow() u32 {
    return device_features_low;
}

pub fn virglFeatureNegotiated() bool {
    return virgl_feature_negotiated;
}

pub fn virglContextReady() bool {
    return virgl_ctx_alive;
}

pub fn virglSubmit3dNoopOk() bool {
    return virgl_submit3d_noop_ok;
}

pub fn scanoutUsesMultipageBacking() bool {
    return scanout_multipage_backing;
}

pub fn hardwareCursorActive() bool {
    return hardware_cursor_move_ok;
}

/// 每帧 `present` 末尾同步指针位置到 VirtIO 光标队列（成功后可关软件光标叠加）。
pub fn syncHardwareCursorFromPresent(cursor_x: i32, cursor_y: i32) void {
    if (!cursor_queue_ready or !scanout_active) return;
    const fw = scanout_w;
    const fh = scanout_h;
    if (fw == 0 or fh == 0) return;
    const max_x: i32 = if (fw > 0) @as(i32, @intCast(fw - 1)) else 0;
    const max_y: i32 = if (fh > 0) @as(i32, @intCast(fh - 1)) else 0;
    const cx = std.math.clamp(cursor_x, 0, max_x);
    const cy = std.math.clamp(cursor_y, 0, max_y);
    spec.writeMoveCursor(gpu_cursor_io[0..spec.move_cursor_req_len], 0, @intCast(cx), @intCast(cy));
    if (submitCursor(@intCast(spec.move_cursor_req_len), 64)) |rt| {
        if (rt == spec.RESP_OK_NODATA) {
            hardware_cursor_move_ok = true;
        }
    }
}

/// VirGL 上下文已就绪时尝试将盒式模糊交给 GPU；**不接** VirGL 命令流，`SUBMIT_3D` 仅在 bring-up 时空提交探测（`virglSubmit3dNoopOk`）；模糊仍 CPU。
pub fn tryVirglBlurBoxDelegation(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    radius: u32,
    passes: u32,
) bool {
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = radius;
    _ = passes;
    if (!virgl_ctx_alive) return false;
    return false;
}
