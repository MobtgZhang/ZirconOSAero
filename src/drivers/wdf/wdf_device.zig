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
//! WDF设备对象实现
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt61.zig");
const io = @import("../../io/io.zig");
const mm = @import("../../mm/mm.zig");
const wdf = @import("mod.zig");
const WdfObject = wdf.WdfObject;
const WdfObjectType = wdf.WdfObjectType;
const WDF_OBJECT_ATTRIBUTES = wdf.WDF_OBJECT_ATTRIBUTES;
const WdfDriverImpl = @import("wdf_driver.zig").WdfDriverImpl;

/// WDF设备对象内部实现
pub const WdfDeviceImpl = struct {
    base: WdfObject,
    driver: *WdfDriverImpl,
    nt_device_object: *io.DEVICE_OBJECT,
    device_name: []const u8,
    device_type: u32,
    device_flags: u32,
    queues: std.ArrayList(*@import("wdf_queue.zig").WdfQueueImpl),

    /// PnP与电源管理回调
    evt_pnp_prepare_hardware: ?fn (*WdfDeviceImpl, *io.CM_RESOURCE_LIST) nt.NTSTATUS,
    evt_pnp_release_hardware: ?fn (*WdfDeviceImpl) void,
    evt_pnp_start_device: ?fn (*WdfDeviceImpl) nt.NTSTATUS,
    evt_pnp_stop_device: ?fn (*WdfDeviceImpl) void,
    evt_pnp_remove_device: ?fn (*WdfDeviceImpl) void,
    evt_power_d0_entry: ?fn (*WdfDeviceImpl, nt.POWER_STATE) nt.NTSTATUS,
    evt_power_d0_exit: ?fn (*WdfDeviceImpl, nt.POWER_STATE) nt.NTSTATUS,

    /// 初始化WDF设备对象
    pub fn init(
        allocator: std.mem.Allocator,
        driver: *WdfDriverImpl,
        device_name: []const u8,
        device_type: u32,
        device_flags: u32,
        attributes: ?*WDF_OBJECT_ATTRIBUTES,
    ) !*WdfDeviceImpl {
        const device = try allocator.create(WdfDeviceImpl);
        errdefer allocator.destroy(device);

        // 初始化基础对象
        device.base.init(WdfObjectType.device, if (attributes) |attr| attr.parent_object else @as(?*WdfObject, &driver.base));

        device.driver = driver;
        device.device_name = try allocator.dupe(u8, device_name);
        device.device_type = device_type;
        device.device_flags = device_flags;
        device.queues = std.ArrayList(*@import("wdf_queue.zig").WdfQueueImpl).init(allocator);

        // 初始化回调函数为null
        device.evt_pnp_prepare_hardware = null;
        device.evt_pnp_release_hardware = null;
        device.evt_pnp_start_device = null;
        device.evt_pnp_stop_device = null;
        device.evt_pnp_remove_device = null;
        device.evt_power_d0_entry = null;
        device.evt_power_d0_exit = null;

        // 创建NT设备对象
        const nt_status = io.IoCreateDevice(
            driver.nt_driver_object,
            0, // 设备扩展大小，WDF上下文单独管理
            &nt.UnicodeString.init(device_name),
            device_type,
            device_flags,
            false, // 非独占
            &device.nt_device_object,
        );
        if (!nt.NT_SUCCESS(nt_status)) {
            return error.IoCreateDeviceFailed;
        }

        // 设置销毁回调
        device.base.setDestroyCallback(&destroy);

        return device;
    }

    /// 销毁WDF设备对象
    fn destroy(obj: *WdfObject) void {
        const device: *WdfDeviceImpl = @fieldParentPtr("base", obj);
        const allocator = mm.heap_allocator();

        // 销毁所有关联的队列
        for (device.queues.items) |queue| {
            queue.base.dereference();
        }
        device.queues.deinit();

        // 删除NT设备对象
        io.IoDeleteDevice(device.nt_device_object);

        allocator.free(device.device_name);
        allocator.destroy(device);
    }

    /// 添加队列到设备
    pub fn addQueue(self: *WdfDeviceImpl, queue: *@import("wdf_queue.zig").WdfQueueImpl) !void {
        try self.queues.append(queue);
        queue.base.reference();
    }

    /// 设置PnP准备硬件回调
    pub fn setPnpPrepareHardwareCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl, *io.CM_RESOURCE_LIST) nt.NTSTATUS) void {
        self.evt_pnp_prepare_hardware = callback;
    }

    /// 设置PnP释放硬件回调
    pub fn setPnpReleaseHardwareCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl) void) void {
        self.evt_pnp_release_hardware = callback;
    }

    /// 设置PnP启动设备回调
    pub fn setPnpStartDeviceCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl) nt.NTSTATUS) void {
        self.evt_pnp_start_device = callback;
    }

    /// 设置PnP停止设备回调
    pub fn setPnpStopDeviceCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl) void) void {
        self.evt_pnp_stop_device = callback;
    }

    /// 设置PnP移除设备回调
    pub fn setPnpRemoveDeviceCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl) void) void {
        self.evt_pnp_remove_device = callback;
    }

    /// 设置电源D0Entry回调
    pub fn setPowerD0EntryCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl, nt.POWER_STATE) nt.NTSTATUS) void {
        self.evt_power_d0_entry = callback;
    }

    /// 设置电源D0Exit回调
    pub fn setPowerD0ExitCallback(self: *WdfDeviceImpl, callback: fn (*WdfDeviceImpl, nt.POWER_STATE) nt.NTSTATUS) void {
        self.evt_power_d0_exit = callback;
    }

    /// 处理PnP IRP
    pub fn dispatchPnpIrp(self: *WdfDeviceImpl, irp: *io.IRP) nt.NTSTATUS {
        const stack = io.IoGetCurrentIrpStackLocation(irp);
        const minor_function = stack.MinorFunction;

        switch (minor_function) {
            io.IRP_MN_START_DEVICE => {
                const resources = stack.Parameters.StartDevice.AllocatedResources;
                if (self.evt_pnp_prepare_hardware) |callback| {
                    const status = callback(self, resources);
                    if (!nt.NT_SUCCESS(status)) {
                        irp.IoStatus.Status = status;
                        io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                        return status;
                    }
                }

                if (self.evt_pnp_start_device) |callback| {
                    const status = callback(self);
                    if (!nt.NT_SUCCESS(status)) {
                        if (self.evt_pnp_release_hardware) |release_callback| {
                            release_callback(self);
                        }
                        irp.IoStatus.Status = status;
                        io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                        return status;
                    }
                }

                // 启动设备成功，完成IRP
                irp.IoStatus.Status = nt.STATUS_SUCCESS;
                io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                return nt.STATUS_SUCCESS;
            },
            io.IRP_MN_STOP_DEVICE => {
                if (self.evt_pnp_stop_device) |callback| {
                    callback(self);
                }

                if (self.evt_pnp_release_hardware) |callback| {
                    callback(self);
                }

                irp.IoStatus.Status = nt.STATUS_SUCCESS;
                io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                return nt.STATUS_SUCCESS;
            },
            io.IRP_MN_REMOVE_DEVICE => {
                if (self.evt_pnp_remove_device) |callback| {
                    callback(self);
                }

                if (self.evt_pnp_release_hardware) |callback| {
                    callback(self);
                }

                irp.IoStatus.Status = nt.STATUS_SUCCESS;
                io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);

                // 销毁设备对象
                self.base.dereference();
                return nt.STATUS_SUCCESS;
            },
            io.IRP_MN_SURPRISE_REMOVAL => {
                // 处理意外移除
                if (self.evt_pnp_remove_device) |callback| {
                    callback(self);
                }

                irp.IoStatus.Status = nt.STATUS_SUCCESS;
                io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                return nt.STATUS_SUCCESS;
            },
            else => {
                // 其他PnP IRP，转发到下层设备
                return io.IoCallDriver(self.nt_device_object.NextDevice, irp);
            },
        }
    }

    /// 处理电源IRP
    pub fn dispatchPowerIrp(self: *WdfDeviceImpl, irp: *io.IRP) nt.NTSTATUS {
        const stack = io.IoGetCurrentIrpStackLocation(irp);
        const minor_function = stack.MinorFunction;
        const power_state = stack.Parameters.Power.PowerState;

        switch (minor_function) {
            io.IRP_MN_SET_POWER => {
                if (power_state.Type == nt.DevicePowerState) {
                    switch (power_state.State.DeviceState) {
                        nt.PowerDeviceD0 => {
                            if (self.evt_power_d0_entry) |callback| {
                                const status = callback(self, power_state);
                                if (!nt.NT_SUCCESS(status)) {
                                    irp.IoStatus.Status = status;
                                    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                                    return status;
                                }
                            }
                        },
                        nt.PowerDeviceD1, nt.PowerDeviceD2, nt.PowerDeviceD3 => {
                            if (self.evt_power_d0_exit) |callback| {
                                const status = callback(self, power_state);
                                if (!nt.NT_SUCCESS(status)) {
                                    irp.IoStatus.Status = status;
                                    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                                    return status;
                                }
                            }
                        },
                        else => {},
                    }
                }

                // 完成电源IRP
                irp.IoStatus.Status = nt.STATUS_SUCCESS;
                io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
                return nt.STATUS_SUCCESS;
            },
            else => {
                // 其他电源IRP，转发到下层设备
                return io.IoCallDriver(self.nt_device_object.NextDevice, irp);
            },
        }
    }
};

/// WDF设备初始化配置
pub const WDF_DEVICE_INIT = struct {
    size: u32,
    device_type: u32,
    device_flags: u32,
    exclusive: bool,

    /// 创建设备初始化结构
    pub fn create(device_type: u32, device_flags: u32) *WDF_DEVICE_INIT {
        const init = mm.heap_allocator().create(WDF_DEVICE_INIT) catch unreachable;
        init.size = @sizeOf(WDF_DEVICE_INIT);
        init.device_type = device_type;
        init.device_flags = device_flags;
        init.exclusive = false;
        return init;
    }
};

/// 创建WDF设备对象
pub fn WdfDeviceCreate(
    driver: *WdfDriverImpl,
    device_init: *WDF_DEVICE_INIT,
    device_attributes: ?*WDF_OBJECT_ATTRIBUTES,
    out_device_handle: ?**wdf.WDFDEVICE,
) nt.NTSTATUS {
    // 验证结构大小
    if (device_init.size != @sizeOf(WDF_DEVICE_INIT)) {
        return nt.STATUS_INVALID_PARAMETER;
    }

    // 生成设备名称
    const device_name = std.fmt.allocPrint(mm.heap_allocator(), "\\Device\\WdfDevice_{}_{}", .{
        driver.driver_name,
        std.time.milliTimestamp(),
    }) catch return nt.STATUS_INSUFFICIENT_RESOURCES;
    defer mm.heap_allocator().free(device_name);

    // 创建WDF设备对象
    const device = WdfDeviceImpl.init(
        mm.heap_allocator(),
        driver,
        device_name,
        device_init.device_type,
        device_init.device_flags,
        device_attributes,
    ) catch |err| {
        return nt.statusFromZigError(err);
    };

    // 返回设备句柄
    if (out_device_handle) |handle| {
        handle.* = @ptrCast(device);
    }

    return nt.STATUS_SUCCESS;
}

/// 初始化WDF设备子系统
pub fn initDeviceSubsystem() nt.NTSTATUS {
    return nt.STATUS_SUCCESS;
}
