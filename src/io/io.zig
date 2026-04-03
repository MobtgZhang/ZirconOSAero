// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/io/io.zig
// Purpose: I/O Manager — IRP、设备栈、驱动分发表、与 VFS/块设备衔接的最小子集。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/ — IRP, IoCompleteRequest,
//      IoCallDriver, device stacks; WDK IRP_MJ_* / IRP_MN_* 公开枚举与行为描述。

const std = @import("std");
const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");
const mdl_mod = @import("../mm/mdl.zig");

/// NTSTATUS 子集（与 `ntdll.NTSTATUS` 数值一致；`io` 不依赖 `ntdll` 以避免环引用）。
pub const NTSTATUS = i32;

pub const STATUS_SUCCESS: NTSTATUS = 0;
pub const STATUS_PENDING: NTSTATUS = 259;
pub const STATUS_INVALID_PARAMETER: NTSTATUS = -1073741811;
pub const STATUS_ACCESS_DENIED: NTSTATUS = -1073741790;
pub const STATUS_NOT_IMPLEMENTED: NTSTATUS = -1073741822;
pub const STATUS_BUFFER_TOO_SMALL: NTSTATUS = -1073741789;
pub const STATUS_END_OF_FILE: NTSTATUS = -1073741807;
pub const STATUS_OBJECT_NAME_NOT_FOUND: NTSTATUS = -1073741772;
pub const STATUS_INVALID_DEVICE_REQUEST: NTSTATUS = @bitCast(@as(u32, 0xC0000010));
pub const STATUS_IO_DEVICE_ERROR: NTSTATUS = @bitCast(@as(u32, 0xC0000185));
pub const STATUS_DISK_FULL: NTSTATUS = @bitCast(@as(u32, 0xC000007F));
pub const STATUS_NOT_A_DIRECTORY: NTSTATUS = @bitCast(@as(u32, 0xC0000103));
pub const STATUS_FILE_IS_A_DIRECTORY: NTSTATUS = @bitCast(@as(u32, 0xC00000BA));
pub const STATUS_OBJECT_NAME_COLLISION: NTSTATUS = -1073741771;
pub const STATUS_DEVICE_NOT_READY: NTSTATUS = @bitCast(@as(u32, 0xC00000A3));
pub const STATUS_CANCELLED: NTSTATUS = @bitCast(@as(u32, 0xC0000120));
pub const STATUS_INSUFFICIENT_RESOURCES: NTSTATUS = -1073741823;

/// 与用户态/文档 `IO_STATUS_BLOCK` 布局对齐（x64：8+8）。
pub const IO_STATUS_BLOCK = extern struct {
    status: NTSTATUS = STATUS_SUCCESS,
    information: u64 = 0,
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
    /// WDK `IRP_MJ_PNP`
    pnp = 9,
    /// WDK `IRP_MJ_POWER`
    power = 10,
};

comptime {
    std.debug.assert(@intFromEnum(IrpMajorFunction.pnp) == 9);
    std.debug.assert(@intFromEnum(IrpMajorFunction.power) == 10);
}

/// WDK `IRP_MN_*` PnP 子集（公开头文件枚举值；clean-room 仅使用文档化常量）。
pub const IrpMinorPnp = enum(u8) {
    start_device = 0,
    query_remove_device = 1,
    remove_device = 2,
    cancel_remove_device = 3,
    stop_device = 4,
    query_stop_device = 5,
    cancel_stop_device = 6,
    query_capabilities = 7,
    filter_resource_requirements = 8,
    _,
};

/// Power minor（占位；与 `DEVICE_POWER_STATE` 全链路线图）。
pub const IrpMinorPower = enum(u8) {
    wait_wake = 0,
    power_sequence = 1,
    set_power = 2,
    query_power = 3,
    _,
};

pub const IRP_MJ_COUNT: usize = @intFromEnum(IrpMajorFunction.power) + 1;

/// 最多注册两层完成例程（LIFO 调用；完整 NT 链为动态分配，见 WDK）。
pub const MAX_COMPLETION_ROUTINES: usize = 2;

pub const IrpCompletionRoutine = *const fn (*Irp) void;

pub const Irp = struct {
    major_function: IrpMajorFunction = .create,
    minor_function: u8 = 0,
    status: NTSTATUS = STATUS_SUCCESS,
    /// 与 `system_buffer` 同义；历史字段名保留供驱动 IOCTL 路径使用。
    buffer_ptr: u64 = 0,
    /// WDK: `AssociatedIrp.SystemBuffer`（METHOD_BUFFERED 概念）。
    system_buffer: u64 = 0,
    /// WDK: `UserBuffer`。
    user_buffer: u64 = 0,
    /// WDK: `MdlAddress`；0 表示无 MDL（`mm/mdl.zig` 接线前占位）。
    mdl_address: u64 = 0,
    /// 可选：写回 `IO_STATUS_BLOCK`（syscall 代理或测试桩）。
    io_status_block_ptr: u64 = 0,
    buffer_size: usize = 0,
    bytes_transferred: usize = 0,
    ioctl_code: u32 = 0,
    device_ptr: u64 = 0,
    /// WDK: `Irp->Flags` 子集。
    flags: u32 = 0,
    /// 隧道指针：如 `*vfs.FileObject`（卷栈分发）。
    tail: u64 = 0,
    pending: bool = false,
    cancel: bool = false,
    completion_depth: u8 = 0,
    completion_stack: [MAX_COMPLETION_ROUTINES]?IrpCompletionRoutine = .{ null, null },

    pub fn complete(self: *Irp, nt_status: NTSTATUS, transferred: usize) void {
        self.status = nt_status;
        self.bytes_transferred = transferred;
    }

    /// 读路径统一取内核缓冲 VA：`buffer_ptr` 与 `system_buffer` 互填。
    pub fn syncSystemBuffer(self: *Irp) void {
        if (self.system_buffer != 0 and self.buffer_ptr == 0) self.buffer_ptr = self.system_buffer;
        if (self.buffer_ptr != 0 and self.system_buffer == 0) self.system_buffer = self.buffer_ptr;
    }
};

/// 入栈完成例程（满则忽略；与 WDK 多层完成语义近似，深度固定为 2）。
pub fn IoSetCompletionRoutine(irp: *Irp, routine: ?IrpCompletionRoutine) void {
    const r = routine orelse return;
    if (irp.completion_depth >= MAX_COMPLETION_ROUTINES) return;
    irp.completion_stack[irp.completion_depth] = r;
    irp.completion_depth += 1;
}

/// WDK `IoMarkIrpPending` 子集：标记挂起；调用方应返回 `STATUS_PENDING`。
pub fn IoMarkIrpPending(irp: *Irp) void {
    irp.pending = true;
}

/// 子集取消：设置 `cancel`；驱动应在长操作前检查并中止（完整 `IoCancelIrp` 见 WDK）。
pub fn IoCancelIrp(irp: *Irp) void {
    irp.cancel = true;
}

/// WDK `IoAllocateMdl` / `MdlAddress` 接线子集：将已填充/锁页的 `Mdl` 内核指针挂到 IRP（DMA / `METHOD_*` 路径）。
/// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/using-mdls
pub fn IoAttachMdlToIrp(irp: *Irp, mdl: *mdl_mod.Mdl) void {
    irp.mdl_address = @intFromPtr(mdl);
}

pub fn IoDetachMdlFromIrp(irp: *Irp) void {
    irp.mdl_address = 0;
}

/// WDK `IoCompleteRequest`：写状态、传输长度、可选 `IO_STATUS_BLOCK`、LIFO 调用完成例程。
pub fn IoCompleteRequest(irp: *Irp, status: NTSTATUS, transferred: usize) void {
    irp.complete(status, transferred);
    if (irp.io_status_block_ptr != 0) {
        // SAFETY: 调用方保证指针在内核可写且对齐；syscall 层探测后传入。
        const iosb: *IO_STATUS_BLOCK = @ptrFromInt(irp.io_status_block_ptr);
        iosb.status = status;
        iosb.information = transferred;
    }
    while (irp.completion_depth > 0) {
        irp.completion_depth -= 1;
        if (irp.completion_stack[irp.completion_depth]) |cb| {
            irp.completion_stack[irp.completion_depth] = null;
            cb(irp);
        }
    }
}

pub fn attachDeviceToDeviceStack(upper_idx: u32, lower_idx: u32) bool {
    if (upper_idx >= device_count or lower_idx >= device_count) return false;
    devices[upper_idx].attached_device = lower_idx;
    devices[upper_idx].stack_size = @max(
        devices[upper_idx].stack_size,
        devices[lower_idx].stack_size +| 1,
    );
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
    pci_bus = 10,
    pit_timer = 11,
    rtc_clock = 12,
    usb_host = 13,
    usb_hid = 14,
};

/// 设备扩展区最大长度（`DEVICE_OBJECT.DeviceExtension` 定长子集）。
pub const MAX_DEVICE_EXTENSION: usize = 128;

pub const DeviceObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .device },
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    device_type: DeviceType = .unknown,
    flags: u32 = 0,
    driver_idx: u32 = 0,
    attached_device: u32 = 0,
    /// 栈深度概念（与 WDK `StackSize` 同阶；用于 IRP 栈位置占位）。
    stack_size: u8 = 1,
    extension: [MAX_DEVICE_EXTENSION]u8 align(8) = undefined,
};

/// WDK `IoGetDeviceExtension` 子集。
pub fn IoGetDeviceExtension(dev: *DeviceObject) *anyopaque {
    return @ptrCast(&dev.extension);
}

pub const DriverDispatchFn = *const fn (*Irp) NTSTATUS;

pub const MAX_DRIVERS: usize = 24;

pub const DriverObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .driver },
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    device_count: usize = 0,
    /// 未注册 `major_dispatch[major]` 时回退到此例程（兼容单入口驱动）。
    dispatch: ?DriverDispatchFn = null,
    major_dispatch: [IRP_MJ_COUNT]?DriverDispatchFn = .{null} ** IRP_MJ_COUNT,
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

pub fn setDriverMajorDispatch(driver_idx: u32, major: IrpMajorFunction, handler: ?DriverDispatchFn) void {
    if (driver_idx >= driver_count) return;
    drivers[driver_idx].major_dispatch[@intFromEnum(major)] = handler;
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
    dev.stack_size = 1;

    device_count += 1;

    if (driver_idx < driver_count) {
        drivers[driver_idx].device_count += 1;
    }

    klog.debug("I/O: Device '%s' created (idx=%u, type=%u)", .{
        name, idx, @intFromEnum(dev_type),
    });
    return @intCast(idx);
}

pub fn getDeviceObject(idx: u32) ?*DeviceObject {
    if (idx >= device_count) return null;
    return &devices[idx];
}

/// WDK `IoCallDriver` 子集：向指定设备投递 IRP（同步返回 NTSTATUS）。
pub fn IoCallDriver(device_idx: u32, irp: *Irp) NTSTATUS {
    return dispatchIrp(device_idx, irp);
}

pub fn dispatchIrp(device_idx: u32, irp: *Irp) NTSTATUS {
    if (device_idx >= device_count) return STATUS_INVALID_PARAMETER;

    const dev = &devices[device_idx];
    irp.device_ptr = @intFromPtr(dev);

    if (dev.driver_idx >= driver_count) return STATUS_INVALID_DEVICE_REQUEST;
    const drv = &drivers[dev.driver_idx];
    const major = @intFromEnum(irp.major_function);
    const handler: ?DriverDispatchFn = if (major < IRP_MJ_COUNT)
        drv.major_dispatch[major]
    else
        null;
    const fn_dispatch = handler orelse drv.dispatch orelse return STATUS_INVALID_DEVICE_REQUEST;
    return fn_dispatch(irp);
}

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

pub fn dispatchIrpThroughStack(top_idx: u32, irp: *Irp) NTSTATUS {
    var idx = top_idx;
    var guard: usize = 0;
    while (guard < MAX_DEVICES) : (guard += 1) {
        if (idx >= device_count) return STATUS_INVALID_PARAMETER;
        const st = dispatchIrp(idx, irp);
        if (st != STATUS_NOT_IMPLEMENTED) return st;
        const next = devices[idx].attached_device;
        if (next == 0) return st;
        idx = next;
    }
    return STATUS_NOT_IMPLEMENTED;
}

/// WDK `IoForwardIrpToDeviceObject` 概念子集：向栈上 **紧邻下层** 设备投递 IRP（无下层则 `STATUS_INVALID_DEVICE_REQUEST`）。
pub fn IoForwardIrpToNextDevice(upper_idx: u32, irp: *Irp) NTSTATUS {
    if (upper_idx >= device_count) return STATUS_INVALID_PARAMETER;
    const next = devices[upper_idx].attached_device;
    if (next == 0) return STATUS_INVALID_DEVICE_REQUEST;
    return IoCallDriver(next, irp);
}

pub fn getDeviceCount() usize {
    return device_count;
}

pub fn getDriverCount() usize {
    return driver_count;
}

pub fn isInitialized() bool {
    return io_initialized;
}
