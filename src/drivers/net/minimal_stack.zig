// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/net/minimal_stack.zig
// Purpose: IPv4/UDP 网络栈占位（路线图见 docs/cn/HAL_USB_NET_ROADMAP.md）。
//
// This is an independent clean-room implementation.

/// IPv4 地址（主机字节序占位；真实实现须明确 endian 策略）。
pub const Ipv4Addr = u32;

pub const NetStackPhase = enum { not_started, planned, arp_udp };

pub fn phase() NetStackPhase {
    return .planned;
}

pub fn ipv4Unspecified() Ipv4Addr {
    return 0;
}
