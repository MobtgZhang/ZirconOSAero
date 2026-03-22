//! Primary-channel ATA/IDE PIO driver (NT6: atapi / storport stack simplified)
//! Fixed primary legacy I/O: command block 0x1F0–0x1F7, control 0x3F6.

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn inb(_: u16) u8 {
            return 0;
        }
        pub fn outb(_: u16, _: u8) void {}
        pub fn inw(_: u16) u16 {
            return 0;
        }
    };

const ATA_DATA: u16 = 0x1F0;
const ATA_SECCNT: u16 = 0x1F2;
const ATA_LBA0: u16 = 0x1F3;
const ATA_LBA1: u16 = 0x1F4;
const ATA_LBA2: u16 = 0x1F5;
const ATA_DEVSEL: u16 = 0x1F6;
const ATA_STATUS: u16 = 0x1F7;
const ATA_CMD: u16 = 0x1F7;
const ATA_CTL: u16 = 0x3F6;

const CMD_IDENTIFY: u8 = 0xEC;

const STATUS_BSY: u8 = 0x80;
const STATUS_DRQ: u8 = 0x08;
const STATUS_ERR: u8 = 0x01;

pub const IOCTL_ATA_IDENTIFY: u32 = 0x000E0000;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
var present: bool = false;
var identify_word0: u16 = 0;

fn statusWait() bool {
    var i: u32 = 0;
    while (i < 500_000) : (i += 1) {
        const s = portio.inb(ATA_STATUS);
        if ((s & STATUS_BSY) == 0) return true;
    }
    return false;
}

fn selectMaster() void {
    portio.outb(ATA_DEVSEL, 0xA0);
}

pub fn tryIdentify() bool {
    if (builtin.target.cpu.arch != .x86_64) return false;
    selectMaster();
    if (!statusWait()) return false;

    portio.outb(ATA_SECCNT, 0);
    portio.outb(ATA_LBA0, 0);
    portio.outb(ATA_LBA1, 0);
    portio.outb(ATA_LBA2, 0);
    portio.outb(ATA_CMD, CMD_IDENTIFY);

    var i: u32 = 0;
    while (i < 500_000) : (i += 1) {
        const s = portio.inb(ATA_STATUS);
        if (s == 0) return false;
        if ((s & STATUS_ERR) != 0) return false;
        if ((s & STATUS_BSY) == 0) break;
    }

    const lba1 = portio.inb(ATA_LBA1);
    const lba2 = portio.inb(ATA_LBA2);
    if (lba1 != 0 or lba2 != 0) return false; // ATAPI — not handled

    if (!statusWait()) return false;
    const st = portio.inb(ATA_STATUS);
    if ((st & STATUS_DRQ) == 0) return false;

    identify_word0 = portio.inw(ATA_DATA);
    var w: usize = 1;
    while (w < 256) : (w += 1) {
        _ = portio.inw(ATA_DATA);
    }
    return true;
}

fn ataDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            if (irp.ioctl_code != IOCTL_ATA_IDENTIFY) {
                irp.complete(.not_implemented, 0);
                return .not_implemented;
            }
            irp.buffer_ptr = if (present) identify_word0 else 0;
            irp.complete(if (present) .success else .not_found, @sizeOf(u16));
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

    portio.outb(ATA_CTL, 0); // clear reset
    present = tryIdentify();

    driver_idx = io.registerDriver("\\Driver\\Ata", ataDispatch) orelse {
        klog.err("ATA: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\Harddisk0", .disk, driver_idx) orelse {
        klog.err("ATA: Failed to create device", .{});
        return;
    };
    driver_initialized = true;

    if (present) {
        klog.info("ATA Driver: \\Device\\Harddisk0 (primary master, identify[0]=0x%x)", .{identify_word0});
    } else {
        klog.info("ATA Driver: \\Device\\Harddisk0 (no primary ATA device)", .{});
    }
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn isPresent() bool {
    return present;
}
