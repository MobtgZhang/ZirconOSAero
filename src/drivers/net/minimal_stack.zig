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

/// 计算网络数据校验和（RFC 1071），适用于IP/ICMP/TCP/UDP等
pub fn calculateChecksum(data: []const u8, initial: u16) u16 {
    var sum: u32 = initial;
    var i: usize = 0;

    while (i < data.len - 1) : (i += 2) {
        const word = std.mem.readInt(u16, data[i .. i + 2], .big);
        sum += word;
    }

    // 处理奇数字节
    if (i < data.len) {
        const last_byte = data[i];
        sum += @as(u16, last_byte) << 8;
    }

    // 折叠进位到16位
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~@as(u16, @truncate(sum));
}

/// ICMP Echo 请求/应答完整结构
pub const IcmpEchoMessage = struct {
    header: IcmpHeader,
    identifier: u16,
    sequence: u16,
    data: []const u8,
};

/// 构建ICMP Echo Request（ping请求）数据包
pub fn buildIcmpEchoRequest(identifier: u16, sequence: u16, data: []const u8, out_buffer: []u8) ?usize {
    const total_len = 8 + data.len;
    if (out_buffer.len < total_len) return null;

    // 填写ICMP头部
    out_buffer[0] = ICMP_ECHO_REQUEST;
    out_buffer[1] = 0; // code 0 for echo
    std.mem.writeInt(u16, out_buffer[2..4], 0, .big); // 校验和先填0
    std.mem.writeInt(u16, out_buffer[4..6], identifier, .big);
    std.mem.writeInt(u16, out_buffer[6..8], sequence, .big);

    // 复制数据
    @memcpy(out_buffer[8 .. 8 + data.len], data);

    // 计算校验和
    const checksum = calculateChecksum(out_buffer[0..total_len], 0);
    std.mem.writeInt(u16, out_buffer[2..4], checksum, .big);

    return total_len;
}

/// 解析ICMP Echo Reply消息
pub fn parseIcmpEchoReply(bytes: []const u8) ?IcmpEchoMessage {
    if (bytes.len < 8) return null;

    const header = parseIcmpHeader(bytes) orelse return null;
    if (header.icmp_type != ICMP_ECHO_REPLY or header.code != 0) return null;

    const identifier = std.mem.readInt(u16, bytes[4..6], .big);
    const sequence = std.mem.readInt(u16, bytes[6..8], .big);

    return .{
        .header = header,
        .identifier = identifier,
        .sequence = sequence,
        .data = bytes[8..],
    };
}

/// 验证ICMP数据包校验和是否正确
pub fn validateIcmpChecksum(icmp_packet: []const u8) bool {
    if (icmp_packet.len < 4) return false;
    return calculateChecksum(icmp_packet, 0) == 0;
}

/// RFC 793 TCP 首部（20字节固定头）
pub const TcpHeader = struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset: u4,
    reserved: u6,
    flags: u8,
    window_size: u16,
    checksum: u16,
    urgent_pointer: u16,
};

/// TCP 标志位定义
pub const TCP_FLAG_FIN: u8 = 0x01;
pub const TCP_FLAG_SYN: u8 = 0x02;
pub const TCP_FLAG_RST: u8 = 0x04;
pub const TCP_FLAG_PSH: u8 = 0x08;
pub const TCP_FLAG_ACK: u8 = 0x10;
pub const TCP_FLAG_URG: u8 = 0x20;

/// 解析TCP首部
pub fn parseTcpHeader(bytes: []const u8) ?TcpHeader {
    if (bytes.len < 20) return null;

    const data_offset_reserved = bytes[12];
    const data_offset = @as(u4, @truncate(data_offset_reserved >> 4));

    if (data_offset < 5) return null; // TCP首部至少20字节（5*4）

    return .{
        .src_port = std.mem.readInt(u16, bytes[0..2], .big),
        .dst_port = std.mem.readInt(u16, bytes[2..4], .big),
        .seq_num = std.mem.readInt(u32, bytes[4..8], .big),
        .ack_num = std.mem.readInt(u32, bytes[8..12], .big),
        .data_offset = data_offset,
        .reserved = @as(u6, @truncate(data_offset_reserved & 0x0F)),
        .flags = bytes[13],
        .window_size = std.mem.readInt(u16, bytes[14..16], .big),
        .checksum = std.mem.readInt(u16, bytes[16..18], .big),
        .urgent_pointer = std.mem.readInt(u16, bytes[18..20], .big),
    };
}

/// TCP伪首部，用于计算TCP校验和
pub const TcpPseudoHeader = struct {
    src_ip: u32,
    dst_ip: u32,
    zero: u8,
    protocol: u8,
    tcp_length: u16,
};

/// 计算TCP校验和
pub fn calculateTcpChecksum(src_ip: u32, dst_ip: u32, tcp_segment: []const u8) u16 {
    var pseudo = TcpPseudoHeader{
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .zero = 0,
        .protocol = IPPROTO_TCP,
        .tcp_length = std.mem.nativeToBig(u16, @as(u16, @truncate(tcp_segment.len))),
    };

    var sum: u32 = 0;

    // 计算伪首部校验和
    const pseudo_bytes = std.mem.asBytes(&pseudo);
    var i: usize = 0;
    while (i < pseudo_bytes.len) : (i += 2) {
        const word = std.mem.readInt(u16, pseudo_bytes[i .. i + 2], .big);
        sum += word;
    }

    // 计算TCP段校验和
    return calculateChecksum(tcp_segment, @as(u16, @truncate(sum & 0xFFFF)));
}

/// 构建TCP SYN报文（连接请求）
pub fn buildTcpSynPacket(src_port: u16, dst_port: u16, seq_num: u32, window_size: u16, src_ip: u32, dst_ip: u32, out_buffer: []u8) ?usize {
    if (out_buffer.len < 20) return null;

    // 填写TCP头部
    std.mem.writeInt(u16, out_buffer[0..2], src_port, .big);
    std.mem.writeInt(u16, out_buffer[2..4], dst_port, .big);
    std.mem.writeInt(u32, out_buffer[4..8], seq_num, .big);
    std.mem.writeInt(u32, out_buffer[8..12], 0, .big); // ACK号为0
    out_buffer[12] = 0x50; // 数据偏移5*4=20字节，保留位0
    out_buffer[13] = TCP_FLAG_SYN; // SYN标志位
    std.mem.writeInt(u16, out_buffer[14..16], window_size, .big);
    std.mem.writeInt(u16, out_buffer[16..18], 0, .big); // 校验和先填0
    std.mem.writeInt(u16, out_buffer[18..20], 0, .big); // 紧急指针

    // 计算校验和
    const checksum = calculateTcpChecksum(src_ip, dst_ip, out_buffer[0..20]);
    std.mem.writeInt(u16, out_buffer[16..18], checksum, .big);

    return 20;
}

/// 验证TCP SYN-ACK应答，判断连接是否成功建立
pub fn isTcpSynAck(tcp_header: TcpHeader, expected_ack_num: u32) bool {
    return (tcp_header.flags & (TCP_FLAG_SYN | TCP_FLAG_ACK)) == (TCP_FLAG_SYN | TCP_FLAG_ACK) and
        tcp_header.ack_num == expected_ack_num;
}

pub fn parseUdpHeader(bytes: []const u8) ?UdpHeader {
    if (bytes.len < 8) return null;
    return .{
        .src_port = std.mem.readInt(u16, bytes[0..2], .big),
        .dst_port = std.mem.readInt(u16, bytes[2..4], .big),
        .length = std.mem.readInt(u16, bytes[4..6], .big),
        .checksum = std.mem.readInt(u16, bytes[6..8], .big),
    };
}

/// 以太网 II（无 802.1Q）：按 `EtherType` 分流 ARP / IPv4，供 VirtIO-Net 收包与 H4b 自测。
pub const EthernetInspectKind = enum { unknown, arp, ipv4 };

pub fn inspectEthernet8023Frame(frame: []const u8) EthernetInspectKind {
    if (frame.len < 14) return .unknown;
    const et = std.mem.readInt(u16, frame[12..14], .big);
    if (et == 0x0806) {
        if (parseArpHeaderFixed(frame[14..])) |_| return .arp;
        return .unknown;
    }
    if (et == 0x0800) {
        if (parseIpv4Header(frame[14..])) |_| return .ipv4;
        return .unknown;
    }
    return .unknown;
}

/// H4b：无硬件时的栈解析烟测（ARP 与 IPv4 固定头）。
pub fn virtioNetStackSmokeSelfTest() bool {
    var eth: [42]u8 = undefined;
    @memset(&eth, 0);
    eth[12] = 0x08;
    eth[13] = 0x06;
    var arp: [8]u8 = undefined;
    std.mem.writeInt(u16, arp[0..2], 1, .big);
    std.mem.writeInt(u16, arp[2..4], 0x0800, .big);
    arp[4] = 6;
    arp[5] = 4;
    std.mem.writeInt(u16, arp[6..8], ARP_OP_REQUEST, .big);
    @memcpy(eth[14..22], &arp);
    if (inspectEthernet8023Frame(&eth) != .arp) return false;

    @memset(&eth, 0);
    eth[12] = 0x08;
    eth[13] = 0x00;
    var ip: [20]u8 = [_]u8{0} ** 20;
    ip[0] = 0x45;
    ip[8] = 64;
    ip[9] = IPPROTO_UDP;
    std.mem.writeInt(u16, ip[2..4], 20, .big);
    std.mem.writeInt(u32, ip[12..16], 0x0a000001, .big);
    std.mem.writeInt(u32, ip[16..20], 0x0a000002, .big);
    @memcpy(eth[14..34], &ip);
    return inspectEthernet8023Frame(&eth) == .ipv4;
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

test "inspectEthernet8023Frame arp and ipv4" {
    try std.testing.expect(virtioNetStackSmokeSelfTest());
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
