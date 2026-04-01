//! PCI / PCIe configuration space access (NT6-style bus driver)
//! - x86_64: I/O ports 0xCF8/0xCFC (CONFIG_ADDRESS / CONFIG_DATA)
//! - loongarch64 QEMU virt: ECAM MMIO at 0x2000_0000（见 `pcie@20000000` DT）
//! - aarch64 QEMU virt: 低 ECAM 在 0x3f00_0000（Makefile 使用 `highmem-ecam=off` 与 EDK2 固件一致）
//! - riscv64 QEMU virt: ECAM 在 0x3000_0000（`pci@30000000`）

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");

const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn outl(_: u16, _: u32) void {}
        pub fn inl(_: u16) u32 {
            return 0;
        }
    };

const PCI_CONFIG_ADDR: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

/// QEMU `loongarch64` virt：`pci-host-ecam-generic` 配置空间窗口
const LOONGARCH_ECAM_BASE: u64 = 0x2000_0000;
/// 与 aarch64 一致取 16MiB：足够枚举总线 0；内核 identity 映射止于 512MiB，ECAM 起点恰在边界上须单独映射
const LOONGARCH_ECAM_SIZE: u64 = 0x0100_0000;
/// QEMU `aarch64` virt，低 ECAM（`highmem-ecam=off`）
const AARCH64_ECAM_BASE: u64 = 0x3f00_0000;
const AARCH64_ECAM_SIZE: u64 = 0x0100_0000;
/// QEMU `riscv64` virt
const RISCV64_ECAM_BASE: u64 = 0x3000_0000;
const RISCV64_ECAM_SIZE: u64 = 0x1000_0000;

pub const supports_pci_config: bool = builtin.target.cpu.arch == .x86_64 or
    builtin.target.cpu.arch == .loongarch64 or
    builtin.target.cpu.arch == .aarch64 or
    builtin.target.cpu.arch == .riscv64;

pub const IOCTL_PCI_READ_CONFIG_DWORD: u32 = 0x00070000;
/// buffer_ptr layout: (bus:u8)<<24 | (dev:u8)<<19 | (func:u8)<<16 | (offset:u8) — offset dword-aligned
var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

pub fn readConfigDword(bus: u8, dev: u8, func: u8, offset: u16) u32 {
    if (!supports_pci_config) return 0xFFFFFFFF;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            // I/O CF8/CFC：仅保证 256B 传统配置空间
            const off = @min(offset, 0xFF);
            const aligned: u8 = @truncate(off & 0xFC);
            const addr: u32 = 0x80000000 |
                (@as(u32, bus) << 16) |
                (@as(u32, dev & 0x1F) << 11) |
                (@as(u32, func & 7) << 8) |
                aligned;
            portio.outl(PCI_CONFIG_ADDR, addr);
            return portio.inl(PCI_CONFIG_DATA);
        },
        .loongarch64, .aarch64, .riscv64 => {
            // PCIe ECAM：每功能 4KiB 配置空间，偏移须用 12 位（勿截成 u8）
            const aligned = offset & 0xFFF & ~@as(u16, 3);
            const mmio = switch (builtin.target.cpu.arch) {
                .loongarch64 => LOONGARCH_ECAM_BASE,
                .aarch64 => AARCH64_ECAM_BASE,
                .riscv64 => RISCV64_ECAM_BASE,
                else => unreachable,
            } +
                (@as(u64, bus) << 20) +
                (@as(u64, dev & 0x1F) << 15) +
                (@as(u64, func & 7) << 12) +
                @as(u64, aligned);
            return @as(*volatile u32, @ptrFromInt(mmio)).*;
        },
        else => return 0xFFFFFFFF,
    }
}

pub fn writeConfigDword(bus: u8, dev: u8, func: u8, offset: u16, value: u32) void {
    if (!supports_pci_config) return;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const off = @min(offset, 0xFF);
            const aligned: u8 = @truncate(off & 0xFC);
            const addr: u32 = 0x80000000 |
                (@as(u32, bus) << 16) |
                (@as(u32, dev & 0x1F) << 11) |
                (@as(u32, func & 7) << 8) |
                aligned;
            portio.outl(PCI_CONFIG_ADDR, addr);
            portio.outl(PCI_CONFIG_DATA, value);
        },
        .loongarch64, .aarch64, .riscv64 => {
            const aligned = offset & 0xFFF & ~@as(u16, 3);
            const mmio = switch (builtin.target.cpu.arch) {
                .loongarch64 => LOONGARCH_ECAM_BASE,
                .aarch64 => AARCH64_ECAM_BASE,
                .riscv64 => RISCV64_ECAM_BASE,
                else => unreachable,
            } +
                (@as(u64, bus) << 20) +
                (@as(u64, dev & 0x1F) << 15) +
                (@as(u64, func & 7) << 12) +
                @as(u64, aligned);
            @as(*volatile u32, @ptrFromInt(mmio)).* = value;
        },
        else => {},
    }
}

pub fn readConfigByte(bus: u8, dev: u8, func: u8, offset: u16) u8 {
    const dw = readConfigDword(bus, dev, func, offset);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dw >> shift);
}

pub fn readConfigWord(bus: u8, dev: u8, func: u8, offset: u16) u16 {
    const aligned = offset & ~@as(u16, 1);
    const dw = readConfigDword(bus, dev, func, aligned);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dw >> shift);
}

pub fn writeConfigWord(bus: u8, dev: u8, func: u8, offset: u16, value: u16) void {
    const aligned = offset & ~@as(u16, 1);
    var dw = readConfigDword(bus, dev, func, aligned);
    if ((offset & 2) != 0) {
        dw = (dw & 0xFFFF) | (@as(u32, value) << 16);
    } else {
        dw = (dw & 0xFFFF0000) | value;
    }
    writeConfigDword(bus, dev, func, aligned, dw);
}

/// Intel PCI vendor id
pub const PCI_VENDOR_INTEL: u16 = 0x8086;
/// AMD / ATI PCI vendor id
pub const PCI_VENDOR_AMD_ATI: u16 = 0x1002;
/// Loongson PCI vendor id (display class 0x03 on LS2K/7A 等，见 `video/loongson/dids.zig`)
pub const PCI_VENDOR_LOONGSON: u16 = 0x0014;
/// NVIDIA PCI vendor id（显示类 0x03；与 Linux `nouveau` 枚举范围一致，本内核默认 GOP handoff）
pub const PCI_VENDOR_NVIDIA: u16 = 0x10DE;

/// Decoded PCI BAR (memory or I/O)
pub const PciBarResource = struct {
    base: u64 = 0,
    size: u64 = 0,
    is_io: bool = false,
    is_64: bool = false,
    prefetchable: bool = false,
};

/// 显示控制器（class 0x03xx）在 PCI 上的快照 — Intel / AMD 共用
pub const DisplayGfxPciInfo = struct {
    loc: PciLoc,
    vendor_id: u16,
    device_id: u16,
    revision_id: u8,
    /// 配置空间 0x08 处的 class/rev 双字（字节序：rev, prog_if, subclass, class）
    class_code: u32,
    bars: [6]PciBarResource,
};

/// 与 `DisplayGfxPciInfo` 相同（历史命名）
pub const IntelGfxPciInfo = DisplayGfxPciInfo;

fn probeOneBar(bus: u8, dev: u8, func: u8, idx: u8) struct { bar: PciBarResource, consumed: u32 } {
    const off: u16 = 0x10 + @as(u16, idx) * 4;
    const lo = readConfigDword(bus, dev, func, off);
    if (lo == 0)
        return .{ .bar = .{}, .consumed = 1 };

    if ((lo & 1) != 0) {
        writeConfigDword(bus, dev, func, off, 0xFFFFFFFF);
        const inv = readConfigDword(bus, dev, func, off);
        writeConfigDword(bus, dev, func, off, lo);
        const sz = (~(inv & 0xFFFFFFFC) +% 1) & 0xFFFF;
        return .{
            .bar = .{
                .base = @as(u64, lo & 0xFFFFFFFC),
                .size = sz,
                .is_io = true,
            },
            .consumed = 1,
        };
    }

    const is_64 = (lo & 0x6) == 0x4;
    const prefetch = (lo & 8) != 0;
    const hi_orig: u32 = if (is_64) readConfigDword(bus, dev, func, off + 4) else 0;

    writeConfigDword(bus, dev, func, off, 0xFFFFFFFF);
    const sz_lo = readConfigDword(bus, dev, func, off) & 0xFFFFFFF0;
    var sz_hi: u32 = 0;
    if (is_64) {
        writeConfigDword(bus, dev, func, off + 4, 0xFFFFFFFF);
        sz_hi = readConfigDword(bus, dev, func, off + 4);
        writeConfigDword(bus, dev, func, off + 4, hi_orig);
    }
    writeConfigDword(bus, dev, func, off, lo);

    const size: u64 = if (!is_64) blk: {
        if (sz_lo == 0) break :blk 0;
        break :blk (~@as(u64, sz_lo) +% 1) & 0xFFFFFFFF;
    } else blk: {
        const combined: u64 = (@as(u64, sz_hi) << 32) | @as(u64, sz_lo);
        if (combined == 0) break :blk 0;
        break :blk ~combined +% 1;
    };

    const base: u64 = (@as(u64, hi_orig) << 32) | @as(u64, lo & 0xFFFFFFF0);

    return .{
        .bar = .{
            .base = base,
            .size = size,
            .is_64 = is_64,
            .prefetchable = prefetch,
        },
        .consumed = if (is_64) 2 else 1,
    };
}

/// 解析 6 个 BAR 槽位（64-bit BAR 占连续两项）
pub fn decodePciBars(bus: u8, dev: u8, func: u8) [6]PciBarResource {
    var bars: [6]PciBarResource = [_]PciBarResource{.{}} ** 6;
    var i: u32 = 0;
    while (i < 6) {
        const r = probeOneBar(bus, dev, func, @intCast(i));
        bars[i] = r.bar;
        i += r.consumed;
    }
    return bars;
}

/// 置位 MEM Space + Bus Master（访问 MMIO / DMA 所需）
pub fn enablePciMemAndBusMaster(bus: u8, dev: u8, func: u8) void {
    if (!supports_pci_config) return;
    const cmd = readConfigWord(bus, dev, func, 0x04);
    const new = cmd | 0x0006;
    if (new != cmd) writeConfigWord(bus, dev, func, 0x04, new);
}

/// 基类 Display Controller（0x03），含 VGA、XGA、3D 等子类
fn isPciDisplayClass(class_dword: u32) bool {
    return @as(u8, @truncate(class_dword >> 24)) == 0x03;
}

/// 扫描 PCI（默认前 `max_bus` 条总线），收集指定厂商的显示控制器（class 0x03）
pub fn collectDisplayDevicesByVendor(vendor: u16, out: []DisplayGfxPciInfo, max_bus: u8) usize {
    if (!supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const vid: u16 = @truncate(id);
                if (vid != vendor) continue;
                const cls = readConfigDword(b, d, f, 0x08);
                if (!isPciDisplayClass(cls)) continue;

                enablePciMemAndBusMaster(b, d, f);
                const bars = decodePciBars(b, d, f);
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = vid,
                        .device_id = @truncate(id >> 16),
                        .revision_id = readConfigByte(b, d, f, 0x08),
                        .class_code = cls,
                        .bars = bars,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

/// 扫描 PCI，收集 Intel（8086）显示控制器
pub fn collectIntelDisplayDevices(out: []IntelGfxPciInfo, max_bus: u8) usize {
    return collectDisplayDevicesByVendor(PCI_VENDOR_INTEL, out, max_bus);
}

/// 扫描 PCI，收集 AMD/ATI（1002）显示控制器
pub fn collectAmdDisplayDevices(out: []DisplayGfxPciInfo, max_bus: u8) usize {
    return collectDisplayDevicesByVendor(PCI_VENDOR_AMD_ATI, out, max_bus);
}

fn isPciMassStorageClass(class_dword: u32) bool {
    return @as(u8, @truncate(class_dword >> 24)) == 0x01;
}

/// 统计 PCI class **0x01**（大容量存储控制器）的在位功能数，供块设备驱动发现与串口诊断（AHCI/NVMe/VirtIO-blk 等接线点）。
pub fn countMassStorageFunctions(max_bus: u8) usize {
    if (!supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const cls = readConfigDword(b, d, f, 0x08);
                if (isPciMassStorageClass(cls)) n += 1;
            }
        }
    }
    return n;
}

/// 扫描 PCI，收集龙芯（0014）显示控制器（class 0x03）
pub fn collectLoongsonDisplayDevices(out: []DisplayGfxPciInfo, max_bus: u8) usize {
    return collectDisplayDevicesByVendor(PCI_VENDOR_LOONGSON, out, max_bus);
}

/// 扫描 PCI，收集 NVIDIA（10DE）显示控制器（class 0x03）
pub fn collectNvidiaDisplayDevices(out: []DisplayGfxPciInfo, max_bus: u8) usize {
    return collectDisplayDevicesByVendor(PCI_VENDOR_NVIDIA, out, max_bus);
}

/// 选取首个非零 MMIO BAR（通常为寄存器块）
pub fn firstMmioBar(info: *const DisplayGfxPciInfo) ?PciBarResource {
    for (info.bars) |bar| {
        if (!bar.is_io and bar.size > 0 and bar.base != 0) return bar;
    }
    return null;
}

/// PCI base class Serial Bus Controller（0x0C）下的 USB 主机控制器种类
pub const UsbHostKind = enum(u8) {
    uhci = 0, // prog_if 0x00
    ohci = 1, // 0x10
    ehci = 2, // 0x20
    xhci = 3, // 0x30
    unknown = 0xFF,
};

/// USB 主机控制器在 PCI 上的快照（class 0x0C03 + prog_if）
pub const UsbHostPciInfo = struct {
    loc: PciLoc,
    vendor_id: u16,
    device_id: u16,
    revision_id: u8,
    /// 配置空间 0x08：rev, prog_if, subclass, class（小端双字）
    class_code: u32,
    kind: UsbHostKind,
    bars: [6]PciBarResource,
};

fn usbKindFromClass(class_dword: u32) ?UsbHostKind {
    const cls: u8 = @truncate(class_dword >> 24);
    const sub: u8 = @truncate((class_dword >> 16) & 0xFF);
    const pif: u8 = @truncate((class_dword >> 8) & 0xFF);
    if (cls != 0x0C or sub != 0x03) return null;
    return switch (pif) {
        0x00 => .uhci,
        0x10 => .ohci,
        0x20 => .ehci,
        0x30 => .xhci,
        else => .unknown,
    };
}

/// 扫描 PCI（0..max_bus），收集 USB 主机控制器（class 0x0C03）
pub fn collectUsbHostControllers(out: []UsbHostPciInfo, max_bus: u8) usize {
    if (!supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const cls = readConfigDword(b, d, f, 0x08);
                const kind = usbKindFromClass(cls) orelse continue;

                enablePciMemAndBusMaster(b, d, f);
                const bars = decodePciBars(b, d, f);
                if (n < out.len) {
                    out[n] = .{
                        .loc = .{ .bus = b, .dev = d, .func = f },
                        .vendor_id = @truncate(id),
                        .device_id = @truncate(id >> 16),
                        .revision_id = readConfigByte(b, d, f, 0x08),
                        .class_code = cls,
                        .kind = kind,
                        .bars = bars,
                    };
                    n += 1;
                }
            }
        }
    }
    return n;
}

pub fn firstMmioBarUsb(info: *const UsbHostPciInfo) ?PciBarResource {
    for (info.bars) |bar| {
        if (!bar.is_io and bar.size > 0 and bar.base != 0) return bar;
    }
    return null;
}

pub const PciLoc = struct {
    bus: u8,
    dev: u8,
    func: u8,
};

/// 在总线 0 上查找给定厂商与设备 ID（用于 VirtIO 等）
pub fn findDevicePci0(vendor_id: u16, device_ids: []const u16) ?PciLoc {
    if (!supports_pci_config) return null;
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const id = readConfigDword(0, d, 0, 0);
        if (id == 0xFFFFFFFF) continue;
        const vid: u16 = @truncate(id);
        const did: u16 = @truncate(id >> 16);
        if (vid != vendor_id) continue;
        for (device_ids) |want| {
            if (did == want) return .{ .bus = 0, .dev = d, .func = 0 };
        }
    }
    return null;
}

/// 枚举 `bus 0..max_bus` 上所有 VirtIO Input PCI（1af4:1052）；LoongArch/RISC-V 等下设备偶发不在 bus0。
/// 扫描 func 0..7：多功能设备或部分固件下 virtio 不在 func0。
pub fn collectVirtioInputDevices(out: []PciLoc, max_bus: u8) usize {
    if (!supports_pci_config) return 0;
    var n: usize = 0;
    var b: u8 = 0;
    while (b <= max_bus) : (b += 1) {
        var d: u8 = 0;
        while (d < 32) : (d += 1) {
            var f: u8 = 0;
            while (f < 8) : (f += 1) {
                const id = readConfigDword(b, d, f, 0);
                if (id == 0xFFFFFFFF) continue;
                const vid: u16 = @truncate(id);
                const did: u16 = @truncate(id >> 16);
                if (vid == 0x1AF4 and did == 0x1052) {
                    if (n < out.len) {
                        out[n] = .{ .bus = b, .dev = d, .func = f };
                        n += 1;
                    }
                }
            }
        }
    }
    return n;
}

/// 仅总线 0（x86 QEMU pc 常用；保持旧调用点行为）。
pub fn collectVirtioInputDevicesPci0(out: []PciLoc) usize {
    return collectVirtioInputDevices(out, 0);
}

fn pciDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            if (irp.ioctl_code != IOCTL_PCI_READ_CONFIG_DWORD) {
                irp.complete(.not_implemented, 0);
                return .not_implemented;
            }
            const packed_req: u32 = @truncate(irp.buffer_ptr);
            const bus: u8 = @truncate(packed_req >> 24);
            const dev: u8 = @truncate((packed_req >> 19) & 0x1F);
            const func: u8 = @truncate((packed_req >> 16) & 7);
            const off: u8 = @truncate(packed_req & 0xFF);
            const val = readConfigDword(bus, dev, func, off);
            irp.buffer_ptr = val;
            irp.complete(.success, @sizeOf(u32));
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

pub fn init() void {
    if (!supports_pci_config) return;

    switch (builtin.target.cpu.arch) {
        .aarch64 => _ = vm.mapDeviceMmioIdentity(AARCH64_ECAM_BASE, AARCH64_ECAM_SIZE),
        .riscv64 => _ = vm.mapDeviceMmioIdentity(RISCV64_ECAM_BASE, RISCV64_ECAM_SIZE),
        .loongarch64 => _ = vm.mapDeviceMmioIdentity(LOONGARCH_ECAM_BASE, LOONGARCH_ECAM_SIZE),
        else => {},
    }

    driver_idx = io.registerDriver("\\Driver\\Pci", pciDispatch) orelse {
        klog.err("PCI: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\PCI0", .pci_bus, driver_idx) orelse {
        klog.err("PCI: Failed to create device", .{});
        return;
    };
    driver_initialized = true;

    const id = readConfigDword(0, 0, 0, 0);
    klog.info("PCI Bus Driver: \\Device\\PCI0 (host bridge VID:DID=0x%x)", .{id});
}

pub fn isInitialized() bool {
    return driver_initialized;
}
