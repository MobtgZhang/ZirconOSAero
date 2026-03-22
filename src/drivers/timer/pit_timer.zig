//! 8254 PIT kernel-mode driver (NT6 HAL timer / profile source)
//! Exposes the programmed tick rate. Actual hardware is owned by `hal/x86_64/pit.zig`
//! and must stay consistent with `ke/timer` + scheduler.

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const pit_hal = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/pit.zig")
else
    struct {
        pub fn getProgrammedHz() u32 {
            return 0;
        }
    };

const ke_timer = @import("../../ke/timer.zig");

pub const IOCTL_PIT_GET_PROGRAMMED_HZ: u32 = 0x000A0000;
pub const IOCTL_PIT_GET_KERNEL_HZ: u32 = 0x000A0004;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn pitDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_PIT_GET_PROGRAMMED_HZ => {
                    irp.buffer_ptr = pit_hal.getProgrammedHz();
                    irp.complete(.success, @sizeOf(u32));
                    return .success;
                },
                IOCTL_PIT_GET_KERNEL_HZ => {
                    irp.buffer_ptr = ke_timer.getHz();
                    irp.complete(.success, @sizeOf(u32));
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

    driver_idx = io.registerDriver("\\Driver\\Pit", pitDispatch) orelse {
        klog.err("PIT: Failed to register driver", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\Pit0", .pit_timer, driver_idx) orelse {
        klog.err("PIT: Failed to create device", .{});
        return;
    };
    driver_initialized = true;

    klog.info("PIT Driver: \\Device\\Pit0 (HAL=%uHz, kernel timer=%uHz)", .{
        pit_hal.getProgrammedHz(),
        ke_timer.getHz(),
    });
}

pub fn isInitialized() bool {
    return driver_initialized;
}
