//! MC146818-compatible RTC / CMOS driver (NT6: \Device\Rtc, interrupt-time profile)
//! BCD time read; no periodic interrupt handling here (scheduler uses PIT).

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
    };

const CMOS_INDEX: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

const REG_SECONDS: u8 = 0x00;
const REG_MINUTES: u8 = 0x02;
const REG_HOURS: u8 = 0x04;
const REG_DAY: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;

pub const RtcTime = packed struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8, // 0–99
};

pub const IOCTL_RTC_GET_TIME: u32 = 0x000D0000;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn bcdToBin(bcd: u8) u8 {
    return (bcd >> 4) * 10 + (bcd & 0x0F);
}

fn cmosRead(reg: u8) u8 {
    portio.outb(CMOS_INDEX, reg);
    return portio.inb(CMOS_DATA);
}

/// Waits until RTC update not in progress (UIP, status A bit 7).
fn waitReady() void {
    var spins: u32 = 0;
    while (spins < 1_000_000) : (spins += 1) {
        portio.outb(CMOS_INDEX, REG_STATUS_A);
        const a = portio.inb(CMOS_DATA);
        if (a & 0x80 == 0) return;
    }
}

pub fn readTime() RtcTime {
    waitReady();
    return .{
        .second = bcdToBin(cmosRead(REG_SECONDS)),
        .minute = bcdToBin(cmosRead(REG_MINUTES)),
        .hour = bcdToBin(cmosRead(REG_HOURS) & 0x7F),
        .day = bcdToBin(cmosRead(REG_DAY)),
        .month = bcdToBin(cmosRead(REG_MONTH)),
        .year = bcdToBin(cmosRead(REG_YEAR)),
    };
}

fn rtcDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            if (irp.ioctl_code != IOCTL_RTC_GET_TIME) {
                irp.complete(.not_implemented, 0);
                return .not_implemented;
            }
            const t = readTime();
            const packed_time: u64 = @as(u64, t.second) |
                (@as(u64, t.minute) << 8) |
                (@as(u64, t.hour) << 16) |
                (@as(u64, t.day) << 24) |
                (@as(u64, t.month) << 32) |
                (@as(u64, t.year) << 40);
            irp.buffer_ptr = packed_time;
            irp.complete(.success, @sizeOf(RtcTime));
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

    driver_idx = io.registerDriver("\\Driver\\Rtc", rtcDispatch) orelse {
        klog.err("RTC: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\Rtc0", .rtc_clock, driver_idx) orelse {
        klog.err("RTC: Failed to create device", .{});
        return;
    };
    driver_initialized = true;

    const t = readTime();
    klog.info("RTC Driver: \\Device\\Rtc0 (CMOS %02u:%02u:%02u)", .{ t.hour, t.minute, t.second });
}

pub fn isInitialized() bool {
    return driver_initialized;
}
