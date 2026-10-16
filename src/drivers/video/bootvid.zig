// SPDX-License-Identifier: MIT OR Apache-2.0
//! Clean-room Boot Video Driver stage for the kernel-owned framebuffer.
//!
//! Windows NT uses BootVID between `ExitBootServices` and the full graphics
//! stack.  This module gives the kernel startup log that same display stage
//! without exposing UEFI services and without carrying Microsoft resources.

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const bootvid_console = @import("../../rtl/bootvid_console.zig");

const framebuffer = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("../../hal/x86_64/framebuffer.zig"),
    .aarch64 => @import("../../hal/aarch64/framebuffer.zig"),
    .loongarch64 => @import("../../hal/loongarch64/framebuffer.zig"),
    .riscv64 => @import("../../hal/riscv64/framebuffer.zig"),
    .mips64el => @import("../../hal/mips64el/framebuffer.zig"),
    else => @compileError("bootvid: unsupported architecture"),
};

var initialized: bool = false;
var driver_idx: u32 = 0;
var device_idx: u32 = 0;

fn dispatch(_: *io.Irp) io.NTSTATUS {
    return io.STATUS_SUCCESS;
}

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    if (addr == 0 or width == 0 or height == 0 or pitch == 0 or bpp == 0) return;
    framebuffer.init(addr, width, height, pitch, bpp);
    framebuffer.clear();
    bootvid_console.setActive(true);
    initialized = true;
    klog.info("BootVID: active (framebuffer %ux%u@%ubpp, pitch=%u)", .{ width, height, bpp, pitch });
}

pub fn deactivate() void {
    bootvid_console.setActive(false);
    framebuffer.clear();
}

pub fn isActive() bool {
    return initialized and bootvid_console.isActive();
}

pub fn registerWithIo() void {
    if (!initialized or driver_idx != 0) return;
    driver_idx = io.registerDriver("\\Driver\\Bootvid", dispatch) orelse {
        klog.warn("BootVID: driver registration failed (logging continues)", .{});
        return;
    };
    device_idx = io.createDevice("\\Device\\Bootvid0", .framebuffer, driver_idx) orelse {
        klog.warn("BootVID: device creation failed (logging continues)", .{});
        return;
    };
    klog.info("BootVID: \\Device\\Bootvid0 registered", .{});
}
