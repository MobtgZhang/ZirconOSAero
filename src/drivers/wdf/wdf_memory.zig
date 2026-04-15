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
//! WDF内存对象实现
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt61.zig");
const mm = @import("../../mm/mm.zig");
const wdf = @import("mod.zig");
const WdfObject = wdf.WdfObject;
const WdfObjectType = wdf.WdfObjectType;
const WDF_OBJECT_ATTRIBUTES = wdf.WDF_OBJECT_ATTRIBUTES;
const WDF_MEMORY_FLAGS = wdf.WDF_MEMORY_FLAGS;

/// WDF内存对象内部实现
pub const WdfMemoryImpl = struct {
    base: WdfObject,
    buffer: []u8,
    flags: WDF_MEMORY_FLAGS,
    user_address: ?usize,
    process_id: ?nt.PID,

    /// 初始化WDF内存对象
    pub fn init(
        allocator: std.mem.Allocator,
        size: usize,
        flags: WDF_MEMORY_FLAGS,
        attributes: ?*WDF_OBJECT_ATTRIBUTES,
    ) !*WdfMemoryImpl {
        const memory = try allocator.create(WdfMemoryImpl);
        errdefer allocator.destroy(memory);

        // 初始化基础对象
        memory.base.init(WdfObjectType.memory, if (attributes) |attr| attr.parent_object else null);

        // 分配内存
        if (flags.non_paged) {
            memory.buffer = try mm.heap_allocator().alloc(u8, size);
        } else if (flags.paged) {
            memory.buffer = try mm.paged_allocator().alloc(u8, size);
        } else {
            // 默认使用非分页内存
            memory.buffer = try mm.heap_allocator().alloc(u8, size);
        }

        memory.flags = flags;
        memory.user_address = null;
        memory.process_id = null;

        // 设置销毁回调
        memory.base.setDestroyCallback(&destroy);

        return memory;
    }

    /// 从用户缓冲区创建WDF内存对象
    pub fn initFromUserBuffer(
        allocator: std.mem.Allocator,
        user_buffer: [*]u8,
        size: usize,
        attributes: ?*WDF_OBJECT_ATTRIBUTES,
    ) !*WdfMemoryImpl {
        const memory = try allocator.create(WdfMemoryImpl);
        errdefer allocator.destroy(memory);

        // 初始化基础对象
        memory.base.init(WdfObjectType.memory, if (attributes) |attr| attr.parent_object else null);

        // 验证用户地址
        if (!mm.isUserAddress(@intFromPtr(user_buffer))) {
            return error.InvalidUserAddress;
        }

        // 分配内核缓冲区
        memory.buffer = try mm.heap_allocator().alloc(u8, size);
        errdefer mm.heap_allocator().free(memory.buffer);

        // 复制用户数据到内核缓冲区
        @memcpy(memory.buffer, user_buffer[0..size]);

        memory.flags = WDF_MEMORY_FLAGS{ .non_paged = true };
        memory.user_address = @intFromPtr(user_buffer);
        memory.process_id = nt.PsGetCurrentProcessId();

        // 设置销毁回调
        memory.base.setDestroyCallback(&destroy);

        return memory;
    }

    /// 销毁WDF内存对象
    fn destroy(obj: *WdfObject) void {
        const memory: *WdfMemoryImpl = @fieldParentPtr("base", obj);
        const allocator = mm.heap_allocator();

        // 释放缓冲区
        if (memory.flags.non_paged) {
            mm.heap_allocator().free(memory.buffer);
        } else if (memory.flags.paged) {
            mm.paged_allocator().free(memory.buffer);
        } else {
            mm.heap_allocator().free(memory.buffer);
        }

        allocator.destroy(memory);
    }

    /// 获取内存缓冲区指针
    pub fn getBuffer(self: *WdfMemoryImpl) []u8 {
        return self.buffer;
    }

    /// 获取内存大小
    pub fn getLength(self: *WdfMemoryImpl) usize {
        return self.buffer.len;
    }

    /// 复制数据到用户缓冲区
    pub fn copyToUser(self: *WdfMemoryImpl, user_buffer: [*]u8, size: usize) nt.NTSTATUS {
        if (size > self.buffer.len) {
            return nt.STATUS_BUFFER_TOO_SMALL;
        }

        if (!mm.isUserAddress(@intFromPtr(user_buffer))) {
            return nt.STATUS_INVALID_USER_BUFFER;
        }

        // 复制内核数据到用户缓冲区
        @memcpy(user_buffer[0..size], self.buffer[0..size]);

        return nt.STATUS_SUCCESS;
    }

    /// 从用户缓冲区复制数据
    pub fn copyFromUser(self: *WdfMemoryImpl, user_buffer: [*]const u8, size: usize) nt.NTSTATUS {
        if (size > self.buffer.len) {
            return nt.STATUS_BUFFER_TOO_SMALL;
        }

        if (!mm.isUserAddress(@intFromPtr(user_buffer))) {
            return nt.STATUS_INVALID_USER_BUFFER;
        }

        // 复制用户数据到内核缓冲区
        @memcpy(self.buffer[0..size], user_buffer[0..size]);

        return nt.STATUS_SUCCESS;
    }
};

/// 创建WDF内存对象
pub fn WdfMemoryCreate(
    attributes: ?*WDF_OBJECT_ATTRIBUTES,
    flags: WDF_MEMORY_FLAGS,
    buffer_size: usize,
    out_memory_handle: ?**wdf.WDFMEMORY,
    out_buffer: ?*[*]u8,
) nt.NTSTATUS {
    if (buffer_size == 0) {
        return nt.STATUS_INVALID_PARAMETER;
    }

    // 创建内存对象
    const memory = WdfMemoryImpl.init(
        mm.heap_allocator(),
        buffer_size,
        flags,
        attributes,
    ) catch |err| {
        return nt.statusFromZigError(err);
    };

    // 返回内存句柄
    if (out_memory_handle) |handle| {
        handle.* = @ptrCast(memory);
    }

    // 返回缓冲区指针
    if (out_buffer) |buffer| {
        buffer.* = memory.buffer.ptr;
    }

    return nt.STATUS_SUCCESS;
}

/// 初始化WDF内存子系统
pub fn init() nt.NTSTATUS {
    return nt.STATUS_SUCCESS;
}

/// 从现有缓冲区创建WDF内存对象
pub fn WdfMemoryCreatePreallocated(
    attributes: ?*WDF_OBJECT_ATTRIBUTES,
    buffer: [*]u8,
    buffer_size: usize,
    out_memory_handle: ?**wdf.WDFMEMORY,
) nt.NTSTATUS {
    _ = attributes;
    _ = buffer;
    _ = buffer_size;
    _ = out_memory_handle;
    // TODO: 实现预分配缓冲区支持
    return nt.STATUS_NOT_IMPLEMENTED;
}

/// 获取内存对象的缓冲区
pub fn WdfMemoryGetBuffer(
    memory_handle: *wdf.WDFMEMORY,
    out_buffer_length: ?*usize,
) [*]u8 {
    const memory = @as(*WdfMemoryImpl, @ptrCast(memory_handle));

    if (out_buffer_length) |length| {
        length.* = memory.buffer.len;
    }

    return memory.buffer.ptr;
}

/// 复制内存对象内容到用户缓冲区
pub fn WdfMemoryCopyToBuffer(
    source_memory: *wdf.WDFMEMORY,
    source_offset: usize,
    destination_buffer: [*]u8,
    destination_length: usize,
) nt.NTSTATUS {
    const memory = @as(*WdfMemoryImpl, @ptrCast(source_memory));

    if (source_offset + destination_length > memory.buffer.len) {
        return nt.STATUS_BUFFER_TOO_SMALL;
    }

    if (!mm.isUserAddress(@intFromPtr(destination_buffer))) {
        return nt.STATUS_INVALID_USER_BUFFER;
    }

    @memcpy(destination_buffer[0..destination_length], memory.buffer[source_offset..][0..destination_length]);

    return nt.STATUS_SUCCESS;
}

/// 从用户缓冲区复制内容到内存对象
pub fn WdfMemoryCopyFromBuffer(
    destination_memory: *wdf.WDFMEMORY,
    destination_offset: usize,
    source_buffer: [*]const u8,
    source_length: usize,
) nt.NTSTATUS {
    const memory = @as(*WdfMemoryImpl, @ptrCast(destination_memory));

    if (destination_offset + source_length > memory.buffer.len) {
        return nt.STATUS_BUFFER_TOO_SMALL;
    }

    if (!mm.isUserAddress(@intFromPtr(source_buffer))) {
        return nt.STATUS_INVALID_USER_BUFFER;
    }

    @memcpy(memory.buffer[destination_offset..][0..source_length], source_buffer[0..source_length]);

    return nt.STATUS_SUCCESS;
}
