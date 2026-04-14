//! PS/2 keyboard class driver (NT6: i8042prt / keyboard class)
//! IRP dispatch over the HAL ring buffer in `hal/x86_64/keyboard.zig` (IRQ1).

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const hal_kbd = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/keyboard.zig")
else if (builtin.target.cpu.arch == .loongarch64)
    @import("evdev_virtio_bridge.zig")
else
    struct {
        pub fn readChar() ?u8 {
            return null;
        }
        pub fn hasData() bool {
            return false;
        }
        pub fn injectSyntheticChar(_: u8) void {}
        pub fn handleIrq() void {}
    };

pub const IOCTL_KBD_READ_CHAR: u32 = 0x00080000;
pub const IOCTL_KBD_QUERY_DATA: u32 = 0x00080004;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn kbdDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_KBD_READ_CHAR => {
                    if (hal_kbd.readChar()) |ch| {
                        irp.buffer_ptr = ch;
                        irp.complete(io.STATUS_SUCCESS, 1);
                    } else {
                        irp.buffer_ptr = 0;
                        irp.complete(io.STATUS_END_OF_FILE, 0);
                    }
                    return io.STATUS_SUCCESS;
                },
                IOCTL_KBD_QUERY_DATA => {
                    irp.buffer_ptr = if (hal_kbd.hasData()) @as(u64, 1) else 0;
                    irp.complete(io.STATUS_SUCCESS, @sizeOf(u8));
                    return io.STATUS_SUCCESS;
                },
                else => {
                    irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
                    return io.STATUS_NOT_IMPLEMENTED;
                },
            }
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

pub fn init() void {
    if (builtin.target.cpu.arch != .x86_64 and builtin.target.cpu.arch != .loongarch64) return;

    driver_idx = io.registerDriver("\\Driver\\Kbdclass", kbdDispatch) orelse {
        klog.err("Kbdclass: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\KeyboardClass0", .keyboard, driver_idx) orelse {
        klog.err("Kbdclass: Failed to create device", .{});
        return;
    };
    driver_initialized = true;
    klog.info("Keyboard Driver: \\Device\\KeyboardClass0 (%s)", .{
        if (builtin.target.cpu.arch == .x86_64) "PS/2" else "VirtIO evdev",
    });
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn hasData() bool {
    return hal_kbd.hasData();
}

pub fn injectSyntheticChar(c: u8) void {
    hal_kbd.injectSyntheticChar(c);
}

pub fn handleIrq() void {
    hal_kbd.handleIrq();
}

pub fn readChar() ?u8 {
    return hal_kbd.readChar();
}

pub fn consumeTaskMgrHotkey() bool {
    return hal_kbd.consumeTaskMgrHotkey();
}

pub fn consumeWallpaperCycleHotkey() bool {
    return hal_kbd.consumeWallpaperCycleHotkey();
}

pub fn consumeFlip3dHotkey() bool {
    return hal_kbd.consumeFlip3dHotkey();
}

pub fn consumeFlip3dDismiss() bool {
    return hal_kbd.consumeFlip3dDismiss();
}

pub fn takeCursorNudge() @import("cursor_types.zig").CursorNudge {
    return hal_kbd.takeCursorNudge();
}
