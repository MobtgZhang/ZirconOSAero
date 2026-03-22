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

fn netDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_NET_GET_STATUS => {
                    irp.bytes_transferred = if (link_up) 1 else 0;
                    irp.complete(.success, @sizeOf(u32));
                    return .success;
                },
                IOCTL_NET_GET_MAC => {
                    if (irp.buffer_size >= 6 and irp.buffer_ptr != 0) {
                        const dst: [*]u8 = @ptrFromInt(irp.buffer_ptr);
                        @memcpy(dst[0..6], stub_mac[0..6]);
                        irp.bytes_transferred = 6;
                        irp.complete(.success, 6);
                    } else {
                        irp.complete(.invalid_device, 0);
                    }
                    return .success;
                },
                else => {
                    irp.complete(.not_implemented, 0);
                    return .not_implemented;
                },
            }
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
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
