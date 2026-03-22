//! PCI / PCIe configuration space access (NT6-style bus driver)
//! Uses x86 I/O ports 0xCF8/0xCFC (CONFIG_ADDRESS / CONFIG_DATA).
//! Analogous to Windows PCI bus driver + HAL Get/SetBusData for Type 1 host bridges.

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

pub const IOCTL_PCI_READ_CONFIG_DWORD: u32 = 0x00070000;
/// buffer_ptr layout: (bus:u8)<<24 | (dev:u8)<<19 | (func:u8)<<16 | (offset:u8) — offset dword-aligned

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

pub fn readConfigDword(bus: u8, dev: u8, func: u8, offset: u8) u32 {
    if (builtin.target.cpu.arch != .x86_64) return 0xFFFFFFFF;
    const aligned = offset & 0xFC;
    const addr: u32 = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, dev & 0x1F) << 11) |
        (@as(u32, func & 7) << 8) |
        aligned;
    portio.outl(PCI_CONFIG_ADDR, addr);
    return portio.inl(PCI_CONFIG_DATA);
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
    if (builtin.target.cpu.arch != .x86_64) return;

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
