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
//! NDIS 6.20 类型定义
//! 基于微软公开NDIS 6.20技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt/nt_types.zig");

/// NDIS版本定义
pub const NDIS_MAJOR_VERSION = 6;
pub const NDIS_MINOR_VERSION = 20;
pub const NDIS_VERSION = (NDIS_MAJOR_VERSION << 16) | NDIS_MINOR_VERSION;

/// NDIS状态码
pub const NDIS_STATUS = nt.NTSTATUS;
pub const NDIS_STATUS_SUCCESS = NDIS_STATUS.STATUS_SUCCESS;
pub const NDIS_STATUS_PENDING = NDIS_STATUS.STATUS_PENDING;
pub const NDIS_STATUS_BUFFER_OVERFLOW = NDIS_STATUS.STATUS_BUFFER_OVERFLOW;
pub const NDIS_STATUS_INSUFFICIENT_RESOURCES = NDIS_STATUS.STATUS_INSUFFICIENT_RESOURCES;
pub const NDIS_STATUS_INVALID_PARAMETER = NDIS_STATUS.STATUS_INVALID_PARAMETER;
pub const NDIS_STATUS_NOT_SUPPORTED = NDIS_STATUS.STATUS_NOT_SUPPORTED;

/// MDL (Memory Descriptor List) 结构
pub const MDL = extern struct {
    Next: ?*MDL,
    Size: c_ushort,
    MdlFlags: c_ushort,
    Process: ?*nt.EPROCESS,
    MappedSystemVa: ?*anyopaque,
    StartVa: ?*anyopaque,
    ByteCount: c_ulong,
    ByteOffset: c_ulong,
};

/// NET_BUFFER_DATA结构 - NET_BUFFER的私有数据部分
pub const NET_BUFFER_DATA = extern struct {
    Next: ?*NET_BUFFER,
    CurrentMdl: ?*MDL,
    CurrentMdlOffset: c_ulong,
    MdlChain: ?*MDL,
    DataLength: c_ulong,
    DataOffset: c_ulong,
    /// 补充字段，对齐到NDIS 6.20规范
    NdisPoolHandle: ?*anyopaque,
    NdisFlags: c_ulong,
};

/// NET_BUFFER结构 - 单个网络数据包缓冲区
pub const NET_BUFFER = extern struct {
    NetBufferData: NET_BUFFER_DATA,
    /// 协议驱动保留字段
    ProtocolReserved: [4]usize,
    /// Miniport驱动保留字段
    MiniportReserved: [4]usize,
    /// 为上层应用保留的扩展空间
    Scratch: ?*anyopaque,

    /// 获取当前数据的虚拟地址
    pub fn getCurrentVa(self: *NET_BUFFER) ?*u8 {
        if (self.NetBufferData.CurrentMdl == null) return null;
        const mdl = self.NetBufferData.CurrentMdl.?;
        return @ptrCast(@as([*]u8, @ptrCast(mdl.MappedSystemVa)) + mdl.ByteOffset + self.NetBufferData.CurrentMdlOffset);
    }

    /// 获取整个NET_BUFFER的总数据长度
    pub fn getTotalLength(self: *NET_BUFFER) c_ulong {
        return self.NetBufferData.DataLength;
    }

    /// 调整数据偏移量，跳过指定字节数
    pub fn advance(self: *NET_BUFFER, bytes: c_ulong) NDIS_STATUS {
        if (bytes > self.NetBufferData.DataLength) {
            return NDIS_STATUS_INVALID_PARAMETER;
        }

        const current_offset = self.NetBufferData.DataOffset + bytes;
        var mdl = self.NetBufferData.MdlChain;
        var remaining = current_offset;

        while (mdl != null and remaining > mdl.?.ByteCount) : (mdl = mdl.?.Next) {
            remaining -= mdl.?.ByteCount;
        }

        if (mdl == null) {
            return NDIS_STATUS_INVALID_PARAMETER;
        }

        self.NetBufferData.CurrentMdl = mdl;
        self.NetBufferData.CurrentMdlOffset = remaining;
        self.NetBufferData.DataOffset = current_offset;
        self.NetBufferData.DataLength -= bytes;

        return NDIS_STATUS_SUCCESS;
    }

    /// 回退数据偏移量，恢复指定字节数
    pub fn retreat(self: *NET_BUFFER, bytes: c_ulong) NDIS_STATUS {
        var current_offset = self.NetBufferData.DataOffset;
        if (bytes > current_offset) {
            return NDIS_STATUS_INVALID_PARAMETER;
        }

        current_offset -= bytes;
        var mdl = self.NetBufferData.MdlChain;
        var remaining = current_offset;

        while (mdl != null and remaining > mdl.?.ByteCount) : (mdl = mdl.?.Next) {
            remaining -= mdl.?.ByteCount;
        }

        if (mdl == null) {
            return NDIS_STATUS_INVALID_PARAMETER;
        }

        self.NetBufferData.CurrentMdl = mdl;
        self.NetBufferData.CurrentMdlOffset = remaining;
        self.NetBufferData.DataOffset = current_offset;
        self.NetBufferData.DataLength += bytes;

        return NDIS_STATUS_SUCCESS;
    }
};

/// NET_BUFFER_LIST_DATA结构 - NET_BUFFER_LIST的私有数据部分
pub const NET_BUFFER_LIST_DATA = extern struct {
    Next: ?*NET_BUFFER_LIST,
    FirstNetBuffer: ?*NET_BUFFER,
    /// 数据包源端口
    SourcePort: c_ushort,
    /// 数据包目的端口
    DestinationPort: c_ushort,
    /// NDIS处理标志
    NdisFlags: c_ulong,
    /// 数据包状态
    Status: NDIS_STATUS,
};

/// NET_BUFFER_LIST结构 - 网络数据包链表，用于批量处理多个数据包
pub const NET_BUFFER_LIST = extern struct {
    NetBufferListData: NET_BUFFER_LIST_DATA,
    /// 协议驱动保留字段
    ProtocolReserved: [4]usize,
    /// Miniport驱动保留字段
    MiniportReserved: [4]usize,
    /// 父NET_BUFFER_LIST (用于克隆场景)
    ParentNetBufferList: ?*NET_BUFFER_LIST,
    /// NDIS池句柄
    NdisPoolHandle: ?*anyopaque,
    /// 扩展数据指针
    NdisExtensionData: ?*anyopaque,

    /// 获取第一个NET_BUFFER
    pub fn getFirstNetBuffer(self: *NET_BUFFER_LIST) ?*NET_BUFFER {
        return self.NetBufferListData.FirstNetBuffer;
    }

    /// 获取下一个NET_BUFFER_LIST
    pub fn getNext(self: *NET_BUFFER_LIST) ?*NET_BUFFER_LIST {
        return self.NetBufferListData.Next;
    }

    /// 添加NET_BUFFER到列表头部
    pub fn prependNetBuffer(self: *NET_BUFFER_LIST, nb: *NET_BUFFER) void {
        nb.NetBufferData.Next = self.NetBufferListData.FirstNetBuffer;
        self.NetBufferListData.FirstNetBuffer = nb;
    }

    /// 添加NET_BUFFER到列表尾部
    pub fn appendNetBuffer(self: *NET_BUFFER_LIST, nb: *NET_BUFFER) void {
        if (self.NetBufferListData.FirstNetBuffer == null) {
            self.NetBufferListData.FirstNetBuffer = nb;
            nb.NetBufferData.Next = null;
            return;
        }

        var current = self.NetBufferListData.FirstNetBuffer;
        while (current.?.NetBufferData.Next != null) : (current = current.?.NetBufferData.Next) {}
        current.?.NetBufferData.Next = nb;
        nb.NetBufferData.Next = null;
    }

    /// 计算链表中所有NET_BUFFER的总字节数
    pub fn getTotalLength(self: *NET_BUFFER_LIST) c_ulong {
        var total: c_ulong = 0;
        var nb = self.NetBufferListData.FirstNetBuffer;
        while (nb != null) : (nb = nb.?.NetBufferData.Next) {
            total += nb.?.getTotalLength();
        }
        return total;
    }
};

/// NDIS处理上下文标志
pub const NDIS_NBL_FLAGS_RECEIVE: c_ulong = 0x00000001;
pub const NDIS_NBL_FLAGS_SEND: c_ulong = 0x00000002;
pub const NDIS_NBL_FLAGS_LOOPBACK: c_ulong = 0x00000004;
pub const NDIS_NBL_FLAGS_MULTICAST: c_ulong = 0x00000008;
pub const NDIS_NBL_FLAGS_BROADCAST: c_ulong = 0x00000010;
