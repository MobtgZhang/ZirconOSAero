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

/// 枚举总线 0 上所有 VirtIO Input PCI（1af4:1052），用于同时挂 mouse + keyboard
pub fn collectVirtioInputDevicesPci0(out: []PciLoc) usize {
    if (!supports_pci_config) return 0;
    var n: usize = 0;
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const id = readConfigDword(0, d, 0, 0);
        if (id == 0xFFFFFFFF) continue;
        const vid: u16 = @truncate(id);
        const did: u16 = @truncate(id >> 16);
        if (vid == 0x1AF4 and did == 0x1052) {
            if (n < out.len) {
                out[n] = .{ .bus = 0, .dev = d, .func = 0 };
                n += 1;
            }
        }
    }
    return n;
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
