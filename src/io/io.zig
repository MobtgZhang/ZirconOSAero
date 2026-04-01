//! I/O Manager (NT style)
//! Manages device objects, driver objects, and I/O request dispatch
//! IRP-style I/O request routing through device stacks
//!
//! Phase 3 roadmap (LPC, registry, Nt* alignment): [docs/cn/ExecutivePhase3_Milestones.md](../../docs/cn/ExecutivePhase3_Milestones.md).
//! 内核 I/O 分阶段待办（设备栈、PnP/Power）：[docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K4。
//! VFS file operations: [`vfs.dispatchFileObjectIr`](../fs/vfs.zig) builds a minimal `Irp` for read/write/close from `ntdll`.

const std = @import("std");
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
    /// PnP：设备枚举、启动、移除等（WDK `IRP_MJ_PNP` 概念；分发与 PDO/FDO 栈为路线图）。
    pnp = 9,
    /// 电源：Dx/Ix 状态转换（WDK `IRP_MJ_POWER` 概念；当前占位供驱动注册表对齐）。
    power = 10,
};

comptime {
    std.debug.assert(@intFromEnum(IrpMajorFunction.pnp) == 9);
    std.debug.assert(@intFromEnum(IrpMajorFunction.power) == 10);
}

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
    completion_routine: ?IrpCompletionRoutine = null,

    pub fn complete(self: *Irp, status: IoStatus, transferred: usize) void {
        self.status = status;
        self.bytes_transferred = transferred;
    }
};

/// 注册完成例程；在 `IoCompleteRequest` 末尾同步调用一次后自动清除（无多层完成例程链）。
pub fn IoSetCompletionRoutine(irp: *Irp, routine: ?IrpCompletionRoutine) void {
    irp.completion_routine = routine;
}

/// 与 WDK 中 `IoCompleteRequest` 公开语义对齐的最小子集：写回状态与传输字节数，并可选调用 `completion_routine`。
pub fn IoCompleteRequest(irp: *Irp, status: IoStatus, transferred: usize) void {
    irp.complete(status, transferred);
    if (irp.completion_routine) |cb| {
        cb(irp);
        irp.completion_routine = null;
    }
}

/// 将 `upper` 设备附加到 `lower` 之下（NT 设备栈方向：I/O 自顶向下）；用于总线 FDO → PDO 最小演示路径。
pub fn attachDeviceToDeviceStack(upper_idx: u32, lower_idx: u32) bool {
    if (upper_idx >= device_count or lower_idx >= device_count) return false;
    devices[upper_idx].attached_device = lower_idx;
    return true;
}

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
    /// USB HID 类占位（完整路径：xHCI MMIO → 枚举 → HID 中断端点；当前指针以 PS/2 + VirtIO-Input 为主）
    usb_hid = 14,
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

/// 与 WDK `PIO_COMPLETION_ROUTINE` 概念对齐的最小子集：在 `IoCompleteRequest` 之后调用一次。
pub const IrpCompletionRoutine = *const fn (*Irp) void;

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

/// 自栈顶（FDO）沿 `attached_device` 链向下找到最底层 PDO 索引。
pub fn resolveStackBottom(top_idx: u32) u32 {
    var idx = top_idx;
    var guard: usize = 0;
    while (guard < MAX_DEVICES) : (guard += 1) {
        if (idx >= device_count) return top_idx;
        const next = devices[idx].attached_device;
        if (next == 0) return idx;
        idx = next;
    }
    return top_idx;
}

/// 将 IRP 先派发到 `top_idx`；若返回 `not_implemented` 则沿栈向下尝试下一设备（K4.2 最小下传模型）。
pub fn dispatchIrpThroughStack(top_idx: u32, irp: *Irp) IoStatus {
    var idx = top_idx;
    var guard: usize = 0;
    while (guard < MAX_DEVICES) : (guard += 1) {
        if (idx >= device_count) return .invalid_device;
        const st = dispatchIrp(idx, irp);
        if (st != .not_implemented) return st;
        const next = devices[idx].attached_device;
        if (next == 0) return st;
        idx = next;
    }
    return .not_implemented;
}

pub fn getDeviceCount() usize {
    return device_count;
}

pub fn getDriverCount() usize {
    return driver_count;
}
