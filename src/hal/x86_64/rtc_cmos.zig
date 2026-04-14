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
// Module: src/hal/x86_64/rtc_cmos.zig
// Purpose: MC146818 CMOS/RTC 时间读取（无日志、无 I/O 管理器依赖），供 klog 与 \Device\Rtc 复用。
//
// This is an independent clean-room implementation.
// Reference: Intel PC/AT CMOS; OSDev Wiki "RTC"

const builtin = @import("builtin");

const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("portio.zig")
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

/// 与 `drivers/timer/rtc.zig` 的 `RtcTime` 布局一致：`year` 为 0–99（2000+year）。
pub const RtcTime = packed struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
};

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
