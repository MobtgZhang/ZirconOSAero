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
//! NDIS 6.20 协议驱动接口实现
//! 基于微软公开NDIS 6.20技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt/nt_types.zig");
const io = @import("../../io/io.zig");
const ndis = @import("ndis_types.zig");
const ndis_buffer = @import("ndis_buffer.zig");

/// 协议驱动特征结构
pub const NDIS_PROTOCOL_CHARACTERISTICS = extern struct {
    HeaderType: u8 = 0x02, // NDIS_OBJECT_TYPE_PROTOCOL_CHARACTERISTICS
    Revision: u8 = 0x01,
    Size: u16 = @sizeOf(NDIS_PROTOCOL_CHARACTERISTICS),
    MajorNdisVersion: u8 = ndis.NDIS_MAJOR_VERSION,
    MinorNdisVersion: u8 = ndis.NDIS_MINOR_VERSION,
    Reserved: u16 = 0,
    Name: nt.UNICODE_STRING,
    OpenAdapterCompleteHandler: ?fn (
        ProtocolBindingContext: *anyopaque,
        Status: ndis.NDIS_STATUS,
        OpenErrorCode: u32,
    ) void,
    CloseAdapterCompleteHandler: ?fn (
        ProtocolBindingContext: *anyopaque,
    ) void,
    SendCompleteHandler: ?fn (
        ProtocolBindingContext: *anyopaque,
        NetBufferList: *ndis.NET_BUFFER_LIST,
        Status: ndis.NDIS_STATUS,
    ) void,
    ReceiveNetBufferListsHandler: fn (
        ProtocolBindingContext: *anyopaque,
        NetBufferLists: *ndis.NET_BUFFER_LIST,
        NumberOfNetBufferLists: u32,
        ReceiveFlags: u32,
    ) void,
    StatusHandler: ?fn (
        ProtocolBindingContext: *anyopaque,
        Status: ndis.NDIS_STATUS,
        StatusBuffer: *anyopaque,
        StatusBufferSize: u32,
    ) void,
    PnPEventHandler: ?fn (
        ProtocolBindingContext: *anyopaque,
        PnPEvent: ndis.NDIS_PNP_EVENT,
    ) ndis.NDIS_STATUS,
    UnloadHandler: ?fn () void,
};

/// 协议绑定结构
const ProtocolBinding = struct {
    signature: u32 = 0x50524F54, // 'PROT'
    adapter_handle: ndis.NDIS_HANDLE,
    binding_context: *anyopaque,
    characteristics: *const NDIS_PROTOCOL_CHARACTERISTICS,
    next: ?*ProtocolBinding,
};

/// 协议驱动结构
const ProtocolDriver = struct {
    signature: u32 = 0x50524F54, // 'PROT'
    characteristics: NDIS_PROTOCOL_CHARACTERISTICS,
    bindings: ?*ProtocolBinding = null,
    next: ?*ProtocolDriver = null,
};

var protocol_list: ?*ProtocolDriver = null;
var protocol_list_lock: nt.KSPIN_LOCK = .{};

/// 注册NDIS协议驱动
pub fn NdisRegisterProtocolDriver(
    driver_object: *nt.DRIVER_OBJECT,
    protocol_char: *const NDIS_PROTOCOL_CHARACTERISTICS,
) ndis.NDIS_STATUS {
    const allocator = std.heap.page_allocator;
    const protocol = allocator.create(ProtocolDriver) catch return ndis.NDIS_STATUS_INSUFFICIENT_RESOURCES;

    protocol.* = .{
        .characteristics = protocol_char.*,
    };

    nt.KeAcquireSpinLock(&protocol_list_lock);
    defer nt.KeReleaseSpinLock(&protocol_list_lock);

    protocol.next = protocol_list;
    protocol_list = protocol;

    // 设置IRP处理例程
    driver_object.MajorFunction[io.MJ_DEVICE_CONTROL] = ndisIoControl;
    driver_object.MajorFunction[io.MJ_CREATE] = ndisCreate;
    driver_object.MajorFunction[io.MJ_CLOSE] = ndisClose;

    return ndis.NDIS_STATUS_SUCCESS;
}

/// 注销NDIS协议驱动
pub fn NdisDeregisterProtocolDriver(protocol_handle: ndis.NDIS_HANDLE) void {
    const protocol: *ProtocolDriver = @ptrCast(protocol_handle);
    std.debug.assert(protocol.signature == 0x50524F54);

    nt.KeAcquireSpinLock(&protocol_list_lock);
    defer nt.KeReleaseSpinLock(&protocol_list_lock);

    // 从列表中移除
    var prev: ?*ProtocolDriver = null;
    var current = protocol_list;
    while (current != null) : (current = current.?.next) {
        if (current == protocol) {
            if (prev == null) {
                protocol_list = current.?.next;
            } else {
                prev.?.next = current.?.next;
            }
            break;
        }
        prev = current;
    }

    // 释放所有绑定
    var binding = protocol.bindings;
    while (binding != null) {
        const next_binding = binding.?.next;
        std.heap.page_allocator.destroy(binding.?);
        binding = next_binding;
    }

    std.heap.page_allocator.destroy(protocol);
}

/// 打开NDIS适配器
pub fn NdisOpenAdapterEx(
    protocol_handle: ndis.NDIS_HANDLE,
    binding_context: *anyopaque,
    _adapter_name: *nt.UNICODE_STRING,
) ndis.NDIS_STATUS {
    _ = _adapter_name;
    const protocol: *ProtocolDriver = @ptrCast(protocol_handle);
    std.debug.assert(protocol.signature == 0x50524F54);

    const allocator = std.heap.page_allocator;
    const binding = allocator.create(ProtocolBinding) catch return ndis.NDIS_STATUS_INSUFFICIENT_RESOURCES;

    binding.* = .{
        .binding_context = binding_context,
        .characteristics = &protocol.characteristics,
        .adapter_handle = null, // 这里需要查找对应的适配器
        .next = null,
    };

    // TODO: 实现适配器查找逻辑，根据名称找到对应的miniport设备

    nt.KeAcquireSpinLock(&protocol_list_lock);
    defer nt.KeReleaseSpinLock(&protocol_list_lock);

    binding.next = protocol.bindings;
    protocol.bindings = binding;

    return ndis.NDIS_STATUS_SUCCESS;
}

/// 关闭NDIS适配器
pub fn NdisCloseAdapterEx(adapter_handle: ndis.NDIS_HANDLE) ndis.NDIS_STATUS {
    // TODO: 实现关闭适配器逻辑
    _ = adapter_handle;
    return ndis.NDIS_STATUS_SUCCESS;
}

/// 发送网络数据包
pub fn NdisSendNetBufferLists(
    adapter_handle: ndis.NDIS_HANDLE,
    net_buffer_lists: *ndis.NET_BUFFER_LIST,
    send_flags: u32,
) ndis.NDIS_STATUS {
    // TODO: 实现数据包发送逻辑，将NBL传递给miniport驱动
    _ = adapter_handle;
    _ = net_buffer_lists;
    _ = send_flags;
    return ndis.NDIS_STATUS_PENDING;
}

/// miniport驱动调用此函数指示收到的数据包
pub fn NdisMIndicateReceiveNetBufferLists(
    miniport_handle: ndis.NDIS_HANDLE,
    net_buffer_lists: *ndis.NET_BUFFER_LIST,
    number_of_nbl: u32,
    receive_flags: u32,
) void {
    // 遍历所有绑定到该适配器的协议驱动，调用其接收处理函数
    nt.KeAcquireSpinLock(&protocol_list_lock);
    defer nt.KeReleaseSpinLock(&protocol_list_lock);

    var protocol = protocol_list;
    while (protocol != null) : (protocol = protocol.?.next) {
        var binding = protocol.?.bindings;
        while (binding != null) : (binding = binding.?.next) {
            if (binding.?.adapter_handle == miniport_handle) {
                // 调用协议驱动的接收处理函数
                binding.?.characteristics.ReceiveNetBufferListsHandler(
                    binding.?.binding_context,
                    net_buffer_lists,
                    number_of_nbl,
                    receive_flags,
                );
            }
        }
    }
}

/// miniport驱动调用此函数完成发送请求
pub fn NdisMSendNetBufferListsComplete(
    miniport_handle: ndis.NDIS_HANDLE,
    net_buffer_lists: *ndis.NET_BUFFER_LIST,
    send_complete_flags: u32,
) void {
    // 遍历NBL，调用对应的协议驱动的发送完成回调
    _ = miniport_handle;
    _ = net_buffer_lists;
    _ = send_complete_flags;
    // TODO: 实现发送完成逻辑
}

// 网络IOCTL处理
fn ndisIoControl(
    _device_object: *nt.DEVICE_OBJECT,
    irp: *io.IRP,
) nt.NTSTATUS {
    _ = _device_object;
    const io_stack = io.IoGetCurrentIrpStackLocation(irp);
    const control_code = io_stack.Parameters.DeviceIoControl.IoControlCode;

    switch (control_code) {
        // 常见网络IOCTL实现
        IOCTL_NDIS_QUERY_GLOBAL_STATS => {
            // 处理统计信息查询
        },
        IOCTL_NDIS_SET_GLOBAL_STATS => {
            // 处理统计信息设置
        },
        IOCTL_SOCKET => {
            // 处理Winsock相关IOCTL
        },
        else => {
            irp.IoStatus.Information = 0;
            irp.IoStatus.Status = nt.STATUS_NOT_SUPPORTED;
            io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
            return nt.STATUS_NOT_SUPPORTED;
        },
    }

    irp.IoStatus.Information = 0;
    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn ndisCreate(
    _device_object: *nt.DEVICE_OBJECT,
    irp: *io.IRP,
) nt.NTSTATUS {
    _ = _device_object;
    irp.IoStatus.Information = 0;
    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn ndisClose(
    _device_object: *nt.DEVICE_OBJECT,
    irp: *io.IRP,
) nt.NTSTATUS {
    _ = _device_object;
    irp.IoStatus.Information = 0;
    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

/// 网络IOCTL代码定义
pub const IOCTL_NDIS_QUERY_GLOBAL_STATS = 0x00170002;
pub const IOCTL_NDIS_SET_GLOBAL_STATS = 0x00170006;
pub const IOCTL_SOCKET = 0x00120003;

/// NDIS PnP事件类型
pub const NDIS_PNP_EVENT = extern struct {
    EventCode: u32,
    Buffer: *anyopaque,
    BufferLength: u32,
    Flags: u32,
};
