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

//! MC146818-compatible RTC / CMOS driver (NT6: \Device\Rtc, interrupt-time profile)
//! BCD time read; no periodic interrupt handling here (scheduler uses PIT).

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const rtc_cmos = @import("../../hal/x86_64/rtc_cmos.zig");

pub const RtcTime = rtc_cmos.RtcTime;

pub const IOCTL_RTC_GET_TIME: u32 = 0x000D0000;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

pub fn readTime() RtcTime {
    return rtc_cmos.readTime();
}

fn rtcDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => {
            if (irp.ioctl_code != IOCTL_RTC_GET_TIME) {
                irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
                return io.STATUS_NOT_IMPLEMENTED;
            }
            const t = readTime();
            const packed_time: u64 = @as(u64, t.second) |
                (@as(u64, t.minute) << 8) |
                (@as(u64, t.hour) << 16) |
                (@as(u64, t.day) << 24) |
                (@as(u64, t.month) << 32) |
                (@as(u64, t.year) << 40);
            irp.buffer_ptr = packed_time;
            irp.complete(io.STATUS_SUCCESS, @sizeOf(RtcTime));
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
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
