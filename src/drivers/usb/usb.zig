//! USB 主机栈入口：PCI 枚举 xHCI/EHCI、`\\Device\\USB0`、可选 `\\Device\\USB\\HCn`、IOCTL 状态。

const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const pcie = @import("../bus/pcie.zig");
const pci_bind = @import("../bus/pci_driver_bind.zig");
const build_options = @import("build_options");
const xhci = @import("xhci.zig");
const ehci = @import("ehci.zig");

pub const IOCTL_USB_GET_STATUS: u32 = 0x000A0000;

const MAX_USB_HC_PCI: usize = 8;
const MAX_HC_DEVICES: usize = 4;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
var xhci_count: u32 = 0;
var xhci_running: u32 = 0;
var ehci_seen: u32 = 0;

fn usbDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_USB_GET_STATUS => {
                    const v = xhci_count | (xhci_running << 8) | (ehci_seen << 16);
                    irp.buffer_ptr = v;
                    irp.complete(io.STATUS_SUCCESS, @sizeOf(u32));
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

fn createHcDevices() void {
    var n: u32 = 0;
    while (n < xhci_running and n < MAX_HC_DEVICES) : (n += 1) {
        var name: [32]u8 = undefined;
        @memset(&name, 0);
        const prefix = "\\Device\\USB\\HC";
        @memcpy(name[0..prefix.len], prefix);
        const digit: u8 = @as(u8, @intCast(@min(n, 9))) + '0';
        name[prefix.len] = digit;
        _ = io.createDevice(name[0 .. prefix.len + 1], .usb_host, driver_idx) orelse {
            klog.warn("USB: create HC device failed", .{});
        };
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

    _ = io.createDevice("\\Device\\USB\\HidStub", .usb_hid, driver_idx) orelse {
        klog.warn("USB: Failed to create \\Device\\USB\\HidStub", .{});
    };

    xhci_count = 0;
    xhci_running = 0;
    ehci_seen = 0;

    if (pcie.supports_pci_config and build_options.usb_xhci) {
        var buf: [MAX_USB_HC_PCI]pcie.UsbHostPciInfo = undefined;
        const n = pcie.collectUsbHostControllers(buf[0..], 1);
        var picked_xhci = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const inf = buf[i];
            const bind_hint = pci_bind.lookupFromConfigClassWord(inf.vendor_id, inf.device_id, inf.class_code);
            if (build_options.debug and i == 0) {
                klog.debug("USB: pci_driver_bind first HC -> %s", .{@tagName(bind_hint)});
            }
            switch (inf.kind) {
                .xhci => {
                    xhci_count += 1;
                    if (!picked_xhci and xhci.initFromPci(inf)) {
                        picked_xhci = true;
                        xhci_running = 1;
                    }
                },
                .ehci => {
                    ehci_seen += 1;
                    if (!picked_xhci and build_options.usb_ehci) {
                        _ = ehci.tryInit(inf);
                    }
                },
                else => {},
            }
        }
        if (xhci_running > 0) {
            createHcDevices();
            klog.info("USB: xHCI active (PCI hosts=%u)", .{xhci_count});
            klog.info("USB: xhci_mvt enumerate_ok hosts=%u", .{xhci_count});
        } else if (xhci_count > 0) {
            klog.warn("USB: xHCI PCI found but init failed", .{});
        }
    } else if (!build_options.usb_xhci) {
        klog.info("USB: usb_xhci disabled (build flag)", .{});
    }

    if (xhci_running == 0) {
        klog.info("USB: no xHCI active; input: VirtIO-Input / PS/2", .{});
    }

    driver_initialized = true;
}

pub fn poll() void {
    xhci.poll();
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn xhciIsActive() bool {
    return xhci.isActive();
}
