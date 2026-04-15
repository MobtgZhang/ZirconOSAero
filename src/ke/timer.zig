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

//! Kernel Timer Module
//! Wraps architecture-specific timer hardware and provides kernel timing services

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const scheduler = @import("scheduler.zig");
const timekeeping = @import("../ke/timekeeping.zig");
const klog = @import("../rtl/klog.zig");

const TIMER_HZ: u32 = 100;

var timer_initialized: bool = false;

pub fn init() void {
    arch.initPic();
    arch.initTimer();
    arch.unmaskIrq(0);
    timekeeping.noteArchTimerInitialized();
    timer_initialized = true;
    switch (builtin.target.cpu.arch) {
        .x86_64 => klog.info("Timer: PIT at %uHz, PIC initialized", .{TIMER_HZ}),
        .loongarch64 => klog.info("Timer: LoongArch CSR timer ~%uHz, PCH+ECFG.IM", .{TIMER_HZ}),
        else => klog.info("Timer: arch tick ~%uHz (see arch.initTimer)", .{TIMER_HZ}),
    }
}

pub fn getTicks() u64 {
    return timekeeping.readInterruptTicks();
}

pub fn getSeconds() u64 {
    return scheduler.getTicks() / TIMER_HZ;
}

pub fn getHz() u32 {
    return TIMER_HZ;
}

pub fn isInitialized() bool {
    return timer_initialized;
}
