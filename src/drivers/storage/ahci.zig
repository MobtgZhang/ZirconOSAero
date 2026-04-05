// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/ahci.zig
// Purpose: PCI 发现 SATA AHCI 控制器（class 0x01/0x06/0x01）、解析 ABAR（典型为 BAR5）；为 HBA 命令/DMA 与 VFS 卷挂载预留接线点。
//
// This is an independent clean-room implementation.
// Reference: Serial ATA AHCI 1.3.1 specification (ABAR memory register block); PCI class codes — PCI-SIG.
// Milestone: docs/cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md — 存储总线枚举。

const std = @import("std");
const builtin = @import("builtin");
const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const frame = @import("../../mm/frame.zig");
const io = @import("../../io/io.zig");
const block_common = @import("block_dev_common.zig");
const vfs = @import("../../fs/vfs.zig");

pub const AhciPciDev = struct {
    loc: pcie.PciLoc,
    vendor_id: u16,
    device_id: u16,
    /// AHCI 寄存器块物理基址（通常为 PCI BAR5 MMIO）。
    abar_phys: u64,
    abar_size: u64,
};

/// 选取 ABAR：优先 **BAR5** 非 I/O、非零且尺寸合理；否则首个满足条件的 MMIO BAR。
fn pickAbar(bars: [6]pcie.PciBarResource) ?pcie.PciBarResource {
    const b5 = bars[5];
    if (!b5.is_io and b5.base != 0 and b5.size >= 0x1000) return b5;
    for (bars) |bar| {
        if (!bar.is_io and bar.base != 0 and bar.size >= 0x1000) return bar;
    }
    return null;
}

/// 扫描 `0..max_bus`，收集 AHCI 控制器；每项启用 MEM+BusMaster 并解码 BAR。
pub fn collectAhciPci(out: []AhciPciDev, max_bus: u8) usize {
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
                if (pci_bind.lookupFromConfigClassWord(vid, did, cls) != .ahci) continue;

                pcie.enablePciMemAndBusMaster(b, d, f);
                const bars = pcie.decodePciBars(b, d, f);
                const abar = pickAbar(bars) orelse continue;
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = vid,
                        .device_id = did,
                        .abar_phys = abar.base,
                        .abar_size = abar.size,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

/// 启动路径诊断：发现即打一条串口日志（**不**映射 MMIO、**不**发命令）。
pub fn probeAndLog(max_bus: u8) void {
    var buf: [8]AhciPciDev = undefined;
    const c = collectAhciPci(buf[0..], max_bus);
    if (c == 0) {
        klog.info("AHCI: no PCI AHCI controller in bus 0..%u", .{max_bus});
        return;
    }
    var i: usize = 0;
    while (i < c) : (i += 1) {
        const e = buf[i];
        klog.info("AHCI: %u:%u.%u VID:DID=0x%x:0x%x ABAR phys=0x%x size=0x%x (VFS/DMA 后续里程碑)", .{
            e.loc.bus,
            e.loc.dev,
            e.loc.func,
            e.vendor_id,
            e.device_id,
            e.abar_phys,
            e.abar_size,
        });
    }
}

/// H2：在 `probeAndLog` 已发现控制器后登记 VFS/卷挂载意图（DMA/IDENTIFY 就绪后再接 `vfs.mount`）。
pub fn noteVfsVolumeIntentAfterProbe(max_bus: u8) void {
    var buf: [8]AhciPciDev = undefined;
    const c = collectAhciPci(buf[0..], max_bus);
    if (c == 0) return;
    klog.info("AHCI: VFS volume wiring (H2): %u controller(s) pending block ops + mount", .{c});
}

// ── H2a–H2c：ABAR MMIO、HBA 复位、端口命令表、IDENTIFY DEVICE、DMA 读单扇区 ──
// Ref: Serial ATA AHCI 1.3.1 — HBA registers, PxCMD, command list / FIS / PRDT（公开规范，clean-room 字段布局）。

const REG_GHC: usize = 0x04;
const REG_PI: usize = 0x0C;
const GHC_AE: u32 = 1 << 31;
const GHC_HR: u32 = 1 << 0;

/// PxSIG — Port x Signature (offset 0x24 in port register block).
/// Ref: Serial ATA AHCI 1.3.1 — initial device signature after power-on / COMRESET.
const REG_PXSIG: usize = 0x24;
/// PxSSTS — Port x Serial ATA Status (SStatus), lower dword of SStatus from link layer.
/// Bits 3:0 = DET (device detection); value 3 = device detected and PHY communication established.
/// Ref: Serial ATA AHCI 1.3.1 — table for PxSSTS / SATA phys link states.
const REG_PXSSTS: usize = 0x28;
/// PxTFD — Port x Task File Data (ATA status / error from last FIS update).
/// Ref: Serial ATA AHCI 1.3.1 — PxTFD layout; ATA status bit 7 = BSY.
const REG_PXTFD: usize = 0x20;
const PXSSTS_DET_MASK: u32 = 0x0F;
/// DET = 0: no device detected on this port (skip command submission).
const PXSSTS_DET_NONE: u32 = 0;
/// DET = 3: device detected and communication established (PxSIG may still read 0xFFFFFFFF until probed).
const PXSSTS_DET_PHY_UP: u32 = 3;
const ATA_STS_BSY: u32 = 0x80;

/// Upper bound for PxCI bit 0 clear polling (command completion).
const pxci_wait_max_iter: u32 = 800_000;
/// After ST/FRE, wait for task-file BSY clear before posting IDENTIFY / READ (vacant ports often never clear).
const tfd_not_busy_max_iter: u32 = 400_000;

fn portRegBase(port: u32) usize {
    return 0x100 + @as(usize, port) * 0x80;
}

fn hbaR(abar: usize, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(abar + off)).*;
}

fn hbaW(abar: usize, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(abar + off)).* = v;
}

fn portR(abar: usize, port: u32, off: usize) u32 {
    return hbaR(abar, portRegBase(port) + off);
}

fn portW(abar: usize, port: u32, off: usize, v: u32) void {
    hbaW(abar, portRegBase(port) + off, v);
}

fn portReadPxSig(abar: usize, port: u32) u32 {
    return portR(abar, port, REG_PXSIG);
}

fn portReadPxSsts(abar: usize, port: u32) u32 {
    return portR(abar, port, REG_PXSSTS);
}

/// Skip ports that clearly have no link / no device. When DET=3 but PxSIG is still 0 or 0xFFFFFFFF
/// (common on QEMU before full identify), we still attempt `runIdentifyDevice` — TFD + PxCI gate bad ports.
fn portSkipStorageProbe(abar: usize, port: u32) bool {
    const ssts = portReadPxSsts(abar, port);
    const det = ssts & PXSSTS_DET_MASK;
    if (det == PXSSTS_DET_NONE) return true;
    const sig = portReadPxSig(abar, port);
    if (det != PXSSTS_DET_PHY_UP and (sig == 0 or sig == 0xFFFF_FFFF)) return true;
    return false;
}

fn waitPortNotBusy(abar: usize, port: u32, max_iter: u32) bool {
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const tfd = portR(abar, port, REG_PXTFD);
        if ((tfd & ATA_STS_BSY) == 0) return true;
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return false;
}

var g_abar_va: usize = 0;
var g_active_port: u32 = 0;
var g_storage_ready: bool = false;
var g_identify_model: [40]u8 = [_]u8{0} ** 40;
var g_sector0: [512]u8 = [_]u8{0} ** 512;

fn hbaReset(abar: usize) bool {
    var v = hbaR(abar, REG_GHC);
    v |= GHC_HR;
    hbaW(abar, REG_GHC, v);
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        if ((hbaR(abar, REG_GHC) & GHC_HR) == 0) return true;
    }
    return false;
}

fn portStop(abar: usize, port: u32) void {
    var cmd = portR(abar, port, 0x18);
    cmd &= ~@as(u32, 1); // ST
    portW(abar, port, 0x18, cmd);
    var i: u32 = 0;
    while (i < 500_000) : (i += 1) {
        if ((portR(abar, port, 0x18) & (1 << 15)) == 0) break;
    }
    cmd = portR(abar, port, 0x18);
    cmd &= ~@as(u32, 1 << 4); // FRE
    portW(abar, port, 0x18, cmd);
    i = 0;
    while (i < 500_000) : (i += 1) {
        if ((portR(abar, port, 0x18) & (1 << 14)) == 0) break;
    }
}

fn portStart(abar: usize, port: u32, cl_phys: u64, fb_phys: u64) void {
    portW(abar, port, 0x00, @truncate(cl_phys));
    portW(abar, port, 0x04, @truncate(cl_phys >> 32));
    portW(abar, port, 0x08, @truncate(fb_phys));
    portW(abar, port, 0x0C, @truncate(fb_phys >> 32));
    var cmd = portR(abar, port, 0x18);
    cmd |= 1 << 4; // FRE
    portW(abar, port, 0x18, cmd);
    var i: u32 = 0;
    while (i < 500_000) : (i += 1) {
        if ((portR(abar, port, 0x18) & (1 << 14)) != 0) break;
    }
    cmd = portR(abar, port, 0x18);
    cmd |= 1; // ST
    portW(abar, port, 0x18, cmd);
    i = 0;
    while (i < 500_000) : (i += 1) {
        if ((portR(abar, port, 0x18) & (1 << 15)) != 0) break;
    }
}

fn waitPxCiClear(abar: usize, port: u32, max_iter: u32) bool {
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        if ((portR(abar, port, 0x38) & 1) == 0) return true;
        if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }
    return false;
}

/// 在已映射 ABAR 上执行 **IDENTIFY DEVICE**（命令 0xEC），将型号字（字 27–46）写入 `g_identify_model`（ATA 字序交换后 ASCII）。
fn runIdentifyDevice(abar: usize, port: u32, fa: *frame.FrameAllocator) bool {
    const cl_phys = fa.allocZeroed() orelse return false;
    const fb_phys = fa.allocZeroed() orelse return false;
    const ct_phys = fa.allocZeroed() orelse return false;
    const data_phys = fa.allocZeroed() orelse return false;
    defer {
        fa.free(cl_phys);
        fa.free(fb_phys);
        fa.free(ct_phys);
        fa.free(data_phys);
    }

    portStop(abar, port);
    portStart(abar, port, cl_phys, fb_phys);
    if (!waitPortNotBusy(abar, port, tfd_not_busy_max_iter)) {
        klog.debug("AHCI: port %u skip IDENTIFY (PxTFD.BSY timeout after ST/FRE)", .{port});
        portStop(abar, port);
        return false;
    }

    // Command list entry 0 @ cl_phys (1KiB-aligned page satisfies PxCLB).
    const cl: [*]volatile u32 = @ptrFromInt(cl_phys);
    const ct: [*]u8 = @ptrFromInt(ct_phys);
    @memset(ct[0..256], 0);
    // Register — Host to Device FIS (type 0x27).
    ct[0] = 0x27;
    ct[1] = 0x80; // C bit
    ct[2] = 0xEC; // IDENTIFY DEVICE
    // PRDT @ offset 0x80 in command table (128-byte aligned region).
    const prdt_off: usize = 0x80;
    const le_da = std.mem.nativeToLittle(u64, data_phys);
    @memcpy(ct[prdt_off .. prdt_off + 8], std.mem.asBytes(&le_da));
    @memset(ct[prdt_off + 8 .. prdt_off + 12], 0);
    const le_bc = std.mem.nativeToLittle(u32, (@as(u32, 511)) | (@as(u32, 1) << 31));
    @memcpy(ct[prdt_off + 12 .. prdt_off + 16], std.mem.asBytes(&le_bc));

    // Cmd header DW0: CFL=5 dwords, PRDTL=1；DW2–DW3 = CTBA（64 位，小端拆为两 dword）。
    cl[0] = 5 | (@as(u32, 1) << 16);
    cl[1] = 0;
    cl[2] = @truncate(ct_phys);
    cl[3] = @truncate(ct_phys >> 32);

    asm volatile ("" ::: .{ .memory = true });
    portW(abar, port, 0x10, 0xFFFF_FFFF);
    portW(abar, port, 0x38, 1);

    if (!waitPxCiClear(abar, port, pxci_wait_max_iter)) {
        klog.warn("AHCI: IDENTIFY timeout (PxCI)", .{});
        portStop(abar, port);
        return false;
    }

    const data = @as([*]u8, @ptrFromInt(data_phys));
    var m: usize = 0;
    var w: usize = 27;
    while (w <= 46 and m + 1 < g_identify_model.len) : (w += 1) {
        const o = w * 2;
        g_identify_model[m] = data[o + 1];
        g_identify_model[m + 1] = data[o];
        m += 2;
    }
    portStop(abar, port);
    return true;
}

fn runReadSector(abar: usize, port: u32, lba: u64, out_phys: u64, fa: *frame.FrameAllocator) bool {
    const cl_phys = fa.allocZeroed() orelse return false;
    const fb_phys = fa.allocZeroed() orelse return false;
    const ct_phys = fa.allocZeroed() orelse return false;
    defer {
        fa.free(cl_phys);
        fa.free(fb_phys);
        fa.free(ct_phys);
    }

    portStop(abar, port);
    portStart(abar, port, cl_phys, fb_phys);
    if (!waitPortNotBusy(abar, port, tfd_not_busy_max_iter)) {
        portStop(abar, port);
        return false;
    }

    const cl: [*]volatile u32 = @ptrFromInt(cl_phys);
    const ct: [*]u8 = @ptrFromInt(ct_phys);
    @memset(ct[0..256], 0);
    // READ SECTORS (0x20)，LBA28 单扇区。
    ct[0] = 0x27;
    ct[1] = 0x80;
    ct[2] = 0x20;
    ct[3] = 0;
    ct[4] = @truncate(lba);
    ct[5] = @truncate(lba >> 8);
    ct[6] = @truncate(lba >> 16);
    ct[7] = 0x40 | @as(u8, @truncate((lba >> 24) & 0x0F));
    ct[12] = 1; // sector count

    const prdt_off: usize = 0x80;
    const le_out = std.mem.nativeToLittle(u64, out_phys);
    @memcpy(ct[prdt_off .. prdt_off + 8], std.mem.asBytes(&le_out));
    @memset(ct[prdt_off + 8 .. prdt_off + 12], 0);
    const le_bc2 = std.mem.nativeToLittle(u32, (@as(u32, 511)) | (@as(u32, 1) << 31));
    @memcpy(ct[prdt_off + 12 .. prdt_off + 16], std.mem.asBytes(&le_bc2));

    cl[0] = 5 | (@as(u32, 1) << 16);
    cl[1] = 0;
    cl[2] = @truncate(ct_phys);
    cl[3] = @truncate(ct_phys >> 32);

    asm volatile ("" ::: .{ .memory = true });
    portW(abar, port, 0x10, 0xFFFF_FFFF);
    portW(abar, port, 0x38, 1);

    const ok = waitPxCiClear(abar, port, pxci_wait_max_iter);
    portStop(abar, port);
    return ok;
}

var g_ahci_blk_ctx: u8 = 0;

fn readBlocksImpl(ctx: *anyopaque, lba: u64, buf: []u8) io.NTSTATUS {
    _ = ctx;
    if (!g_storage_ready or buf.len < 512 or (buf.len % 512) != 0) return io.STATUS_INVALID_PARAMETER;
    const fa = frame.kernelFrameAllocatorPtr();
    const sectors = buf.len / 512;
    var s: u64 = 0;
    while (s < sectors) : (s += 1) {
        const slice = buf[s * 512 ..][0..512];
        const p = fa.allocZeroed() orelse return io.STATUS_INSUFFICIENT_RESOURCES;
        defer fa.free(p);
        if (!runReadSector(g_abar_va, g_active_port, lba + s, p, fa)) return io.STATUS_IO_DEVICE_ERROR;
        @memcpy(slice, @as([*]const u8, @ptrFromInt(p))[0..512]);
    }
    return io.STATUS_SUCCESS;
}

/// 供 NVMe/AHCI 共享的块读表（当前仅 AHCI 就绪时有效）。
pub fn blockDevVTableOrNull() ?block_common.BlockDevVTable {
    if (!g_storage_ready) return null;
    return .{
        .ctx = @ptrCast(&g_ahci_blk_ctx),
        .read_blocks = readBlocksImpl,
    };
}

pub fn storageReady() bool {
    return g_storage_ready;
}

/// 映射 ABAR、复位 HBA、对首个实现端口发 IDENTIFY 与 LBA0 读；成功则 `g_storage_ready=true`。
pub fn tryInitMmioDmaPath(max_bus: u8) void {
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;
    if (g_storage_ready) return;

    var buf: [4]AhciPciDev = undefined;
    const n = collectAhciPci(buf[0..], max_bus);
    if (n == 0) return;

    const dev = buf[0];
    if (!vm.mapDeviceMmioIdentity(dev.abar_phys, dev.abar_size)) {
        klog.warn("AHCI: mapDeviceMmioIdentity failed for ABAR 0x%x", .{dev.abar_phys});
        return;
    }

    const abar: usize = @intCast(dev.abar_phys);
    g_abar_va = abar;
    if (!hbaReset(abar)) {
        klog.warn("AHCI: HBA reset timeout", .{});
        return;
    }
    var ghc = hbaR(abar, REG_GHC);
    ghc |= GHC_AE;
    hbaW(abar, REG_GHC, ghc);

    const pi = hbaR(abar, REG_PI);
    var p: u32 = 0;
    while (p < 32) : (p += 1) {
        if ((pi & (std.math.shl(u32, 1, p))) == 0) continue;
        if (portSkipStorageProbe(abar, p)) {
            klog.debug("AHCI: port %u skip probe (SSTS=0x%x SIG=0x%x)", .{
                p,
                portReadPxSsts(abar, p),
                portReadPxSig(abar, p),
            });
            continue;
        }
        g_active_port = p;
        const fa = frame.kernelFrameAllocatorPtr();
        if (!runIdentifyDevice(abar, p, fa)) continue;

        var nz: usize = 0;
        for (g_identify_model) |ch| {
            if (ch != 0) nz += 1;
        }
        if (nz > 0) {
            klog.info("AHCI: port %u IDENTIFY model (ATA identify words 27-46)", .{p});
        } else {
            klog.info("AHCI: port %u IDENTIFY done (model empty)", .{p});
        }

        const sec_phys = fa.allocZeroed() orelse continue;
        defer fa.free(sec_phys);
        if (!runReadSector(abar, p, 0, sec_phys, fa)) {
            klog.warn("AHCI: read LBA0 failed on port %u", .{p});
            continue;
        }
        @memcpy(&g_sector0, @as([*]const u8, @ptrFromInt(sec_phys))[0..512]);
        g_storage_ready = true;
        klog.info("AHCI: DMA read LBA0 OK (boot sector word @510 0x%x)", .{
            std.mem.readInt(u16, g_sector0[510..512], .little),
        });
        return;
    }
    klog.warn("AHCI: no implemented port completed init", .{});
}

fn ahciProbeOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    _ = path;
    f.file_size = 512;
    f.fs_data = 1;
    return .success;
}

fn ahciProbeClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn ahciProbeRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (f.fs_data == 0) return .{ .status = .invalid_parameter };
    const n = @min(buffer.len, g_sector0.len);
    @memcpy(buffer[0..n], g_sector0[0..n]);
    return .{ .status = .success, .bytes_read = n };
}

fn getProbeFsOps() vfs.FsOps {
    return .{
        .open = &ahciProbeOpen,
        .close = &ahciProbeClose,
        .read = &ahciProbeRead,
    };
}

/// 在 `vfs.init()` 之后调用：若 DMA 路径就绪，挂载 `E:\\` 暴露扇区 0 只读（H2d 烟测）。
pub fn mountVfsProbeIfReady() void {
    if (!g_storage_ready) return;
    _ = vfs.mount("E:\\", .devfs, getProbeFsOps(), 0, "AHCI-LBA0");
    klog.info("VFS: AHCI probe mount E:\\ (512-byte LBA0 read)", .{});
}
