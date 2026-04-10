// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/rtl/klog.zig
// Purpose: 内核日志（参考 Linux printk）。
//
// 行格式（Linux dmesg 风格）：
//   `[seconds.microseconds] component: message`             — info/notice/debug/trace
//   `[seconds.microseconds] LEVEL: component: message`      — emerg/alert/crit/err/warning
//
// 时间戳：自启动后单调微秒（x86_64 优先 HPET，回退 PIT tick×10000us）。
// Release：仅输出 ERROR 及以上；`mouseDbg` 仍独立开关。

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");

const timekeeping = @import("../ke/timekeeping.zig");
const ringbuf = @import("klog_ringbuf.zig");

pub const LogLevel = enum(u8) {
    emerg = 0,
    alert = 1,
    crit = 2,
    err = 3,
    warning = 4,
    notice = 5,
    info = 6,
    debug = 7,
    trace = 8,
};

pub const TIMER_TICK_MS: u64 = 10;

pub const DEBUG_MODE: bool = @import("build_options").debug;

const RELEASE_MIN_LEVEL: LogLevel = .err;

/// Kept for backward compatibility — still 19, but no longer used for padding.
pub const COMPONENT_FIELD_WIDTH: usize = 19;

const LINE_BUF_SIZE: usize = 512;

/// Tick-based fallback microseconds; accumulated by `notifyTimerTick` in timer IRQ.
var log_elapsed_us: std.atomic.Value(u64) = .init(0);

pub fn notifyTimerTick() void {
    _ = log_elapsed_us.fetchAdd(TIMER_TICK_MS * 1000, .monotonic);
}

pub fn shouldLog(level: LogLevel) bool {
    if (DEBUG_MODE) return true;
    return @intFromEnum(level) <= @intFromEnum(RELEASE_MIN_LEVEL);
}

// ── Ticket spinlock ──────────────────────────────────────────────────
// 所有架构统一的 ticket spinlock 实现：
// - x86_64: 使用 pause 指令退让（Intel SDM 建议）
// - 其他架构: 使用通用退让提示（dbar/yield 等）

var ticket_next: std.atomic.Value(u32) = .init(0);
var ticket_owner: std.atomic.Value(u32) = .init(0);

fn ticketLock() void {
    const my = ticket_next.fetchAdd(1, .monotonic);
    while (ticket_owner.load(.acquire) != my) {
        arch.spinCpuRelax();
    }
}

fn ticketUnlock() void {
    _ = ticket_owner.fetchAdd(1, .release);
}

// ── Per-arch lock guard ───────────────────────────────────────────────
// freestanding 内核在所有支持的架构上都使用 ticket lock 保护日志输出
//（x86_64 用 pause、LoongArch64 用 dbar 0、AArch64 用 yield、退让）。

fn acquireLogLock() void {
    if (builtin.os.tag == .freestanding) {
        ticketLock();
    }
}

fn releaseLogLock() void {
    if (builtin.os.tag == .freestanding) {
        ticketUnlock();
    }
}

// ── Output ───────────────────────────────────────────────────────────

fn output(s: []const u8) void {
    arch.consoleWrite(s);
}

// ── Timestamp: boot-relative microseconds ────────────────────────────

fn getBootUs() u64 {
    return timekeeping.readBootElapsedUs();
}

fn writeSpacePaddedU64(buf: []u8, pos: *usize, width: usize, value: u64) void {
    var tmp: [20]u8 = undefined;
    var n = value;
    var len: usize = 0;
    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) : (n /= 10) {
            tmp[len] = @as(u8, @intCast('0' + (n % 10)));
            len += 1;
        }
    }
    if (len < width) {
        var pad = width - len;
        while (pad > 0) : (pad -= 1) {
            if (pos.* < buf.len) buf[pos.*] = ' ';
            pos.* +|= 1;
        }
    }
    var j: usize = len;
    while (j > 0) {
        j -= 1;
        if (pos.* < buf.len) buf[pos.*] = tmp[j];
        pos.* +|= 1;
    }
}

fn writeZeroPaddedU64(buf: []u8, pos: *usize, width: usize, value: u64) void {
    var tmp: [20]u8 = undefined;
    var n = value;
    var len: usize = 0;
    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) : (n /= 10) {
            tmp[len] = @as(u8, @intCast('0' + (n % 10)));
            len += 1;
        }
    }
    if (len < width) {
        var pad = width - len;
        while (pad > 0) : (pad -= 1) {
            if (pos.* < buf.len) buf[pos.*] = '0';
            pos.* +|= 1;
        }
    }
    var j: usize = len;
    while (j > 0) {
        j -= 1;
        if (pos.* < buf.len) buf[pos.*] = tmp[j];
        pos.* +|= 1;
    }
}

fn appendBytes(buf: []u8, pos: *usize, bytes: []const u8) void {
    for (bytes) |c| {
        if (pos.* < buf.len) buf[pos.*] = c;
        pos.* +|= 1;
    }
}

fn appendByte(buf: []u8, pos: *usize, c: u8) void {
    if (pos.* < buf.len) buf[pos.*] = c;
    pos.* +|= 1;
}

// ── Level display ────────────────────────────────────────────────────

fn levelPrefix(level: LogLevel) ?[]const u8 {
    return switch (level) {
        .emerg, .alert, .crit => "FATAL",
        .err => "ERROR",
        .warning => "WARN",
        .notice, .info, .debug, .trace => null,
    };
}

// ── Line prefix builder ──────────────────────────────────────────────
// Format: "[SSSSS.UUUUUU] component: " or "[SSSSS.UUUUUU] LEVEL: component: "

fn writeLogPrefix(buf: []u8, level: LogLevel, component: []const u8) usize {
    var pos: usize = 0;
    const us_total = getBootUs();
    const secs = us_total / 1_000_000;
    const us_frac = us_total % 1_000_000;

    appendByte(buf, &pos, '[');
    writeSpacePaddedU64(buf, &pos, 5, secs);
    appendByte(buf, &pos, '.');
    writeZeroPaddedU64(buf, &pos, 6, us_frac);
    appendBytes(buf, &pos, "] ");

    if (levelPrefix(level)) |lp| {
        appendBytes(buf, &pos, lp);
        appendBytes(buf, &pos, ": ");
    }

    appendBytes(buf, &pos, component);
    appendBytes(buf, &pos, ": ");
    return pos;
}

// ── Core emit (unified line buffer, single output call) ──────────────

fn klogEmit(level: LogLevel, component: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;

    acquireLogLock();
    defer releaseLogLock();

    var line_buf: [LINE_BUF_SIZE]u8 = undefined;
    var pos = writeLogPrefix(&line_buf, level, component);

    const msg = formatToBuf(line_buf[pos..], fmt, args);
    pos += msg.len;

    if (pos < line_buf.len) {
        line_buf[pos] = '\n';
        pos += 1;
    }

    const line = line_buf[0..@min(pos, line_buf.len)];
    ringbuf.push(level, line);
    output(line);
}

// ── Backward-compatible internal API: padded component → trimmed slice ──

fn trimPadded(padded: []const u8) []const u8 {
    var end: usize = padded.len;
    while (end > 0 and padded[end - 1] == ' ') end -= 1;
    return padded[0..end];
}

fn klogWithComponent(level: LogLevel, component: *const [COMPONENT_FIELD_WIDTH]u8, comptime fmt: []const u8, args: anytype) void {
    klogEmit(level, trimPadded(component), fmt, args);
}

// ── Compile-time component helper (still pads for type compat) ───────

fn padComponentComptime(comptime s: []const u8) [COMPONENT_FIELD_WIDTH]u8 {
    comptime {
        if (s.len > COMPONENT_FIELD_WIDTH) @compileError("klog scoped component max " ++ std.fmt.comptimePrint("{}", .{COMPONENT_FIELD_WIDTH}) ++ " bytes");
        var out: [COMPONENT_FIELD_WIDTH]u8 = .{' '} ** COMPONENT_FIELD_WIDTH;
        for (s, 0..) |c, i| out[i] = c;
        return out;
    }
}

const default_component = padComponentComptime("Kernel.Core");

pub fn klog(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    klogWithComponent(level, &default_component, fmt, args);
}

// ── Scoped logger ────────────────────────────────────────────────────

pub fn scoped(comptime label: []const u8) ScopedLogger(label) {
    return .{};
}

pub fn ScopedLogger(comptime label: []const u8) type {
    const padded = padComponentComptime(label);
    return struct {
        pub fn emerg(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.emerg, &padded, fmt, args);
        }
        pub fn alert(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.alert, &padded, fmt, args);
        }
        pub fn crit(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.crit, &padded, fmt, args);
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.err, &padded, fmt, args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.warning, &padded, fmt, args);
        }
        pub fn notice(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.notice, &padded, fmt, args);
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.info, &padded, fmt, args);
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.debug, &padded, fmt, args);
        }
        pub fn trace(comptime fmt: []const u8, args: anytype) void {
            klogWithComponent(.trace, &padded, fmt, args);
        }
    };
}

// ── Format engine ────────────────────────────────────────────────────
// Supports: %s %d %i %u %x %X %p %% and width/zero-pad: %Nd %0Nd %Nx %0Nx

fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const Args = @TypeOf(args);
    const args_info = @typeInfo(Args);
    if (args_info != .@"struct") return fmt;
    const fields = args_info.@"struct".fields;

    var pos: usize = 0;
    var arg_idx: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;

            if (fmt[i] == '%') {
                if (pos < buf.len) buf[pos] = '%';
                pos +|= 1;
                i += 1;
                continue;
            }

            var zero_pad = false;
            var width: usize = 0;

            if (fmt[i] == '0' and i + 1 < fmt.len and fmt[i + 1] >= '1' and fmt[i + 1] <= '9') {
                zero_pad = true;
                i += 1;
            }

            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                width = width * 10 + @as(usize, fmt[i] - '0');
                i += 1;
            }

            if (i >= fmt.len) break;

            if (arg_idx >= fields.len) {
                if (pos < buf.len) buf[pos] = fmt[i];
                pos +|= 1;
                i += 1;
                continue;
            }

            const spec = fmt[i];
            i += 1;

            if (spec == 's') {
                pos +|= formatArgStr(buf[pos..], args, fields, arg_idx, width);
            } else if (spec == 'p') {
                if (pos < buf.len) buf[pos] = '0';
                pos +|= 1;
                if (pos < buf.len) buf[pos] = 'x';
                pos +|= 1;
                pos +|= formatArgInt(buf[pos..], args, fields, arg_idx, 16, false, 0, false);
            } else {
                const base: u8 = if (spec == 'x' or spec == 'X') 16 else 10;
                const signed = (spec == 'd' or spec == 'i');
                pos +|= formatArgInt(buf[pos..], args, fields, arg_idx, base, signed, width, zero_pad);
            }
            arg_idx += 1;
        } else {
            if (pos < buf.len) buf[pos] = fmt[i];
            pos +|= 1;
            i += 1;
        }
    }
    return buf[0..@min(pos, buf.len)];
}

fn formatArgStr(buf: []u8, args: anytype, fields: anytype, arg_idx: usize, max_len: usize) usize {
    inline for (fields, 0..) |f, idx| {
        if (idx == arg_idx) {
            const arg = @field(args, f.name);
            if (@TypeOf(arg) == []const u8) {
                const limit = if (max_len > 0) @min(arg.len, max_len) else arg.len;
                var j: usize = 0;
                while (j < limit) : (j += 1) {
                    if (j < buf.len) buf[j] = arg[j];
                }
                return j;
            }
            return 0;
        }
    }
    return 0;
}

fn formatArgInt(buf: []u8, args: anytype, fields: anytype, arg_idx: usize, base: u8, signed: bool, width: usize, zero_pad: bool) usize {
    inline for (fields, 0..) |f, idx| {
        if (idx == arg_idx) {
            const arg = @field(args, f.name);
            return formatIntWidthPad(buf, arg, base, signed, width, zero_pad);
        }
    }
    return 0;
}

fn formatIntWidthPad(buf: []u8, value: anytype, base: u8, signed: bool, width: usize, zero_pad: bool) usize {
    const T = @TypeOf(value);
    if (T == []const u8) return 0;
    const type_info = @typeInfo(T);
    if (type_info != .int and type_info != .comptime_int) return 0;

    const digits = "0123456789abcdef";
    var start: usize = 0;
    var n: u64 = 0;
    var has_sign: bool = false;

    if (signed) {
        const v = @as(i64, @intCast(value));
        if (v < 0) {
            has_sign = true;
            n = @as(u64, @intCast(-v));
        } else {
            n = @as(u64, @intCast(v));
        }
    } else {
        n = @as(u64, @intCast(value));
    }

    var tmp: [32]u8 = undefined;
    var len: usize = 0;
    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        var nn = n;
        while (nn > 0) {
            tmp[len] = digits[nn % base];
            len += 1;
            nn /= base;
        }
    }

    const total_digits = len;
    const sign_len: usize = if (has_sign) 1 else 0;
    const content_len = sign_len + total_digits;

    if (width > content_len and !zero_pad) {
        // 空格填充：先填充空格，再写符号，最后写数字
        var pad = width - content_len;
        while (pad > 0) : (pad -= 1) {
            if (start < buf.len) buf[start] = ' ';
            start += 1;
        }
        if (has_sign) {
            if (start < buf.len) buf[start] = '-';
            start += 1;
        }
    } else if (width > content_len and zero_pad) {
        // 零填充：先写符号，再填充零，最后写数字
        if (has_sign) {
            if (start < buf.len) buf[start] = '-';
            start += 1;
        }
        var pad = width - content_len;
        while (pad > 0) : (pad -= 1) {
            if (start < buf.len) buf[start] = '0';
            start += 1;
        }
    } else if (has_sign) {
        // 宽度不够或零填充但无额外填充：直接写符号
        if (start < buf.len) buf[start] = '-';
        start += 1;
    }

    var j: usize = len;
    while (j > 0) {
        j -= 1;
        if (start < buf.len) buf[start] = tmp[j];
        start += 1;
    }
    return start;
}

// ── Mouse debug ──────────────────────────────────────────────────────

const mouse_component = padComponentComptime("Input.MouseDbg");

pub fn mouseDbg(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build_options").mouse_debug) return;
    acquireLogLock();
    defer releaseLogLock();
    var line_buf: [LINE_BUF_SIZE]u8 = undefined;
    var pos = writeLogPrefix(&line_buf, .debug, trimPadded(&mouse_component));

    appendBytes(&line_buf, &pos, "MOUSEDBG ");

    const msg = formatToBuf(line_buf[pos..], fmt, args);
    pos += msg.len;

    if (pos < line_buf.len) {
        line_buf[pos] = '\n';
        pos += 1;
    }

    const line = line_buf[0..@min(pos, line_buf.len)];
    ringbuf.push(.debug, line);
    output(line);
}

// ── Top-level convenience wrappers ───────────────────────────────────

pub fn emerg(comptime fmt: []const u8, args: anytype) void {
    klog(.emerg, fmt, args);
}
pub fn alert(comptime fmt: []const u8, args: anytype) void {
    klog(.alert, fmt, args);
}
pub fn crit(comptime fmt: []const u8, args: anytype) void {
    klog(.crit, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    klog(.err, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    klog(.warning, fmt, args);
}
pub fn notice(comptime fmt: []const u8, args: anytype) void {
    klog(.notice, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    klog(.info, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    klog(.debug, fmt, args);
}
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    klog(.trace, fmt, args);
}
