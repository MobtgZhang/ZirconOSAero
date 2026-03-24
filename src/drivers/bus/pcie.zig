//! PCI / PCIe configuration space access (NT6-style bus driver)
//! - x86_64: I/O ports 0xCF8/0xCFC (CONFIG_ADDRESS / CONFIG_DATA)
//! - loongarch64 QEMU virt: ECAM MMIO at 0x2000_0000（见 `pcie@20000000` DT）

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

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

pub const supports_pci_config: bool =
    builtin.target.cpu.arch == .x86_64 or builtin.target.cpu.arch == .loongarch64;

pub const IOCTL_PCI_READ_CONFIG_DWORD: u32 = 0x00070000;
/// buffer_ptr layout: (bus:u8)<<24 | (dev:u8)<<19 | (func:u8)<<16 | (offset:u8) — offset dword-aligned

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

pub fn readConfigDword(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    if (!supports_pci_config) return 0xFFFFFFFF;
    const aligned: u8 = offset & 0xFC;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const addr: u32 = 0x80000000 |
                (@as(u32, bus) << 16) |
                (@as(u32, dev & 0x1F) << 11) |
                (@as(u32, func & 7) << 8) |
                aligned;
            portio.outl(PCI_CONFIG_ADDR, addr);
            return portio.inl(PCI_CONFIG_DATA);
        },
        .loongarch64 => {
            const mmio = LOONGARCH_ECAM_BASE +
                (@as(u64, bus) << 20) +
                (@as(u64, dev & 0x1F) << 15) +
                (@as(u64, func & 7) << 12) +
                aligned;
            return @as(*volatile u32, @ptrFromInt(mmio)).*;
        },
        else => return 0xFFFFFFFF,
    }
}

pub fn writeConfigDword(bus: u8, dev: u8, func: u8, offset: u8, value: u32) void {
    if (!supports_pci_config) return;
    const aligned: u8 = offset & 0xFC;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const addr: u32 = 0x80000000 |
                (@as(u32, bus) << 16) |
                (@as(u32, dev & 0x1F) << 11) |
                (@as(u32, func & 7) << 8) |
                aligned;
            portio.outl(PCI_CONFIG_ADDR, addr);
            portio.outl(PCI_CONFIG_DATA, value);
        },
        .loongarch64 => {
            const mmio = LOONGARCH_ECAM_BASE +
                (@as(u64, bus) << 20) +
                (@as(u64, dev & 0x1F) << 15) +
                (@as(u64, func & 7) << 12) +
                aligned;
            @as(*volatile u32, @ptrFromInt(mmio)).* = value;
        },
        else => {},
    }
}

pub fn readConfigByte(bus: u8, dev: u8, func: u8, offset: u8) u8 {
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
