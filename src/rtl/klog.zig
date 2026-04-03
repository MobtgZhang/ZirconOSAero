// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/rtl/klog.zig
// Purpose: 内核串口/VGA 日志；行格式 `[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Component...] 消息`。
//
// 时间：x86_64 读 CMOS 日历与时分秒（见 hal/x86_64/rtc_cmos.zig）；毫秒低位来自 `notifyTimerTick` 累加的单调毫秒（与 RTC 秒边界不对齐，仅用于区分同秒多行）。
// Release：仅输出 ERROR 及以上（与历史 KERN_ERR 一致）；`mouseDbg` 仍独立开关。

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");

const rtc_cmos = @import("../hal/x86_64/rtc_cmos.zig");

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

/// PIT/定时器 IRQ 约 100Hz 时每 tick 增加毫秒数（与 `main` 启动日志一致）。
pub const TIMER_TICK_MS: u64 = 10;

pub const DEBUG_MODE: bool = @import("build_options").debug;

const RELEASE_MIN_LEVEL: LogLevel = .err;

/// 组件名字段宽度（与 Shell.Taskbar / DWM.Compositor 示例一致）。
pub const COMPONENT_FIELD_WIDTH: usize = 19;

/// 单调毫秒（供时间戳后缀）；由 `notifyTimerTick` 在 timer IRQ 中累加。
var log_elapsed_ms: std.atomic.Value(u64) = .init(0);

pub fn notifyTimerTick() void {
    _ = log_elapsed_ms.fetchAdd(TIMER_TICK_MS, .monotonic);
}

pub fn shouldLog(level: LogLevel) bool {
    if (DEBUG_MODE) return true;
    return @intFromEnum(level) <= @intFromEnum(RELEASE_MIN_LEVEL);
}

fn levelDisplayFive(level: LogLevel) []const u8 {
    return switch (level) {
        .emerg, .alert, .crit => "FATAL",
        .err => "ERROR",
        .warning => "WARN ",
        .notice, .info => "INFO ",
        .debug => "DEBUG",
        .trace => "TRACE",
    };
}

fn padComponentComptime(comptime s: []const u8) [COMPONENT_FIELD_WIDTH]u8 {
    comptime {
        if (s.len > COMPONENT_FIELD_WIDTH) @compileError("klog scoped component max " ++ std.fmt.comptimePrint("{}", .{COMPONENT_FIELD_WIDTH}) ++ " bytes");
        var out: [COMPONENT_FIELD_WIDTH]u8 = .{' '} ** COMPONENT_FIELD_WIDTH;
        for (s, 0..) |c, i| out[i] = c;
        return out;
    }
}

const default_component = padComponentComptime("Kernel.Core");

/// x86_64 裸机：串口 `consoleWrite` 多核/异常路径交错时易乱码；整行日志原子化（诊断用，勿在持锁路径再嵌套 klog）。
var klog_serial_gate: std.atomic.Value(u32) = .init(0);

fn output(s: []const u8) void {
    arch.consoleWrite(s);
}

fn writePaddedU64(buf: []u8, pos: *usize, width: usize, value: u64) void {
    var mod: u64 = 1;
    var j: usize = 0;
    while (j < width) : (j += 1) mod *%= 10;
    const v = value % mod;

    var tmp: [20]u8 = undefined;
    var n = v;
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
    const leading = width - len;
    j = 0;
    while (j < leading) : (j += 1) {
        if (pos.* < buf.len) buf[pos.*] = '0';
        pos.* +|= 1;
    }
    j = 0;
    while (j < len) : (j += 1) {
        const ch = tmp[len - 1 - j];
        if (pos.* < buf.len) buf[pos.*] = ch;
        pos.* +|= 1;
    }
}

fn writeTimestampPrefix(buf: []u8, pos: *usize) void {
    const t: rtc_cmos.RtcTime = rtc_cmos.readTime();
    const full_year: u64 = 2000 + @as(u64, t.year);
    const ms = log_elapsed_ms.load(.monotonic) % 1000;

    if (pos.* < buf.len) buf[pos.*] = '[';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 4, full_year);
    if (pos.* < buf.len) buf[pos.*] = '-';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 2, t.month);
    if (pos.* < buf.len) buf[pos.*] = '-';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 2, t.day);
    if (pos.* < buf.len) buf[pos.*] = ' ';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 2, t.hour);
    if (pos.* < buf.len) buf[pos.*] = ':';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 2, t.minute);
    if (pos.* < buf.len) buf[pos.*] = ':';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 2, t.second);
    if (pos.* < buf.len) buf[pos.*] = '.';
    pos.* +|= 1;
    writePaddedU64(buf, pos, 3, ms);
    if (pos.* < buf.len) buf[pos.*] = ']';
    pos.* +|= 1;
}

fn appendBytes(buf: []u8, pos: *usize, bytes: []const u8) void {
    for (bytes) |c| {
        if (pos.* < buf.len) buf[pos.*] = c;
        pos.* +|= 1;
    }
}

fn writeLogPrefix(buf: []u8, level: LogLevel, component: *const [COMPONENT_FIELD_WIDTH]u8) []const u8 {
    var pos: usize = 0;
    writeTimestampPrefix(buf, &pos);
    appendBytes(buf, &pos, " [");
    appendBytes(buf, &pos, levelDisplayFive(level));
    appendBytes(buf, &pos, "] [");
    for (component) |c| {
        if (pos < buf.len) buf[pos] = c;
        pos +|= 1;
    }
    appendBytes(buf, &pos, "] ");
    return buf[0..@min(pos, buf.len)];
}

fn klogWithComponent(level: LogLevel, component: *const [COMPONENT_FIELD_WIDTH]u8, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        while (klog_serial_gate.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
            arch.spinCpuRelax();
        }
        defer klog_serial_gate.store(0, .release);
    }
    var prefix_buf: [128]u8 = undefined;
    const prefix = writeLogPrefix(&prefix_buf, level, component);
    output(prefix);
    var buf_storage: [256]u8 = undefined;
    const result = formatToBuf(&buf_storage, fmt, args);
    output(result);
    output("\n");
}

pub fn klog(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    klogWithComponent(level, &default_component, fmt, args);
}

/// 两级组件名（如 `Shell.Taskbar`），总长不超过 19，右补空格；`klog.scoped("Shell.Taskbar").info(...)`。
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
            if (arg_idx >= fields.len) {
                if (pos < buf.len) buf[pos] = fmt[i];
                pos +|= 1;
                i += 1;
                continue;
            }
            pos +|= formatArg(buf[pos..], fmt[i], args, fields, arg_idx);
            arg_idx += 1;
            i += 1;
        } else {
            if (pos < buf.len) buf[pos] = fmt[i];
            pos +|= 1;
            i += 1;
        }
    }
    return buf[0..@min(pos, buf.len)];
}

fn formatArg(buf: []u8, spec: u8, args: anytype, fields: anytype, arg_idx: usize) usize {
    inline for (fields, 0..) |f, i| {
        if (i == arg_idx) {
            const arg = @field(args, f.name);
            switch (spec) {
                's' => {
                    if (@TypeOf(arg) == []const u8) {
                        var j: usize = 0;
                        for (arg) |c| {
                            if (j < buf.len) buf[j] = c;
                            j += 1;
                        }
                        return j;
                    }
                    return 0;
                },
                'd', 'i' => return formatIntMaybe(buf, arg, 10, true),
                'u' => return formatIntMaybe(buf, arg, 10, false),
                'x', 'X' => return formatIntMaybe(buf, arg, 16, false),
                'p' => {
                    if (buf.len > 1) {
                        buf[0] = '0';
                        buf[1] = 'x';
                    }
                    return 2 + formatIntMaybe(buf[2..], arg, 16, false);
                },
                '%' => {
                    if (buf.len > 0) buf[0] = '%';
                    return 1;
                },
                else => {
                    if (buf.len > 0) buf[0] = spec;
                    return 1;
                },
            }
        }
    }
    return 0;
}

fn formatIntMaybe(buf: []u8, value: anytype, base: u8, signed: bool) usize {
    const T = @TypeOf(value);
    if (T == []const u8) return 0;
    const type_info = @typeInfo(T);
    if (type_info == .int or type_info == .comptime_int) {
        return formatInt(buf, value, base, signed);
    }
    return 0;
}

fn formatInt(buf: []u8, value: anytype, base: u8, signed: bool) usize {
    const digits = "0123456789abcdef";
    var start: usize = 0;
    var n: u64 = 0;
    if (signed) {
        const v = @as(i64, @intCast(value));
        if (v < 0) {
            if (buf.len > 0) buf[0] = '-';
            start = 1;
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
    var idx: usize = len;
    while (idx > 0) {
        idx -= 1;
        if (start < buf.len) buf[start] = tmp[idx];
        start += 1;
    }
    return start;
}

const mouse_component = padComponentComptime("Input.MouseDbg");

/// 仅当 `-Dmouse_debug=true` 编译时输出；**不受** `DEBUG_MODE`/Release 日志级别限制，便于无冗长日志下抓指针。
pub fn mouseDbg(comptime fmt: []const u8, args: anytype) void {
    if (!@import("build_options").mouse_debug) return;
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        while (klog_serial_gate.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
            arch.spinCpuRelax();
        }
        defer klog_serial_gate.store(0, .release);
    }
    var prefix_buf: [128]u8 = undefined;
    const prefix = writeLogPrefix(&prefix_buf, .debug, &mouse_component);
    output(prefix);
    output("MOUSEDBG ");
    var buf_storage: [224]u8 = undefined;
    const result = formatToBuf(&buf_storage, fmt, args);
    output(result);
    output("\n");
}

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
