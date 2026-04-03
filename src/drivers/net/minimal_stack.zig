// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/net/minimal_stack.zig
// Purpose: IPv4/UDP 网络栈占位与首部解析子集（路线图见 docs/cn/HAL_USB_NET_ROADMAP.md）。
//
// This is an independent clean-room implementation.
// Reference: RFC 791 (IPv4 header); endian — 线上为小端字段按规范网络字节序。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K5.3

const std = @import("std");

/// IPv4 地址（网络字节序 / big-endian 整数，与线上 `s_addr` 一致）。
pub const Ipv4Addr = u32;

pub const NetStackPhase = enum { not_started, planned, arp_udp };

pub fn phase() NetStackPhase {
    return .arp_udp;
}

/// H4：VirtIO-Net 已枚举时登记与 `parseIpv4Header` / ARP 子集接线的占位（环驱动就绪后填回调）。
pub fn noteVirtioNetPciEnumerated(count: usize) void {
    _ = count;
}

/// RFC 826 ARP 以太网帧内操作码（线上 big-endian）。
pub const ARP_OP_REQUEST: u16 = 1;
pub const ARP_OP_REPLY: u16 = 2;

/// ARP 固定首部 8 字节（不含硬件/协议地址可变尾部）；多字字段为 **已从线上解码** 的主机值。
pub const ArpHeaderFixed = struct {
    hardware_type: u16,
    protocol_type: u16,
    hardware_len: u8,
    protocol_len: u8,
    operation: u16,
};

/// 解析 ARP 前 8 字节；以太网 IPv4 常见 `hw=1 eth, proto=0x0800, hw_len=6, proto_len=4`。
pub fn parseArpHeaderFixed(bytes: []const u8) ?ArpHeaderFixed {
    if (bytes.len < 8) return null;
    return .{
        .hardware_type = std.mem.readInt(u16, bytes[0..2], .big),
        .protocol_type = std.mem.readInt(u16, bytes[2..4], .big),
        .hardware_len = bytes[4],
        .protocol_len = bytes[5],
        .operation = std.mem.readInt(u16, bytes[6..8], .big),
    };
}

pub fn ipv4Unspecified() Ipv4Addr {
    return 0;
}

/// RFC 791 IPv4 首部（20 字节固定头）；多字节字段在结构体中存为 **已从线上 big-endian 解码** 的主机值。
pub const Ipv4Header = struct {
    version_ihl: u8,
    tos: u8,
    total_length: u16,
    id: u16,
    flags_frag: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src: Ipv4Addr,
    dst: Ipv4Addr,
};

/// 自缓冲区解析 IPv4 首部；`version` 须为 4 且 `ihl` 至少 5（无选项）。
pub fn parseIpv4Header(bytes: []const u8) ?Ipv4Header {
    if (bytes.len < 20) return null;
    const ver_ihl = bytes[0];
    const ver = ver_ihl >> 4;
    const ihl = ver_ihl & 0x0f;
    if (ver != 4 or ihl < 5) return null;
    // 仅支持 20 字节固定头（IHL=5）；带选项的首部为后续里程碑。
    if (ihl != 5) return null;
    const need = @as(usize, ihl) * 4;
    if (bytes.len < need) return null;
    return .{
        .version_ihl = ver_ihl,
        .tos = bytes[1],
        .total_length = std.mem.readInt(u16, bytes[2..4], .big),
        .id = std.mem.readInt(u16, bytes[4..6], .big),
        .flags_frag = std.mem.readInt(u16, bytes[6..8], .big),
        .ttl = bytes[8],
        .protocol = bytes[9],
        .checksum = std.mem.readInt(u16, bytes[10..12], .big),
        .src = std.mem.readInt(u32, bytes[12..16], .big),
        .dst = std.mem.readInt(u32, bytes[16..20], .big),
    };
}

/// IP 协议号子集（IANA）。
pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_TCP: u8 = 6;
pub const IPPROTO_UDP: u8 = 17;

/// RFC 792 ICMP 首部前 4 字节；`checksum` 为线上 big-endian。
pub const IcmpHeader = struct {
    icmp_type: u8,
    code: u8,
    checksum: u16,
};

pub const ICMP_ECHO_REPLY: u8 = 0;
pub const ICMP_ECHO_REQUEST: u8 = 8;

pub fn parseIcmpHeader(bytes: []const u8) ?IcmpHeader {
    if (bytes.len < 4) return null;
    return .{
        .icmp_type = bytes[0],
        .code = bytes[1],
        .checksum = std.mem.readInt(u16, bytes[2..4], .big),
    };
}

/// RFC 768 UDP 首部；端口与长度、校验和为 **big-endian** 解码后的主机值。
pub const UdpHeader = struct {
    src_port: u16,
    dst_port: u16,
    length: u16,
    checksum: u16,
};

pub fn parseUdpHeader(bytes: []const u8) ?UdpHeader {
    if (bytes.len < 8) return null;
    return .{
        .src_port = std.mem.readInt(u16, bytes[0..2], .big),
        .dst_port = std.mem.readInt(u16, bytes[2..4], .big),
        .length = std.mem.readInt(u16, bytes[4..6], .big),
        .checksum = std.mem.readInt(u16, bytes[6..8], .big),
    };
}

test "parseIpv4Header rejects IHL greater than 5 (options not implemented)" {
    var wire: [20]u8 = [_]u8{0} ** 20;
    wire[0] = 0x46; // version 4, IHL 6 — 解析器仅接受 IHL=5
    try std.testing.expect(parseIpv4Header(&wire) == null);
}

test "parseArpHeaderFixed decodes Ethernet/IPv4 style preamble" {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u16, b[0..2], 1, .big);
    std.mem.writeInt(u16, b[2..4], 0x0800, .big);
    b[4] = 6;
    b[5] = 4;
    std.mem.writeInt(u16, b[6..8], ARP_OP_REQUEST, .big);
    const a = parseArpHeaderFixed(&b) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u16, 1), a.hardware_type);
    try std.testing.expectEqual(@as(u16, 0x0800), a.protocol_type);
    try std.testing.expectEqual(ARP_OP_REQUEST, a.operation);
}

test "parseIpv4Header decodes RFC791 fixed header (big-endian fields)" {
    var wire: [20]u8 = [_]u8{0} ** 20;
    wire[0] = 0x45; // version 4, IHL 5
    wire[1] = 0;
    std.mem.writeInt(u16, wire[2..4], 28, .big); // total length
    std.mem.writeInt(u16, wire[4..6], 0x1234, .big);
    std.mem.writeInt(u16, wire[6..8], 0, .big);
    wire[8] = 64;
    wire[9] = IPPROTO_UDP;
    std.mem.writeInt(u16, wire[10..12], 0, .big);
    std.mem.writeInt(u32, wire[12..16], 0x0a000001, .big); // 10.0.0.1
    std.mem.writeInt(u32, wire[16..20], 0x0a000002, .big); // 10.0.0.2
    const h = parseIpv4Header(&wire) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 0x45), h.version_ihl);
    try std.testing.expectEqual(@as(u16, 28), h.total_length);
    try std.testing.expectEqual(IPPROTO_UDP, h.protocol);
    try std.testing.expectEqual(@as(u32, 0x0a000001), h.src);
    try std.testing.expectEqual(@as(u32, 0x0a000002), h.dst);
}

test "parseIcmpHeader echo request" {
    var b: [4]u8 = undefined;
    b[0] = ICMP_ECHO_REQUEST;
    b[1] = 0;
    std.mem.writeInt(u16, b[2..4], 0xABCD, .big);
    const ic = parseIcmpHeader(&b) orelse return error.Bad;
    try std.testing.expectEqual(ICMP_ECHO_REQUEST, ic.icmp_type);
    try std.testing.expectEqual(@as(u16, 0xABCD), ic.checksum);
}

test "parseUdpHeader ports and length" {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u16, b[0..2], 12345, .big);
    std.mem.writeInt(u16, b[2..4], 53, .big);
    std.mem.writeInt(u16, b[4..6], 16, .big);
    std.mem.writeInt(u16, b[6..8], 0, .big);
    const u = parseUdpHeader(&b) orelse return error.Bad;
    try std.testing.expectEqual(@as(u16, 12345), u.src_port);
    try std.testing.expectEqual(@as(u16, 53), u.dst_port);
    try std.testing.expectEqual(@as(u16, 16), u.length);
}
