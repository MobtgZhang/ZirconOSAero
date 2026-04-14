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

//! 网络微型端口（NDIS 风格桩）：注册 `\Driver\NdisMiniport` / `\Device\TCP`，
//! 为上层提供 IOCTL 查询链路状态与模拟 MAC。完整收发需 PCI/virtio/MMIO 后续接入。

const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

pub const IOCTL_NET_GET_STATUS: u32 = 0x00120000;
pub const IOCTL_NET_GET_MAC: u32 = 0x00120004;

/// 模拟以太网 MAC（本地管理地址前缀）
const stub_mac: [6]u8 = .{ 0x02, 0x00, 0x5A, 0x00, 0x00, 0x01 };

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
var link_up: bool = true;

fn netDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_NET_GET_STATUS => {
                    irp.bytes_transferred = if (link_up) 1 else 0;
                    irp.complete(io.STATUS_SUCCESS, @sizeOf(u32));
                    return io.STATUS_SUCCESS;
                },
                IOCTL_NET_GET_MAC => {
                    if (irp.buffer_size >= 6 and irp.buffer_ptr != 0) {
                        const dst: [*]u8 = @ptrFromInt(irp.buffer_ptr);
                        @memcpy(dst[0..6], stub_mac[0..6]);
                        irp.bytes_transferred = 6;
                        irp.complete(io.STATUS_SUCCESS, 6);
                    } else {
                        irp.complete(io.STATUS_INVALID_PARAMETER, 0);
                    }
                    return io.STATUS_SUCCESS;
                },
                else => {
                    irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
                    return io.STATUS_NOT_IMPLEMENTED;
                },
            }
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

pub fn init() void {
    driver_idx = io.registerDriver("\\Driver\\NdisMiniport", netDispatch) orelse {
        klog.err("NET: Failed to register miniport driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\TCP", .network, driver_idx) orelse {
        klog.err("NET: Failed to create \\Device\\TCP", .{});
        return;
    };

    driver_initialized = true;
    klog.info("NET: NDIS miniport stub (\\Device\\TCP, IOCTL status/MAC)", .{});
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn isLinkUp() bool {
    return link_up;
}
