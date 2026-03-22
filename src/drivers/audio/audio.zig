//! ZirconOS Audio Subsystem (placeholder)
//! Provides an event-based sound interface so that the kernel can
//! request sounds (startup, shutdown, error, notification, etc.)
//! even before a real audio driver is present.
//!
//! When a hardware audio driver (AC97 / HD Audio / USB Audio) is
//! loaded in the future, it registers itself and drains the pending
//! event queue.

const klog = @import("../../rtl/klog.zig");

pub const SoundEvent = enum(u8) {
    startup = 0,
    shutdown = 1,
    logon = 2,
    logoff = 3,
    error_critical = 4,
    error_minor = 5,
    notification = 6,
    question = 7,
    menu_open = 8,
    menu_close = 9,
    click = 10,
    recycle_bin_empty = 11,
};

const MAX_PENDING: usize = 16;
var pending_events: [MAX_PENDING]SoundEvent = [_]SoundEvent{.startup} ** MAX_PENDING;
var pending_count: usize = 0;

var hw_present: bool = false;
var initialized: bool = false;
var total_events: u64 = 0;

pub fn init() void {
    hw_present = false;
    initialized = true;

    klog.info("Audio: Subsystem initialized (hardware=none, events queued)", .{});
}

pub fn playEvent(event: SoundEvent) void {
    total_events += 1;

    if (hw_present) {
        dispatchToHardware(event);
        return;
    }

    if (pending_count < MAX_PENDING) {
        pending_events[pending_count] = event;
        pending_count += 1;
    }

    klog.info("Audio: Event queued: %s (total=%u, pending=%u)", .{
        eventName(event), total_events, pending_count,
    });
}

pub fn registerHardware() void {
    hw_present = true;
    klog.info("Audio: Hardware driver registered, flushing %u pending events", .{pending_count});

    var idx: usize = 0;
    while (idx < pending_count) : (idx += 1) {
        dispatchToHardware(pending_events[idx]);
    }
    pending_count = 0;
}

fn dispatchToHardware(event: SoundEvent) void {
    const ac97 = @import("ac97.zig");
    if (ac97.isInitialized() and !ac97.isMuted()) {
        _ = event;
    }
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn isHardwarePresent() bool {
    return hw_present;
}

pub fn getTotalEvents() u64 {
    return total_events;
}

pub fn getPendingCount() usize {
    return pending_count;
}

fn eventName(event: SoundEvent) []const u8 {
    return switch (event) {
        .startup => "Startup",
        .shutdown => "Shutdown",
        .logon => "Logon",
        .logoff => "Logoff",
        .error_critical => "Critical Error",
        .error_minor => "Minor Error",
        .notification => "Notification",
        .question => "Question",
        .menu_open => "Menu Open",
        .menu_close => "Menu Close",
        .click => "Click",
        .recycle_bin_empty => "Recycle Bin Empty",
    };
}
