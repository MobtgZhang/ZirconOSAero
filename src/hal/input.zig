// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - HAL input abstraction
// Purpose: Hide platform-specific keyboard controller and port I/O behind
// one API so `drivers/input/` never imports architecture folders directly.

const builtin = @import("builtin");
const hal_root = @import("../hal.zig");

/// Port I/O stub for platforms without legacy PC I/O ports.
const portio_stub = struct {
    pub fn outb(_: u16, _: u8) void {}
    pub fn inb(_: u16) u8 {
        return 0;
    }
    pub fn ioWait() void {}
    pub fn outl(_: u16, _: u32) void {}
    pub fn inl(_: u16) u32 {
        return 0;
    }
};

/// Keyboard stub for platforms without a PS/2 keyboard controller.
const keyboard_stub = struct {
    pub fn handleScancodeByte(_: u8) void {}
};

/// Port I/O functions; no-op on non-PC platforms.
pub const portio = if (hal_root.hasLegacyPCDevices)
    @import("x86_64/portio.zig")
else
    portio_stub;

/// Keyboard scancode handler; no-op on non-PC platforms.
pub const keyboard = if (hal_root.hasLegacyPCDevices)
    @import("x86_64/keyboard.zig")
else
    keyboard_stub;

/// LoongArch keyboard implementation when available.
pub const keyboardLoongarch = keyboard_stub;

/// Whether the platform has a PS/2 keyboard controller (x86 or LoongArch).
pub const hasPS2KeyboardController = hal_root.hasPS2Keyboard;

/// Whether the platform has hardware PS/2 mouse polling.
pub const hasPS2MouseController = hal_root.hasPS2Mouse;

/// RTC CMOS access (PC platform only).
pub const rtcCmos = if (hal_root.hasLegacyPCDevices)
    @import("x86_64/rtc_cmos.zig")
else
    struct {
        pub const RtcTime = packed struct {
            second: u8,
            minute: u8,
            hour: u8,
            day: u8,
            month: u8,
            year: u8,
        };
        pub fn readTime() RtcTime {
            return RtcTime{ .second = 0, .minute = 0, .hour = 0, .day = 0, .month = 0, .year = 0 };
        }
        pub fn isInitialized() bool {
            return false;
        }
    };

/// PIT timer access (PC platform only).
pub const pit = if (hal_root.hasLegacyPCDevices)
    @import("x86_64/pit.zig")
else
    struct {
        pub const PIT_FREQ: u32 = 1193182;
        pub fn setHz(hz: u32) void {
            _ = hz;
        }
        pub fn getProgrammedHz() u32 {
            return 0;
        }
        pub fn init() void {}
    };
