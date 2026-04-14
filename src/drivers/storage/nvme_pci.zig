// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/nvme_pci.zig
// Purpose: PCI 发现 NVM Express（010802）、BAR0 MMIO；Admin 队列 + Identify + Create I/O 队列 + NVM Read；
//          与 `ahci.zig` 共享 `BlockDevVTable` / 分区探测 / `E:\` 探测挂载（真机 NVMe 系统盘优先路径）。
//
// This is an independent clean-room implementation.
// Reference: NVM Express Base Specification — registers, Admin/IO SQ/CQE, Identify, NVM Read.

const std = @import("std");
const builtin = @import("builtin");
const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const io = @import("../../io/io.zig");
const frame = @import("../../mm/frame.zig");
const block_common = @import("block_dev_common.zig");
const part = @import("partition_table.zig");
const vfs = @import("../../fs/vfs.zig");

pub const NvmePciDev = struct {
    loc: pcie.PciLoc,
    vendor_id: u16,
    device_id: u16,
    bar0_phys: u64,
    bar0_size: u64,
};

fn pickBar0(bars: [6]pcie.PciBarResource) ?pcie.PciBarResource {
    const b0 = bars[0];
    if (!b0.is_io and b0.base != 0 and b0.size >= 0x1000) return b0;
    for (bars) |bar| {
        if (!bar.is_io and bar.base != 0 and bar.size >= 0x1000) return bar;
    }
    return null;
}

pub fn collectNvmePci(out: []NvmePciDev, max_bus: u8) usize {
    if (!pcie.supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = pcie.readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const vid: u16 = @truncate(id);
                const did: u16 = @truncate(id >> 16);
                const cls = pcie.readConfigDword(b, d, f, 0x08);
                if (pci_bind.lookupFromConfigClassWord(vid, did, cls) != .nvme) continue;

                pcie.enablePciMemAndBusMaster(b, d, f);
                const bars = pcie.decodePciBars(b, d, f);
                const bar0 = pickBar0(bars) orelse continue;
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = vid,
                        .device_id = did,
                        .bar0_phys = bar0.base,
                        .bar0_size = bar0.size,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

pub fn probeAndLog(max_bus: u8) void {
    var buf: [8]NvmePciDev = undefined;
    const c = collectNvmePci(buf[0..], max_bus);
    if (c == 0) {
        klog.info("NVMe: no PCI NVMe controller in bus 0..%u", .{max_bus});
        return;
    }
    var i: usize = 0;
    while (i < c) : (i += 1) {
        const e = buf[i];
        klog.info("NVMe: %u:%u.%u VID:DID=0x%x:0x%x BAR0 phys=0x%x size=0x%x", .{
            e.loc.bus,
            e.loc.dev,
            e.loc.func,
            e.vendor_id,
            e.device_id,
            e.bar0_phys,
            e.bar0_size,
        });
    }
}

// ── NVMe 寄存器（BAR0 前 8KiB 足够 Admin + QID1 doorbell）────────────────
const REG_CAP: usize = 0x00;
const REG_CC: usize = 0x14;
const REG_CSTS: usize = 0x1C;
const REG_AQA: usize = 0x24;
const REG_ASQ: usize = 0x28;
const REG_ACQ: usize = 0x30;

const CC_EN: u32 = 1 << 0;
const CC_IOSQES: u32 = 6 << 16;
const CC_IOCQES: u32 = 4 << 20;

const CSTS_RDY: u32 = 1 << 0;

const OPC_IDENTIFY: u8 = 0x06;
const OPC_CREATE_SQ: u8 = 0x01;
const OPC_CREATE_CQ: u8 = 0x05;
const OPC_NVM_READ: u8 = 0x02;
const OPC_NVM_WRITE: u8 = 0x01;
const OPC_FLUSH: u8 = 0x00;

const ADMIN_Q_DEPTH: u32 = 8;
const IO_Q_DEPTH: u32 = 8;
const IO_QID: u32 = 1;
const NSID_FIRST: u32 = 1;

var g_bar: usize = 0;
var g_db_stride: u32 = 4;
var g_storage_ready: bool = false;
var g_nsid: u32 = NSID_FIRST;
var g_sector0: [512]u8 = [_]u8{0} ** 512;
var g_partition_start_lba: u64 = 0;

var g_asq_phys: u64 = 0;
var g_acq_phys: u64 = 0;
var g_iosq_phys: u64 = 0;
var g_iocq_phys: u64 = 0;
var g_admin_sq_tail: u32 = 0;
var g_admin_cq_head: u32 = 0;
var g_admin_cq_phase: u1 = 1;
var g_admin_cid: u16 = 1;

var g_io_sq_tail: u32 = 0;
var g_io_cq_head: u32 = 0;
var g_io_cq_phase: u1 = 1;
var g_io_cid: u16 = 0x400;

var g_nvme_blk_ctx: u8 = 0;

fn mmioR32(bar: usize, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(bar + off)).*;
}

/// 身份映射下的队列内存（非 BAR 窗口）。
fn physR32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn mmioW32(bar: usize, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(bar + off)).* = v;
}

fn mmioR64(bar: usize, off: usize) u64 {
    const lo = mmioR32(bar, off);
    const hi = mmioR32(bar, off + 4);
    return @as(u64, lo) | (@as(u64, hi) << 32);
}

fn capDoorbellStride(cap: u64) u32 {
    const dstrd: u5 = @truncate((cap >> 32) & 0xF);
    return @as(u32, 4) << dstrd;
}

fn adminSqTailDb(bar: usize) usize {
    return bar + 0x1000;
}

fn adminCqHeadDb(bar: usize) usize {
    return bar + 0x1000 + @as(usize, g_db_stride);
}

fn ioSqTailDb(bar: usize) usize {
    return bar + 0x1000 + 2 * @as(usize, IO_QID) * @as(usize, g_db_stride);
}

fn ioCqHeadDb(bar: usize) usize {
    return bar + 0x1000 + (2 * @as(usize, IO_QID) + 1) * @as(usize, g_db_stride);
}

fn waitCstsRdy(bar: usize, want: bool) bool {
    var i: u32 = 0;
    while (i < 2_000_000) : (i += 1) {
        const rdy = (mmioR32(bar, REG_CSTS) & CSTS_RDY) != 0;
        if (rdy == want) return true;
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return false;
}

fn pollAdminCompletion(bar: usize) bool {
    const depth = ADMIN_Q_DEPTH;
    var spin: u32 = 0;
    while (spin < 5_000_000) : (spin += 1) {
        const cqe_off = g_admin_cq_head * 16;
        const dw3 = physR32(g_acq_phys + cqe_off + 12);
        const phase = @as(u1, @truncate(dw3 >> 16));
        if (phase != g_admin_cq_phase) {
            if (builtin.target.cpu.arch == .x86_64) asm volatile ("pause" ::: .{ .memory = true });
            continue;
        }
        const sts = (dw3 >> 17) & 0x3FFF;
        if (sts != 0) {
            klog.warn("NVMe: Admin CQE status=0x%x", .{sts});
            return false;
        }
        g_admin_cq_head = (g_admin_cq_head + 1) % depth;
        if (g_admin_cq_head == 0) g_admin_cq_phase +%= 1;
        mmioW32(bar, adminCqHeadDb(bar), g_admin_cq_head);
        return true;
    }
    klog.warn("NVMe: Admin CQE timeout", .{});
    return false;
}

fn submitAdminRaw(bar: usize, sqe: *const [64]u8) bool {
    const depth = ADMIN_Q_DEPTH;
    const slot = g_admin_sq_tail;
    @memcpy(@as([*]u8, @ptrFromInt(g_asq_phys + slot * 64))[0..64], sqe);
    g_admin_sq_tail = (g_admin_sq_tail + 1) % depth;
    mmioW32(bar, adminSqTailDb(bar), g_admin_sq_tail);
    return pollAdminCompletion(bar);
}

fn adminIdentify(bar: usize, cns: u32, nsid: u32, prp1: u64) bool {
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_IDENTIFY;
    std.mem.writeInt(u16, sqe[2..4], g_admin_cid, .little);
    g_admin_cid +%= 1;
    std.mem.writeInt(u32, sqe[4..8], nsid, .little);
    std.mem.writeInt(u64, sqe[24..32], prp1, .little);
    std.mem.writeInt(u32, sqe[40..44], cns, .little);
    return submitAdminRaw(bar, &sqe);
}

fn adminCreateIoCq(bar: usize, prp1: u64) bool {
    const cdw10 = ((IO_Q_DEPTH - 1) << 16) | IO_QID;
    const cdw11: u32 = 1;
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_CREATE_CQ;
    std.mem.writeInt(u16, sqe[2..4], g_admin_cid, .little);
    g_admin_cid +%= 1;
    std.mem.writeInt(u64, sqe[24..32], prp1, .little);
    std.mem.writeInt(u32, sqe[40..44], cdw10, .little);
    std.mem.writeInt(u32, sqe[44..48], cdw11, .little);
    return submitAdminRaw(bar, &sqe);
}

fn adminCreateIoSq(bar: usize, prp1: u64) bool {
    const cdw10 = ((IO_Q_DEPTH - 1) << 16) | IO_QID;
    const cdw11: u32 = IO_QID | (@as(u32, 1) << 17);
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_CREATE_SQ;
    std.mem.writeInt(u16, sqe[2..4], g_admin_cid, .little);
    g_admin_cid +%= 1;
    std.mem.writeInt(u64, sqe[24..32], prp1, .little);
    std.mem.writeInt(u32, sqe[40..44], cdw10, .little);
    std.mem.writeInt(u32, sqe[44..48], cdw11, .little);
    return submitAdminRaw(bar, &sqe);
}

fn pollIoCompletion(bar: usize) bool {
    const depth = IO_Q_DEPTH;
    var spin: u32 = 0;
    while (spin < 5_000_000) : (spin += 1) {
        const cqe_off = g_io_cq_head * 16;
        const dw3 = physR32(g_iocq_phys + cqe_off + 12);
        const phase = @as(u1, @truncate(dw3 >> 16));
        if (phase != g_io_cq_phase) {
            if (builtin.target.cpu.arch == .x86_64) asm volatile ("pause" ::: .{ .memory = true });
            continue;
        }
        const sts = (dw3 >> 17) & 0x3FFF;
        if (sts != 0) {
            klog.warn("NVMe: IO CQE status=0x%x", .{sts});
            return false;
        }
        g_io_cq_head = (g_io_cq_head + 1) % depth;
        if (g_io_cq_head == 0) g_io_cq_phase +%= 1;
        mmioW32(bar, ioCqHeadDb(bar), g_io_cq_head);
        return true;
    }
    klog.warn("NVMe: IO CQE timeout", .{});
    return false;
}

fn nvmeReadSector(bar: usize, lba: u64, out_phys: u64) bool {
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_NVM_READ;
    std.mem.writeInt(u16, sqe[2..4], g_io_cid, .little);
    g_io_cid +%= 1;
    std.mem.writeInt(u32, sqe[4..8], g_nsid, .little);
    std.mem.writeInt(u64, sqe[24..32], out_phys, .little);
    std.mem.writeInt(u32, sqe[40..44], @truncate(lba), .little);
    std.mem.writeInt(u32, sqe[44..48], @truncate(lba >> 32), .little);
    std.mem.writeInt(u32, sqe[48..52], 0, .little);

    const slot = g_io_sq_tail;
    @memcpy(@as([*]u8, @ptrFromInt(g_iosq_phys + slot * 64))[0..64], &sqe);
    g_io_sq_tail = (g_io_sq_tail + 1) % IO_Q_DEPTH;
    mmioW32(bar, ioSqTailDb(bar), g_io_sq_tail);
    return pollIoCompletion(bar);
}

/// NVM Write (OPC 0x01)：将一个 LBA (512B) 写入 `in_phys` 物理缓冲。
fn nvmeWriteSector(bar: usize, lba: u64, in_phys: u64) bool {
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_NVM_WRITE;
    std.mem.writeInt(u16, sqe[2..4], g_io_cid, .little);
    g_io_cid +%= 1;
    std.mem.writeInt(u32, sqe[4..8], g_nsid, .little);
    std.mem.writeInt(u64, sqe[24..32], in_phys, .little);
    std.mem.writeInt(u32, sqe[40..44], @truncate(lba), .little);
    std.mem.writeInt(u32, sqe[44..48], @truncate(lba >> 32), .little);
    std.mem.writeInt(u32, sqe[48..52], 0, .little);

    const slot = g_io_sq_tail;
    @memcpy(@as([*]u8, @ptrFromInt(g_iosq_phys + slot * 64))[0..64], &sqe);
    g_io_sq_tail = (g_io_sq_tail + 1) % IO_Q_DEPTH;
    mmioW32(bar, ioSqTailDb(bar), g_io_sq_tail);
    return pollIoCompletion(bar);
}

/// Flush (OPC 0x00)：将所有挂起的写数据刷新到非易失性存储。
fn nvmeFlush(bar: usize) bool {
    var sqe: [64]u8 = [_]u8{0} ** 64;
    sqe[0] = OPC_FLUSH;
    std.mem.writeInt(u16, sqe[2..4], g_io_cid, .little);
    g_io_cid +%= 1;
    std.mem.writeInt(u32, sqe[4..8], g_nsid, .little);

    const slot = g_io_sq_tail;
    @memcpy(@as([*]u8, @ptrFromInt(g_iosq_phys + slot * 64))[0..64], &sqe);
    g_io_sq_tail = (g_io_sq_tail + 1) % IO_Q_DEPTH;
    mmioW32(bar, ioSqTailDb(bar), g_io_sq_tail);
    return pollIoCompletion(bar);
}

fn namespaceLbads512(ident_ns: *const [4096]u8) bool {
    const flbas = ident_ns[26];
    const idx = flbas & 0xF;
    const lbaf_off: usize = 128 + @as(usize, idx) * 4;
    if (lbaf_off + 3 >= ident_ns.len) return false;
    const lbads = ident_ns[lbaf_off + 2];
    return lbads == 9;
}

fn probePartitionStartLba(fa: *frame.FrameAllocator) void {
    g_partition_start_lba = 0;
    if (part.isGptProtectiveMbr(&g_sector0)) {
        const sec1_phys = fa.allocZeroed() orelse return;
        defer fa.free(sec1_phys);
        if (!nvmeReadSector(g_bar, 1, sec1_phys)) return;
        var hdr: [512]u8 = undefined;
        @memcpy(&hdr, @as([*]const u8, @ptrFromInt(sec1_phys))[0..512]);
        const meta = part.parseGptHeaderMeta(&hdr) orelse return;
        if (meta.partition_entry_count == 0 or meta.partition_entry_size < 128) return;
        const ent_phys = fa.allocZeroed() orelse return;
        defer fa.free(ent_phys);
        if (!nvmeReadSector(g_bar, meta.partition_entry_lba, ent_phys)) return;
        var tab: [512]u8 = undefined;
        @memcpy(&tab, @as([*]const u8, @ptrFromInt(ent_phys))[0..512]);
        if (part.firstGptPartitionFromHeaderAndTable(&hdr, &tab)) |sl| {
            g_partition_start_lba = sl.start_lba;
            klog.info("NVMe: GPT first partition LBA start=0x{x} size=0x{x}", .{ sl.start_lba, sl.size_lba });
        }
    } else if (part.firstMbrPartition(&g_sector0)) |sl| {
        g_partition_start_lba = sl.start_lba;
        klog.info("NVMe: MBR first partition LBA start=0x{x} size=0x{x}", .{ sl.start_lba, sl.size_lba });
    }
}

fn readBlocksImpl(ctx: *anyopaque, lba: u64, buf: []u8) io.NTSTATUS {
    _ = ctx;
    if (!g_storage_ready or buf.len < 512 or (buf.len % 512) != 0) return io.STATUS_INVALID_PARAMETER;
    const fa = frame.kernelFrameAllocatorPtr();
    const sectors = buf.len / 512;
    const base = lba +% g_partition_start_lba;
    var s: u64 = 0;
    while (s < sectors) : (s += 1) {
        const slice = buf[s * 512 ..][0..512];
        const p = fa.allocZeroed() orelse return io.STATUS_INSUFFICIENT_RESOURCES;
        defer fa.free(p);
        const phys_lba = base +% s;
        if (!nvmeReadSector(g_bar, phys_lba, p)) return io.STATUS_IO_DEVICE_ERROR;
        @memcpy(slice, @as([*]const u8, @ptrFromInt(p))[0..512]);
    }
    return io.STATUS_SUCCESS;
}

fn writeBlocksImpl(ctx: *anyopaque, lba: u64, buf: []const u8) io.NTSTATUS {
    _ = ctx;
    if (!g_storage_ready or buf.len < 512 or (buf.len % 512) != 0) return io.STATUS_INVALID_PARAMETER;
    const fa = frame.kernelFrameAllocatorPtr();
    const sectors = buf.len / 512;
    const base = lba +% g_partition_start_lba;
    var s: u64 = 0;
    while (s < sectors) : (s += 1) {
        const slice = buf[s * 512 ..][0..512];
        const p = fa.allocZeroed() orelse return io.STATUS_INSUFFICIENT_RESOURCES;
        defer fa.free(p);
        @memcpy(@as([*]u8, @ptrFromInt(p))[0..512], slice);
        const phys_lba = base +% s;
        if (!nvmeWriteSector(g_bar, phys_lba, p)) return io.STATUS_IO_DEVICE_ERROR;
    }
    return io.STATUS_SUCCESS;
}

fn flushBlocksImpl(ctx: *anyopaque) io.NTSTATUS {
    _ = ctx;
    if (!g_storage_ready) return io.STATUS_DEVICE_NOT_READY;
    if (!nvmeFlush(g_bar)) {
        klog.warn("NVMe: FLUSH failed", .{});
        return io.STATUS_IO_DEVICE_ERROR;
    }
    return io.STATUS_SUCCESS;
}

pub fn blockDevVTableOrNull() ?block_common.BlockDevVTable {
    if (!g_storage_ready) return null;
    return .{
        .ctx = @ptrCast(&g_nvme_blk_ctx),
        .read_blocks = readBlocksImpl,
        .write_blocks = writeBlocksImpl,
        .flush_blocks = flushBlocksImpl,
    };
}

pub fn storageReady() bool {
    return g_storage_ready;
}

fn nvmeProbeOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    _ = path;
    f.file_size = 512;
    f.fs_data = 1;
    return .success;
}

fn nvmeProbeClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn nvmeProbeRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (f.fs_data == 0) return .{ .status = .invalid_parameter };
    var tmp: [512]u8 = undefined;
    const st = readBlocksImpl(@ptrCast(&g_nvme_blk_ctx), 0, &tmp);
    if (st != io.STATUS_SUCCESS) return .{ .status = .io_error };
    const n = @min(buffer.len, tmp.len);
    @memcpy(buffer[0..n], tmp[0..n]);
    return .{ .status = .success, .bytes_read = n };
}

fn getProbeFsOps() vfs.FsOps {
    return .{
        .open = &nvmeProbeOpen,
        .close = &nvmeProbeClose,
        .read = &nvmeProbeRead,
    };
}

pub fn mountVfsProbeIfReady() void {
    if (!g_storage_ready) return;
    _ = vfs.mount("E:\\", .devfs, getProbeFsOps(), 0, "NVMe-LBA0");
    klog.info("VFS: NVMe probe mount E:\\ (partition-relative LBA0)", .{});
}

/// 复位控制器、建 Admin/IO 队列、Identify、读 LBA0、解析分区；供启动盘优先于 AHCI。
pub fn tryInitMvpBlockPath(max_bus: u8) void {
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;
    if (g_storage_ready) return;

    var buf: [4]NvmePciDev = undefined;
    const n = collectNvmePci(buf[0..], max_bus);
    if (n == 0) return;

    const dev = buf[0];
    const map_size = @max(dev.bar0_size, 0x4000);
    if (!vm.mapDeviceMmioIdentity(dev.bar0_phys, map_size)) {
        klog.warn("NVMe: mapDeviceMmioIdentity failed BAR0 phys=0x%x", .{dev.bar0_phys});
        return;
    }

    const bar: usize = @intCast(dev.bar0_phys);
    g_bar = bar;
    const cap = mmioR64(bar, REG_CAP);
    g_db_stride = capDoorbellStride(cap);
    klog.info("NVMe: CAP 0x%x:0x%x db_stride=%u", .{
        @as(u32, @truncate(cap >> 32)),
        @as(u32, @truncate(cap)),
        g_db_stride,
    });

    mmioW32(bar, REG_CC, 0);
    if (!waitCstsRdy(bar, false)) {
        klog.warn("NVMe: CC disable / CSTS.RDY clear timeout", .{});
        return;
    }

    const fa = frame.kernelFrameAllocatorPtr();
    const asq_p = fa.allocZeroed() orelse return;
    const acq_p = fa.allocZeroed() orelse return;
    const id_p = fa.allocZeroed() orelse return;
    const iosq_p = fa.allocZeroed() orelse return;
    const iocq_p = fa.allocZeroed() orelse return;
    const sec0_p = fa.allocZeroed() orelse return;

    @memset(@as([*]u8, @ptrFromInt(asq_p))[0 .. ADMIN_Q_DEPTH * 64], 0);
    @memset(@as([*]u8, @ptrFromInt(acq_p))[0 .. ADMIN_Q_DEPTH * 16], 0);
    @memset(@as([*]u8, @ptrFromInt(iosq_p))[0 .. IO_Q_DEPTH * 64], 0);
    @memset(@as([*]u8, @ptrFromInt(iocq_p))[0 .. IO_Q_DEPTH * 16], 0);

    g_asq_phys = asq_p;
    g_acq_phys = acq_p;
    g_iosq_phys = iosq_p;
    g_iocq_phys = iocq_p;

    g_admin_sq_tail = 0;
    g_admin_cq_head = 0;
    g_admin_cq_phase = 1;
    g_io_sq_tail = 0;
    g_io_cq_head = 0;
    g_io_cq_phase = 1;

    const aqa = ((ADMIN_Q_DEPTH - 1) << 16) | (ADMIN_Q_DEPTH - 1);
    mmioW32(bar, REG_AQA, aqa);
    mmioW64(bar, REG_ASQ, asq_p);
    mmioW64(bar, REG_ACQ, acq_p);

    const cc: u32 = CC_EN | CC_IOSQES | CC_IOCQES;
    mmioW32(bar, REG_CC, cc);
    if (!waitCstsRdy(bar, true)) {
        klog.warn("NVMe: CSTS.RDY timeout after CC.EN", .{});
        return;
    }

    if (!adminIdentify(bar, 1, 0, id_p)) {
        klog.warn("NVMe: Identify Controller failed", .{});
        return;
    }

    if (!adminIdentify(bar, 0, NSID_FIRST, id_p)) {
        klog.warn("NVMe: Identify Namespace %u failed", .{NSID_FIRST});
        return;
    }
    const id_slice = @as([*]align(4096) u8, @ptrFromInt(id_p))[0..4096];
    const id_ns: *const [4096]u8 = @ptrCast(id_slice.ptr);
    if (!namespaceLbads512(id_ns)) {
        klog.warn("NVMe: namespace LBA size is not 512 bytes (skip block path)", .{});
        return;
    }

    if (!adminCreateIoCq(bar, iocq_p)) {
        klog.warn("NVMe: Create I/O CQ failed", .{});
        return;
    }
    if (!adminCreateIoSq(bar, iosq_p)) {
        klog.warn("NVMe: Create I/O SQ failed", .{});
        return;
    }

    g_nsid = NSID_FIRST;
    if (!nvmeReadSector(bar, 0, sec0_p)) {
        klog.warn("NVMe: read LBA0 failed", .{});
        return;
    }
    @memcpy(&g_sector0, @as([*]const u8, @ptrFromInt(sec0_p))[0..512]);
    probePartitionStartLba(fa);

    g_storage_ready = true;
    klog.info("NVMe: LBA0 OK (sig@510=0x%x partition_base_LBA=0x{x})", .{
        std.mem.readInt(u16, g_sector0[510..512], .little),
        g_partition_start_lba,
    });
}

fn mmioW64(bar: usize, off: usize, phys: u64) void {
    mmioW32(bar, off, @truncate(phys));
    mmioW32(bar, off + 4, @truncate(phys >> 32));
}

/// 兼容旧调用点：若尚未 `tryInitMvpBlockPath`，仅映射并打印 CAP。
pub fn tryMapBar0AndLogCap(max_bus: u8) void {
    if (g_storage_ready) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;
    var buf: [4]NvmePciDev = undefined;
    const c = collectNvmePci(buf[0..], max_bus);
    if (c == 0) return;
    const e = buf[0];
    if (!vm.mapDeviceMmioIdentity(e.bar0_phys, @max(e.bar0_size, 0x1000))) {
        klog.warn("NVMe: BAR0 map failed phys=0x%x", .{e.bar0_phys});
        return;
    }
    const bar: usize = @intCast(e.bar0_phys);
    const cap_lo = mmioR32(bar, REG_CAP);
    const cap_hi = mmioR32(bar, REG_CAP + 4);
    klog.info("NVMe: BAR0 CAP 0x%x:0x%x (tryInitMvpBlockPath for full bring-up)", .{ cap_hi, cap_lo });
}
