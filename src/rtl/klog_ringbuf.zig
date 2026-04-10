// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/rtl/klog_ringbuf.zig
// Purpose: 内核日志环形缓冲区（参考 Linux printk log_buf），供后续 dmesg / IOCTL_KLOG_READ 使用。
//
// This is an independent clean-room implementation.

const std = @import("std");
const klog_mod = @import("klog.zig");

pub const RING_SIZE: usize = 128 * 1024;

pub const LogEntry = packed struct {
    timestamp_us: u64,
    level: u8,
    text_len: u16,
};

const ENTRY_HDR_SIZE: usize = @sizeOf(LogEntry);

var ring: [RING_SIZE]u8 = .{0} ** RING_SIZE;
var write_pos: usize = 0;
var entry_count: u64 = 0;
/// 溢出标志：环形缓冲区被覆盖时置 true，直到被查询并清除
var overflow_flag: bool = false;

fn wrapCopy(dst_pos: usize, src: []const u8) usize {
    const end_pos = dst_pos + src.len;
    // 检测溢出：当写指针加上数据长度超过 RING_SIZE 时发生
    if (end_pos >= RING_SIZE) {
        overflow_flag = true;
    }
    var pos = dst_pos % RING_SIZE;
    for (src) |b| {
        ring[pos] = b;
        pos = (pos + 1) % RING_SIZE;
    }
    return (dst_pos + src.len) % RING_SIZE;
}

/// 检查并清除溢出标志（原子操作）
/// 返回 true 表示自上次调用以来发生了溢出
pub fn checkAndClearOverflow() bool {
    const prev = overflow_flag;
    overflow_flag = false;
    return prev;
}

/// 查询溢出标志（不修改）
pub fn hasOverflowed() bool {
    return overflow_flag;
}

pub fn push(level: klog_mod.LogLevel, text: []const u8) void {
    const ts = @import("../ke/timekeeping.zig").readBootElapsedUs();
    const tlen: u16 = @intCast(@min(text.len, @as(usize, std.math.maxInt(u16))));

    const hdr = LogEntry{
        .timestamp_us = ts,
        .level = @intFromEnum(level),
        .text_len = tlen,
    };

    const hdr_bytes = std.mem.asBytes(&hdr);
    var pos = write_pos;
    pos = wrapCopy(pos, hdr_bytes);
    pos = wrapCopy(pos, text[0..tlen]);
    write_pos = pos;
    entry_count +%= 1;
}

pub fn getEntryCount() u64 {
    return entry_count;
}

pub fn getWritePos() usize {
    return write_pos;
}

pub fn getRingSlice() []const u8 {
    return &ring;
}
