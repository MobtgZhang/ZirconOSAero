//! USB host controller driver (xHCI 1.x / EHCI) — registration + IOCTL stub.
//! Full enumeration (ports, hubs, HID mass-storage) needs MMIO BAR mapping + IRQ.
//!
//! Registers `\Driver\UsbHost` and `\Device\USB0` for the I/O manager stack.

const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

pub const IOCTL_USB_GET_STATUS: u32 = 0x000A0000;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn usbDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_USB_GET_STATUS => {
                    irp.complete(.success, 0);
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
    driver_idx = io.registerDriver("\\Driver\\UsbHost", usbDispatch) orelse {
        klog.err("USB: Failed to register host driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\USB0", .usb_host, driver_idx) orelse {
        klog.err("USB: Failed to create \\Device\\USB0", .{});
        return;
    };

    driver_initialized = true;
    klog.info("USB: Host driver registered (xHCI/EHCI MMIO + port enumeration stub)", .{});
}

pub fn isInitialized() bool {
    return driver_initialized;
}
