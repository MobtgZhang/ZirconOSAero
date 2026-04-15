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
//! WDF驱动对象实现
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt61.zig");
const ob = @import("../../ob/ob.zig");
const io = @import("../../io/io.zig");
const mm = @import("../../mm/mm.zig");
const wdf = @import("mod.zig");
const WdfObject = wdf.WdfObject;
const WdfObjectType = wdf.WdfObjectType;
const WDF_OBJECT_ATTRIBUTES = wdf.WDF_OBJECT_ATTRIBUTES;

/// WDF驱动对象内部实现
pub const WdfDriverImpl = struct {
    base: WdfObject,
    driver_name: []const u8,
    version_major: u16,
    version_minor: u16,
    nt_driver_object: *io.DRIVER_OBJECT,
    evt_driver_device_add: ?fn (*WdfDriverImpl, *io.DEVICE_OBJECT) nt.NTSTATUS,
    evt_driver_unload: ?fn (*WdfDriverImpl) void,

    /// 初始化WDF驱动对象
    pub fn init(
        allocator: std.mem.Allocator,
        driver_name: []const u8,
        version_major: u16,
        version_minor: u16,
        attributes: ?*WDF_OBJECT_ATTRIBUTES,
    ) !*WdfDriverImpl {
        const driver = try allocator.create(WdfDriverImpl);
        errdefer allocator.destroy(driver);

        // 初始化基础对象
        driver.base.init(WdfObjectType.driver, if (attributes) |attr| attr.parent_object else null);

        driver.driver_name = try allocator.dupe(u8, driver_name);
        driver.version_major = version_major;
        driver.version_minor = version_minor;
        driver.nt_driver_object = undefined;
        driver.evt_driver_device_add = null;
        driver.evt_driver_unload = null;

        // 设置销毁回调
        driver.base.setDestroyCallback(&destroy);

        return driver;
    }

    /// 销毁WDF驱动对象
    fn destroy(obj: *WdfObject) void {
        const driver: *WdfDriverImpl = @fieldParentPtr("base", obj);
        const allocator = mm.heap_allocator();

        if (driver.evt_driver_unload) |unload| {
            unload(driver);
        }

        allocator.free(driver.driver_name);
        allocator.destroy(driver);
    }

    /// 设置DeviceAdd事件回调
    pub fn setEvtDeviceAdd(self: *WdfDriverImpl, callback: fn (*WdfDriverImpl, *io.DEVICE_OBJECT) nt.NTSTATUS) void {
        self.evt_driver_device_add = callback;
    }

    /// 设置Unload事件回调
    pub fn setEvtUnload(self: *WdfDriverImpl, callback: fn (*WdfDriverImpl) void) void {
        self.evt_driver_unload = callback;
    }
};

/// WDF驱动初始化参数
pub const WDF_DRIVER_CONFIG = struct {
    size: u32,
    evt_driver_device_add: ?fn (*WdfDriverImpl, *io.DEVICE_OBJECT) nt.NTSTATUS,
    evt_driver_unload: ?fn (*WdfDriverImpl) void,
    driver_pool_tag: u32,
    major_version: u16,
    minor_version: u16,

    /// 初始化默认配置
    pub fn init() WDF_DRIVER_CONFIG {
        return WDF_DRIVER_CONFIG{
            .size = @sizeOf(WDF_DRIVER_CONFIG),
            .evt_driver_device_add = null,
            .evt_driver_unload = null,
            .driver_pool_tag = 0x4644574B, // KWDF
            .major_version = wdf.WDF_MAJOR_VERSION,
            .minor_version = wdf.WDF_MINOR_VERSION,
        };
    }
};

/// WDF驱动入口点
pub fn WdfDriverCreate(
    driver_object: *io.DRIVER_OBJECT,
    registry_path: []const u8,
    driver_attributes: ?*WDF_OBJECT_ATTRIBUTES,
    driver_config: *WDF_DRIVER_CONFIG,
    out_driver_handle: ?**wdf.WDFDRIVER,
) nt.NTSTATUS {
    _ = registry_path; // TODO: 处理注册表路径

    // 验证配置结构大小
    if (driver_config.size != @sizeOf(WDF_DRIVER_CONFIG)) {
        return nt.STATUS_INVALID_PARAMETER;
    }

    // 创建WDF驱动对象
    const driver = WdfDriverImpl.init(
        mm.heap_allocator(),
        driver_object.driver_name,
        driver_config.major_version,
        driver_config.minor_version,
        driver_attributes,
    ) catch |err| {
        return nt.statusFromZigError(err);
    };

    // 保存NT驱动对象引用
    driver.nt_driver_object = driver_object;

    // 设置回调函数
    if (driver_config.evt_driver_device_add) |callback| {
        driver.setEvtDeviceAdd(callback);
    }
    if (driver_config.evt_driver_unload) |callback| {
        driver.setEvtUnload(callback);
    }

    // 设置NT驱动的卸载回调
    driver_object.DriverUnload = ntDriverUnload;

    // 设置NT驱动的分发例程默认处理函数
    for (driver_object.MajorFunction[0..]) |*func| {
        func.* = wdfDefaultDispatch;
    }

    // 返回驱动句柄
    if (out_driver_handle) |handle| {
        handle.* = @ptrCast(driver);
    }

    return nt.STATUS_SUCCESS;
}

/// NT驱动卸载回调
fn ntDriverUnload(driver_object: *io.DRIVER_OBJECT) void {
    _ = driver_object;
    // TODO: 查找对应的WDF驱动对象并调用其Unload回调
}

/// 默认IRP分发处理函数
fn wdfDefaultDispatch(device_object: *io.DEVICE_OBJECT, irp: *io.IRP) nt.NTSTATUS {
    _ = device_object;
    _ = irp;
    // TODO: 将IRP转发到WDF队列处理
    return nt.STATUS_NOT_SUPPORTED;
}

/// 初始化WDF驱动子系统
pub fn init() nt.NTSTATUS {
    // 目前无需额外初始化
    return nt.STATUS_SUCCESS;
}
