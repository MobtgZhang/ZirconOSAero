// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//!
//! WDF I/O队列实现
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt61.zig");
const io = @import("../../io/io.zig");
const mm = @import("../../mm/mm.zig");
const ke = @import("../../ke/ke.zig");
const wdf = @import("mod.zig");
const WdfObject = wdf.WdfObject;
const WdfObjectType = wdf.WdfObjectType;
const WDF_OBJECT_ATTRIBUTES = wdf.WDF_OBJECT_ATTRIBUTES;
const WDF_IO_QUEUE_TYPE = wdf.WDF_IO_QUEUE_TYPE;
const WDF_IO_QUEUE_DISPATCH_TYPE = wdf.WDF_IO_QUEUE_DISPATCH_TYPE;
const WdfDeviceImpl = @import("wdf_device.zig").WdfDeviceImpl;

/// WDF队列请求项
const WdfRequestItem = struct {
    irp: *io.IRP,
    request: *wdf.WDFREQUEST,
    timestamp: u64,
};

/// WDF队列对象内部实现
pub const WdfQueueImpl = struct {
    base: WdfObject,
    device: *WdfDeviceImpl,
    queue_type: WDF_IO_QUEUE_TYPE,
    dispatch_type: WDF_IO_QUEUE_DISPATCH_TYPE,
    is_default_queue: bool,
    power_managed: bool,

    /// 请求队列和同步锁
    request_queue: std.TailQueue(WdfRequestItem),
    queue_lock: ke.SpinLock,
    current_request_count: std.atomic.Atomic(u32),
    max_concurrent_requests: u32,

    /// 回调函数
    evt_io_read: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u64, u32) void,
    evt_io_write: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u64, u32) void,
    evt_io_device_control: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u32, []u8, []u8) void,
    evt_io_internal_device_control: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u32, []u8, []u8) void,
    evt_io_cleanup: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST) void,
    evt_io_close: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST) void,
    evt_io_flush_buffers: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST) void,
    evt_io_query_information: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u32) void,
    evt_io_set_information: ?fn (*wdf.WDFQUEUE, *wdf.WDFREQUEST, u32) void,

    /// 初始化WDF队列对象
    pub fn init(
        allocator: std.mem.Allocator,
        device: *WdfDeviceImpl,
        queue_type: WDF_IO_QUEUE_TYPE,
        dispatch_type: WDF_IO_QUEUE_DISPATCH_TYPE,
        is_default_queue: bool,
        max_concurrent_requests: u32,
        attributes: ?*WDF_OBJECT_ATTRIBUTES,
    ) !*WdfQueueImpl {
        const queue = try allocator.create(WdfQueueImpl);
        errdefer allocator.destroy(queue);

        // 初始化基础对象
        queue.base.init(WdfObjectType.queue, if (attributes) |attr| attr.parent_object else @as(?*WdfObject, &device.base));

        queue.device = device;
        queue.queue_type = queue_type;
        queue.dispatch_type = dispatch_type;
        queue.is_default_queue = is_default_queue;
        queue.power_managed = true;
        queue.max_concurrent_requests = if (max_concurrent_requests == 0) 1 else max_concurrent_requests;
        queue.current_request_count = std.atomic.Atomic(u32).init(0);
        queue.request_queue = .{};
        queue.queue_lock = ke.SpinLock.init();

        // 初始化所有回调为null
        queue.evt_io_read = null;
        queue.evt_io_write = null;
        queue.evt_io_device_control = null;
        queue.evt_io_internal_device_control = null;
        queue.evt_io_cleanup = null;
        queue.evt_io_close = null;
        queue.evt_io_flush_buffers = null;
        queue.evt_io_query_information = null;
        queue.evt_io_set_information = null;

        // 设置销毁回调
        queue.base.setDestroyCallback(&destroy);

        return queue;
    }

    /// 销毁WDF队列对象
    fn destroy(obj: *WdfObject) void {
        const queue: *WdfQueueImpl = @fieldParentPtr("base", obj);
        const allocator = mm.heap_allocator();

        // 清空请求队列
        queue.queue_lock.lock();
        defer queue.queue_lock.unlock();

        while (queue.request_queue.pop()) |node| {
            // 取消所有未处理的IRP
            const irp = node.data.irp;
            irp.IoStatus.Status = nt.STATUS_CANCELLED;
            irp.IoStatus.Information = 0;
            io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);

            // 释放请求对象
            // TODO: 释放WDFREQUEST对象
            allocator.destroy(node);
        }

        allocator.destroy(queue);
    }

    /// 添加IRP到队列
    pub fn enqueueIrp(self: *WdfQueueImpl, irp: *io.IRP) nt.NTSTATUS {
        const allocator = mm.heap_allocator();

        // 创建请求项
        const node = try allocator.create(std.TailQueue(WdfRequestItem).Node);
        errdefer allocator.destroy(node);

        // 创建WDF请求对象
        // TODO: 实现WDFREQUEST对象创建
        const request = @as(*wdf.WDFREQUEST, undefined);

        node.data = .{
            .irp = irp,
            .request = request,
            .timestamp = ke.KeQueryInterruptTime(),
        };

        // 入队
        self.queue_lock.lock();
        defer self.queue_lock.unlock();

        self.request_queue.append(node);

        // 尝试处理队列
        self.processQueueLocked();

        return nt.STATUS_PENDING;
    }

    /// 处理队列中的请求（需要持有队列锁）
    fn processQueueLocked(self: *WdfQueueImpl) void {
        // 根据调度类型处理请求
        switch (self.dispatch_type) {
            .sequential => {
                // 顺序调度：同一时间只处理一个请求
                if (self.current_request_count.load(.seq_cst) == 0) {
                    if (self.request_queue.first) |node| {
                        _ = self.request_queue.pop();
                        self.current_request_count.fetchAdd(1, .seq_cst);

                        // 解锁后处理请求，避免死锁
                        self.queue_lock.unlock();
                        self.processRequest(node.data);
                        self.queue_lock.lock();
                    }
                }
            },
            .parallel => {
                // 并行调度：最多同时处理max_concurrent_requests个请求
                while (self.current_request_count.load(.seq_cst) < self.max_concurrent_requests) {
                    if (self.request_queue.pop()) |node| {
                        self.current_request_count.fetchAdd(1, .seq_cst);

                        // 解锁后处理请求
                        self.queue_lock.unlock();
                        self.processRequest(node.data);
                        self.queue_lock.lock();
                    } else {
                        break;
                    }
                }
            },
            .manual => {
                // 手动调度：需要驱动显式获取请求
                // 不做自动处理
            },
            else => {},
        }
    }

    /// 处理单个请求
    fn processRequest(self: *WdfQueueImpl, item: WdfRequestItem) void {
        defer {
            // 请求处理完成，减少计数并尝试处理更多请求
            self.current_request_count.fetchSub(1, .seq_cst);
            self.queue_lock.lock();
            self.processQueueLocked();
            self.queue_lock.unlock();
        }

        const irp = item.irp;
        const stack = io.IoGetCurrentIrpStackLocation(irp);

        // 根据IRP主功能码调用对应的回调函数
        switch (stack.MajorFunction) {
            io.IRP_MJ_READ => {
                if (self.evt_io_read) |callback| {
                    callback(
                        @ptrCast(self),
                        item.request,
                        stack.Parameters.Read.ByteOffset.QuadPart,
                        stack.Parameters.Read.Length,
                    );
                    return;
                }
            },
            io.IRP_MJ_WRITE => {
                if (self.evt_io_write) |callback| {
                    callback(
                        @ptrCast(self),
                        item.request,
                        stack.Parameters.Write.ByteOffset.QuadPart,
                        stack.Parameters.Write.Length,
                    );
                    return;
                }
            },
            io.IRP_MJ_DEVICE_CONTROL => {
                if (self.evt_io_device_control) |callback| {
                    const input_buffer = irp.AssociatedIrp.SystemBuffer;
                    const output_buffer = irp.AssociatedIrp.SystemBuffer;
                    const input_length = stack.Parameters.DeviceControl.InputBufferLength;
                    const output_length = stack.Parameters.DeviceControl.OutputBufferLength;
                    const io_control_code = stack.Parameters.DeviceControl.IoControlCode;

                    callback(
                        @ptrCast(self),
                        item.request,
                        io_control_code,
                        @as([*]u8, input_buffer)[0..input_length],
                        @as([*]u8, output_buffer)[0..output_length],
                    );
                    return;
                }
            },
            io.IRP_MJ_INTERNAL_DEVICE_CONTROL => {
                if (self.evt_io_internal_device_control) |callback| {
                    const input_buffer = irp.AssociatedIrp.SystemBuffer;
                    const output_buffer = irp.AssociatedIrp.SystemBuffer;
                    const input_length = stack.Parameters.DeviceControl.InputBufferLength;
                    const output_length = stack.Parameters.DeviceControl.OutputBufferLength;
                    const io_control_code = stack.Parameters.DeviceControl.IoControlCode;

                    callback(
                        @ptrCast(self),
                        item.request,
                        io_control_code,
                        @as([*]u8, input_buffer)[0..input_length],
                        @as([*]u8, output_buffer)[0..output_length],
                    );
                    return;
                }
            },
            io.IRP_MJ_CLEANUP => {
                if (self.evt_io_cleanup) |callback| {
                    callback(@ptrCast(self), item.request);
                    return;
                }
            },
            io.IRP_MJ_CLOSE => {
                if (self.evt_io_close) |callback| {
                    callback(@ptrCast(self), item.request);
                    return;
                }
            },
            io.IRP_MJ_FLUSH_BUFFERS => {
                if (self.evt_io_flush_buffers) |callback| {
                    callback(@ptrCast(self), item.request);
                    return;
                }
            },
            io.IRP_MJ_QUERY_INFORMATION => {
                if (self.evt_io_query_information) |callback| {
                    callback(
                        @ptrCast(self),
                        item.request,
                        stack.Parameters.QueryFile.FileInformationClass,
                    );
                    return;
                }
            },
            io.IRP_MJ_SET_INFORMATION => {
                if (self.evt_io_set_information) |callback| {
                    callback(
                        @ptrCast(self),
                        item.request,
                        stack.Parameters.SetFile.FileInformationClass,
                    );
                    return;
                }
            },
            else => {},
        }

        // 没有对应的回调处理，完成IRP并返回不支持
        irp.IoStatus.Status = nt.STATUS_NOT_SUPPORTED;
        irp.IoStatus.Information = 0;
        io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    }

    /// 请求处理完成，由驱动调用
    pub fn completeRequest(self: *WdfQueueImpl, request: *wdf.WDFREQUEST, status: nt.NTSTATUS, information: usize) void {
        _ = self;
        _ = request;
        _ = status;
        _ = information;
        // TODO: 实现请求完成逻辑
    }
};

/// WDF队列配置结构
pub const WDF_IO_QUEUE_CONFIG = struct {
    size: u32,
    queue_type: WDF_IO_QUEUE_TYPE,
    dispatch_type: WDF_IO_QUEUE_DISPATCH_TYPE,
    is_default_queue: bool,
    max_concurrent_requests: u32,
    power_managed: bool,

    /// 初始化默认队列配置
    pub fn initDefault(
        dispatch_type: WDF_IO_QUEUE_DISPATCH_TYPE,
        is_default_queue: bool,
    ) WDF_IO_QUEUE_CONFIG {
        return WDF_IO_QUEUE_CONFIG{
            .size = @sizeOf(WDF_IO_QUEUE_CONFIG),
            .queue_type = if (dispatch_type == .manual) .manual else .sequential,
            .dispatch_type = dispatch_type,
            .is_default_queue = is_default_queue,
            .max_concurrent_requests = if (dispatch_type == .parallel) 10 else 1,
            .power_managed = true,
        };
    }

    /// 初始化并行队列配置
    pub fn initParallel(
        is_default_queue: bool,
        max_concurrent_requests: u32,
    ) WDF_IO_QUEUE_CONFIG {
        return WDF_IO_QUEUE_CONFIG{
            .size = @sizeOf(WDF_IO_QUEUE_CONFIG),
            .queue_type = .parallel,
            .dispatch_type = .parallel,
            .is_default_queue = is_default_queue,
            .max_concurrent_requests = max_concurrent_requests,
            .power_managed = true,
        };
    }

    /// 初始化手动队列配置
    pub fn initManual(is_default_queue: bool) WDF_IO_QUEUE_CONFIG {
        return WDF_IO_QUEUE_CONFIG{
            .size = @sizeOf(WDF_IO_QUEUE_CONFIG),
            .queue_type = .manual,
            .dispatch_type = .manual,
            .is_default_queue = is_default_queue,
            .max_concurrent_requests = 0,
            .power_managed = true,
        };
    }
};

/// 创建WDF队列对象
pub fn WdfIoQueueCreate(
    device: *WdfDeviceImpl,
    queue_config: *WDF_IO_QUEUE_CONFIG,
    queue_attributes: ?*WDF_OBJECT_ATTRIBUTES,
    out_queue_handle: ?**wdf.WDFQUEUE,
) nt.NTSTATUS {
    // 验证配置结构大小
    if (queue_config.size != @sizeOf(WDF_IO_QUEUE_CONFIG)) {
        return nt.STATUS_INVALID_PARAMETER;
    }

    // 创建队列对象
    const queue = WdfQueueImpl.init(
        mm.heap_allocator(),
        device,
        queue_config.queue_type,
        queue_config.dispatch_type,
        queue_config.is_default_queue,
        queue_config.max_concurrent_requests,
        queue_attributes,
    ) catch |err| {
        return nt.statusFromZigError(err);
    };

    // 添加队列到设备
    device.addQueue(queue) catch |err| {
        queue.base.dereference();
        return nt.statusFromZigError(err);
    };

    // 如果是默认队列，设置设备的默认队列
    if (queue_config.is_default_queue) {
        // TODO: 保存默认队列引用到设备对象
    }

    // 返回队列句柄
    if (out_queue_handle) |handle| {
        handle.* = @ptrCast(queue);
    }

    return nt.STATUS_SUCCESS;
}

/// 初始化WDF队列子系统
pub fn init() nt.NTSTATUS {
    return nt.STATUS_SUCCESS;
}
