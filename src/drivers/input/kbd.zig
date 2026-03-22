//! PS/2 keyboard class driver (NT6: i8042prt / keyboard class)
//! IRP dispatch over the HAL ring buffer in `hal/x86_64/keyboard.zig` (IRQ1).

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const hal_kbd = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/keyboard.zig")
else
    struct {
        pub fn readChar() ?u8 {
            return null;
        }
        pub fn hasData() bool {
            return false;
        }
    };

pub const IOCTL_KBD_READ_CHAR: u32 = 0x00080000;
pub const IOCTL_KBD_QUERY_DATA: u32 = 0x00080004;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn kbdDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_KBD_READ_CHAR => {
                    if (hal_kbd.readChar()) |ch| {
                        irp.buffer_ptr = ch;
                        irp.complete(.success, 1);
                    } else {
                        irp.buffer_ptr = 0;
                        irp.complete(.end_of_file, 0);
                    }
                    return .success;
                },
                IOCTL_KBD_QUERY_DATA => {
                    irp.buffer_ptr = if (hal_kbd.hasData()) @as(u64, 1) else 0;
                    irp.complete(.success, @sizeOf(u8));
                    return .success;
                },
                else => {
                    irp.complete(.not_implemented, 0);
                    return .not_implemented;
                },
            }
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

pub fn init() void {
    if (builtin.target.cpu.arch != .x86_64) return;

    driver_idx = io.registerDriver("\\Driver\\Kbdclass", kbdDispatch) orelse {
        klog.err("Kbdclass: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\KeyboardClass0", .keyboard, driver_idx) orelse {
        klog.err("Kbdclass: Failed to create device", .{});
        return;
    };
    driver_initialized = true;
    klog.info("Keyboard Driver: \\Device\\KeyboardClass0 (PS/2)", .{});
}

pub fn isInitialized() bool {
    return driver_initialized;
}
