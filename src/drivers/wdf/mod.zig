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
//! WDF (Windows Driver Frameworks) 模块导出
//! 基于微软公开WDF技术文档，符合Clean Room开发规范
//! 兼容NT6.1.7601 WDF 1.9版本

const std = @import("std");
const nt = @import("../../nt61.zig");
const ob = @import("../../ob/ob.zig");
const io = @import("../../io/io.zig");
const mm = @import("../../mm/mm.zig");

pub const wdf_types = @import("wdf_types.zig");
pub const wdf_driver = @import("wdf_driver.zig");
pub const wdf_device = @import("wdf_device.zig");
pub const wdf_queue = @import("wdf_queue.zig");
pub const wdf_memory = @import("wdf_memory.zig");
pub const wdf_pnp = @import("wdf_pnp.zig");
/// WDF版本定义，兼容NT6.1.7601 WDF 1.9版本
pub const WDF_MAJOR_VERSION: u16 = 1;
pub const WDF_MINOR_VERSION: u16 = 9;
pub const WDF_VERSION = (WDF_MAJOR_VERSION << 16) | WDF_MINOR_VERSION;

/// WDF对象类型枚举
pub const WdfObjectType = enum(u32) {
    invalid = 0,
    driver = 1,
    device = 2,
    queue = 3,
    memory = 4,
    request = 5,
    file = 6,
    interrupt = 7,
    dma_transaction = 8,
    dma_enabler = 9,
    common_buffer = 10,
    lookaside = 11,
    timer = 12,
    workitem = 13,
    waitlock = 14,
    event = 15,
    mutex = 16,
    semaphore = 17,
    spinlock = 18,
    object_attributes = 19,
    string = 20,
    registry_key = 21,
    resource_list = 22,
    resource_requirements_list = 23,
    dpc = 24,
    wmi_instance = 25,
    wmi_provider = 26,
    io_target = 27,
    device_interface = 28,
    usbd_device = 29,
    usbd_interface = 30,
    usbd_pipe = 31,
    usbd_request = 32,
    chid_target = 33,
};

/// WDF对象基类，所有WDF对象都继承自这个结构
pub const WdfObject = struct {
    type: WdfObjectType,
    reference_count: std.atomic.Atomic(u32),
    parent: ?*WdfObject,
    context: ?*anyopaque,
    destroy_callback: ?fn (*WdfObject) void,

    /// 初始化WDF对象基类
    pub fn init(self: *WdfObject, object_type: WdfObjectType, parent: ?*WdfObject) void {
        self.type = object_type;
        self.reference_count = std.atomic.Atomic(u32).init(1);
        self.parent = parent;
        self.context = null;
        self.destroy_callback = null;

        // 增加父对象引用计数
        if (parent) |p| {
            p.reference();
        }
    }

    /// 增加对象引用计数
    pub fn reference(self: *WdfObject) void {
        _ = self.reference_count.fetchAdd(1, .seq_cst);
    }

    /// 减少对象引用计数，当引用计数为0时销毁对象
    pub fn dereference(self: *WdfObject) void {
        const prev_count = self.reference_count.fetchSub(1, .seq_cst);
        if (prev_count == 1) {
            self.destroy();
        }
    }

    /// 销毁对象
    fn destroy(self: *WdfObject) void {
        // 调用销毁回调
        if (self.destroy_callback) |callback| {
            callback(self);
        }

        // 释放父对象引用
        if (self.parent) |p| {
            p.dereference();
        }

        // 释放对象内存
        mm.heap_free(self);
    }

    /// 设置对象上下文
    pub fn setContext(self: *WdfObject, context: *anyopaque) void {
        self.context = context;
    }

    /// 获取对象上下文
    pub fn getContext(self: *WdfObject) ?*anyopaque {
        return self.context;
    }

    /// 设置对象销毁回调
    pub fn setDestroyCallback(self: *WdfObject, callback: fn (*WdfObject) void) void {
        self.destroy_callback = callback;
    }
};

/// WDF对象属性结构
pub const WDF_OBJECT_ATTRIBUTES = struct {
    size: u32,
    parent_object: ?*WdfObject,
    context_size: usize,
    context_type_guid: ?*nt.GUID,
    execution_level: WDF_EXECUTION_LEVEL,
    synchronization_scope: WDF_SYNCHRONIZATION_SCOPE,

    /// 执行级别枚举
    pub const WDF_EXECUTION_LEVEL = enum(u32) {
        invalid = 0,
        passive = 1,
        dispatch = 2,
    };

    /// 同步范围枚举
    pub const WDF_SYNCHRONIZATION_SCOPE = enum(u32) {
        invalid = 0,
        device = 1,
        queue = 2,
        none = 3,
    };

    /// 初始化默认对象属性
    pub fn init() WDF_OBJECT_ATTRIBUTES {
        return WDF_OBJECT_ATTRIBUTES{
            .size = @sizeOf(WDF_OBJECT_ATTRIBUTES),
            .parent_object = null,
            .context_size = 0,
            .context_type_guid = null,
            .execution_level = .passive,
            .synchronization_scope = .none,
        };
    }
};

/// 初始化WDF框架
pub fn wdfInit() nt.NTSTATUS {
    // 注册WDF对象类型
    var status = wdf_driver.init();
    if (!nt.NT_SUCCESS(status)) return status;

    status = wdf_device.init();
    if (!nt.NT_SUCCESS(status)) return status;

    status = wdf_queue.init();
    if (!nt.NT_SUCCESS(status)) return status;

    status = wdf_memory.init();
    if (!nt.NT_SUCCESS(status)) return status;

    status = wdf_pnp.init();
    if (!nt.NT_SUCCESS(status)) return status;

    return nt.STATUS_SUCCESS;
}
