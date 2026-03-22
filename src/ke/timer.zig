//! Kernel Timer Module
//! Wraps architecture-specific timer hardware and provides kernel timing services

const arch = @import("../arch.zig");
const scheduler = @import("scheduler.zig");
const klog = @import("../rtl/klog.zig");

const TIMER_HZ: u32 = 100;

var timer_initialized: bool = false;

pub fn init() void {
    arch.initPic();
    arch.initTimer();
    arch.unmaskIrq(0);
    timer_initialized = true;
    klog.info("Timer: PIT at %uHz, PIC initialized", .{TIMER_HZ});
}

pub fn getTicks() u64 {
    return scheduler.getTicks();
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
