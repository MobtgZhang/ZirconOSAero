//! I/O Manager (NT style)
//! Manages device objects, driver objects, and I/O request dispatch
//! IRP-style I/O request routing through device stacks

const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

pub const IoStatus = enum(u32) {
    success = 0,
    pending = 1,
    invalid_device = 2,
    not_implemented = 3,
    access_denied = 4,
    buffer_overflow = 5,
    end_of_file = 6,
    not_found = 7,
};

pub const IrpMajorFunction = enum(u8) {
    create = 0,
    close = 1,
    read = 2,
    write = 3,
    ioctl = 4,
    cleanup = 5,
    flush = 6,
    query_info = 7,
    set_info = 8,
};

pub const Irp = struct {
    major_function: IrpMajorFunction = .create,
    minor_function: u8 = 0,
    status: IoStatus = .success,
    buffer_ptr: u64 = 0,
    buffer_size: usize = 0,
    bytes_transferred: usize = 0,
    ioctl_code: u32 = 0,
    device_ptr: u64 = 0,
    flags: u32 = 0,

    pub fn complete(self: *Irp, status: IoStatus, transferred: usize) void {
        self.status = status;
        self.bytes_transferred = transferred;
    }
};

pub const MAX_DEVICES: usize = 32;

pub const DeviceType = enum(u32) {
    unknown = 0,
    console = 1,
    serial = 2,
    keyboard = 3,
    disk = 4,
    filesystem = 5,
    network = 6,
    framebuffer = 7,
    mouse = 8,
    audio = 9,
    /// PCI/PCIe bus (config space access; NT: bus driver / FDO)
    pci_bus = 10,
    /// 8254 PIT — kernel tick source (NT: HAL profile timer / profile driver)
    pit_timer = 11,
    /// MC146818 RTC / CMOS (NT: \Device\Rtc)
    rtc_clock = 12,
    /// USB xHCI/EHCI root (stub until PnP + MMIO bring-up)
    usb_host = 13,
};

pub const DeviceObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .device },
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    device_type: DeviceType = .unknown,
    flags: u32 = 0,
    driver_idx: u32 = 0,
    attached_device: u32 = 0,
};

pub const DriverDispatchFn = *const fn (*Irp) IoStatus;

pub const MAX_DRIVERS: usize = 24;

pub const DriverObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .driver },
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    device_count: usize = 0,
    dispatch: ?DriverDispatchFn = null,
};

var devices: [MAX_DEVICES]DeviceObject = [_]DeviceObject{.{}} ** MAX_DEVICES;
var device_count: usize = 0;

var drivers: [MAX_DRIVERS]DriverObject = [_]DriverObject{.{}} ** MAX_DRIVERS;
var driver_count: usize = 0;

var io_initialized: bool = false;

pub fn init() void {
    device_count = 0;
    driver_count = 0;
    io_initialized = true;
    klog.info("I/O Manager: initialized", .{});
}

pub fn registerDriver(name: []const u8, dispatch: ?DriverDispatchFn) ?u32 {
    if (driver_count >= MAX_DRIVERS) return null;

    const idx = driver_count;
    var drv = &drivers[idx];
    drv.* = .{};
    const copy_len = @min(name.len, drv.name.len);
    @memcpy(drv.name[0..copy_len], name[0..copy_len]);
    drv.name_len = copy_len;
    drv.dispatch = dispatch;

    driver_count += 1;

    klog.debug("I/O: Driver '%s' registered (idx=%u)", .{ name, idx });
    return @intCast(idx);
}

pub fn createDevice(name: []const u8, dev_type: DeviceType, driver_idx: u32) ?u32 {
    if (device_count >= MAX_DEVICES) return null;

    const idx = device_count;
    var dev = &devices[idx];
    dev.* = .{};
    const copy_len = @min(name.len, dev.name.len);
    @memcpy(dev.name[0..copy_len], name[0..copy_len]);
    dev.name_len = copy_len;
    dev.device_type = dev_type;
    dev.driver_idx = driver_idx;

    device_count += 1;

    if (driver_idx < driver_count) {
        drivers[driver_idx].device_count += 1;
    }

    klog.debug("I/O: Device '%s' created (idx=%u, type=%u)", .{
        name, idx, @intFromEnum(dev_type),
    });
    return @intCast(idx);
}

pub fn dispatchIrp(device_idx: u32, irp: *Irp) IoStatus {
    if (device_idx >= device_count) return .invalid_device;

    const dev = &devices[device_idx];
    irp.device_ptr = @intFromPtr(dev);

    if (dev.driver_idx < driver_count) {
        const drv = &drivers[dev.driver_idx];
        if (drv.dispatch) |dispatch_fn| {
            return dispatch_fn(irp);
        }
    }

    return .not_implemented;
}

pub fn getDeviceCount() usize {
    return device_count;
}

pub fn getDriverCount() usize {
    return driver_count;
}
