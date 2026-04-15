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
//! NDIS 6.20 缓冲区管理实现
//! 基于微软公开NDIS 6.20技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt/nt_types.zig");
const mm = @import("../../mm/mm.zig");
const ndis = @import("ndis_types.zig");

pub const NDIS_HANDLE = *anyopaque;

/// NET_BUFFER池结构
const NetBufferPool = struct {
    signature: u32 = 0x4E42504C, // 'NBPL'
    allocator: std.mem.Allocator,
    data_size: c_ulong,
    pool_flags: c_ulong,
    allocated_count: usize = 0,
};

/// NET_BUFFER_LIST池结构
const NetBufferListPool = struct {
    signature: u32 = 0x4E424C50, // 'NBLP'
    allocator: std.mem.Allocator,
    context_size: c_ulong,
    pool_flags: c_ulong,
    allocated_count: usize = 0,
};

/// 创建NET_BUFFER池
pub fn NdisAllocateNetBufferPool(
    allocator: std.mem.Allocator,
    pool_flags: c_ulong,
    data_size: c_ulong,
) NDIS_HANDLE {
    const pool = allocator.create(NetBufferPool) catch return null;

    pool.* = .{
        .allocator = allocator,
        .pool_flags = pool_flags,
        .data_size = data_size,
    };

    return pool;
}

/// 销毁NET_BUFFER池
pub fn NdisFreeNetBufferPool(pool_handle: NDIS_HANDLE) void {
    const pool: *NetBufferPool = @ptrCast(pool_handle);
    std.debug.assert(pool.signature == 0x4E42504C);

    pool.allocator.destroy(pool);
}

/// 从池中分配NET_BUFFER
pub fn NdisAllocateNetBuffer(
    pool_handle: NDIS_HANDLE,
    mdl_chain: ?*ndis.MDL,
    data_offset: c_ulong,
    data_length: c_ulong,
) ?*ndis.NET_BUFFER {
    const pool: *NetBufferPool = @ptrCast(pool_handle);
    std.debug.assert(pool.signature == 0x4E42504C);

    const nb = pool.allocator.create(ndis.NET_BUFFER) catch return null;

    nb.* = std.mem.zeroInit(ndis.NET_BUFFER, .{});
    nb.NetBufferData.MdlChain = mdl_chain;
    nb.NetBufferData.DataOffset = data_offset;
    nb.NetBufferData.DataLength = data_length;
    nb.NetBufferData.NdisPoolHandle = pool_handle;

    // 初始化CurrentMdl指针
    if (mdl_chain != null) {
        var remaining = data_offset;
        var current_mdl = mdl_chain;

        while (current_mdl != null and remaining > current_mdl.?.ByteCount) : (current_mdl = current_mdl.?.Next) {
            remaining -= current_mdl.?.ByteCount;
        }

        nb.NetBufferData.CurrentMdl = current_mdl;
        nb.NetBufferData.CurrentMdlOffset = remaining;
    }

    pool.allocated_count += 1;
    return nb;
}

/// 释放NET_BUFFER
pub fn NdisFreeNetBuffer(nb: *ndis.NET_BUFFER) void {
    const pool: *NetBufferPool = @ptrCast(nb.NetBufferData.NdisPoolHandle.?);
    std.debug.assert(pool.signature == 0x4E42504C);

    pool.allocator.destroy(nb);
    pool.allocated_count -= 1;
}

/// 创建NET_BUFFER_LIST池
pub fn NdisAllocateNetBufferListPool(
    allocator: std.mem.Allocator,
    pool_flags: c_ulong,
    context_size: c_ulong,
) NDIS_HANDLE {
    const pool = allocator.create(NetBufferListPool) catch return null;

    pool.* = .{
        .allocator = allocator,
        .pool_flags = pool_flags,
        .context_size = context_size,
    };

    return pool;
}

/// 销毁NET_BUFFER_LIST池
pub fn NdisFreeNetBufferListPool(pool_handle: NDIS_HANDLE) void {
    const pool: *NetBufferListPool = @ptrCast(pool_handle);
    std.debug.assert(pool.signature == 0x4E424C50);

    pool.allocator.destroy(pool);
}

/// 从池中分配NET_BUFFER_LIST
pub fn NdisAllocateNetBufferList(
    pool_handle: NDIS_HANDLE,
    nb: ?*ndis.NET_BUFFER,
    flags: c_ulong,
) ?*ndis.NET_BUFFER_LIST {
    const pool: *NetBufferListPool = @ptrCast(pool_handle);
    std.debug.assert(pool.signature == 0x4E424C50);

    const nbl = pool.allocator.create(ndis.NET_BUFFER_LIST) catch return null;

    nbl.* = std.mem.zeroInit(ndis.NET_BUFFER_LIST, .{});
    nbl.NetBufferListData.FirstNetBuffer = nb;
    nbl.NetBufferListData.NdisFlags = flags;
    nbl.NdisPoolHandle = pool_handle;

    pool.allocated_count += 1;
    return nbl;
}

/// 释放NET_BUFFER_LIST
pub fn NdisFreeNetBufferList(nbl: *ndis.NET_BUFFER_LIST) void {
    const pool: *NetBufferListPool = @ptrCast(nbl.NdisPoolHandle.?);
    std.debug.assert(pool.signature == 0x4E424C50);

    pool.allocator.destroy(nbl);
    pool.allocated_count -= 1;
}

/// 创建MDL描述一段内存
pub fn NdisAllocateMdl(
    virtual_address: *anyopaque,
    length: c_ulong,
) ?*ndis.MDL {
    const mdl = mm.allocateNonPagedPool(@sizeOf(ndis.MDL)) catch return null;

    mdl.* = std.mem.zeroInit(ndis.MDL, .{});
    mdl.StartVa = @alignCast(std.mem.alignBackward(@intFromPtr(virtual_address), std.mem.page_size));
    mdl.ByteOffset = @intFromPtr(virtual_address) - @intFromPtr(mdl.StartVa);
    mdl.ByteCount = length;
    mdl.Size = @sizeOf(ndis.MDL);
    mdl.MdlFlags = 0;

    return mdl;
}

/// 释放MDL
pub fn NdisFreeMdl(mdl: *ndis.MDL) void {
    mm.freeNonPagedPool(mdl);
}

/// 映射MDL到系统地址空间
pub fn NdisMMapMdl(mdl: *ndis.MDL, _priority: nt.MM_PAGE_PRIORITY) ?*anyopaque {
    _ = _priority;
    // 实现内存映射逻辑
    // 这里简化实现，直接返回虚拟地址
    mdl.MappedSystemVa = @as([*]u8, @ptrCast(mdl.StartVa)) + mdl.ByteOffset;
    return mdl.MappedSystemVa;
}

/// 取消MDL的系统地址空间映射
pub fn NdisMUnmapMdl(mdl: *ndis.MDL) void {
    mdl.MappedSystemVa = null;
}
