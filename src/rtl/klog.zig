//! ZirconOS Kernel Logger (printk-style)
//! Debug mode: full log output at all levels, dual output (VGA + serial)
//! Release mode: only KERN_ERR and above

const arch = @import("../arch.zig");

pub const LogLevel = enum(u8) {
    emerg = 0,
    alert = 1,
    crit = 2,
    err = 3,
    warning = 4,
    notice = 5,
    info = 6,
    debug = 7,
};

const LEVEL_PREFIX: [8][]const u8 = .{
    "<0>", "<1>", "<2>", "<3>",
    "<4>", "<5>", "<6>", "<7>",
};

const LEVEL_NAME: [8][]const u8 = .{
    "EMERG", "ALERT", "CRIT", "ERR",
    "WARN", "NOTICE", "INFO", "DEBUG",
};

pub const DEBUG_MODE: bool = @import("build_options").debug;

const RELEASE_MIN_LEVEL: LogLevel = .err;

pub fn shouldLog(level: LogLevel) bool {
    if (DEBUG_MODE) return true;
    return @intFromEnum(level) <= @intFromEnum(RELEASE_MIN_LEVEL);
}

fn output(s: []const u8) void {
    arch.consoleWrite(s);
}

pub fn klog(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;
    const prefix = LEVEL_PREFIX[@intFromEnum(level)];
    output(prefix);
    output(" ");
    var buf_storage: [256]u8 = undefined;
    const result = formatToBuf(&buf_storage, fmt, args);
    output(result);
    output("\n");
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
                pos += 1;
                i += 1;
                continue;
            }
            pos += formatArg(buf[pos..], fmt[i], args, fields, arg_idx);
            arg_idx += 1;
            i += 1;
        } else {
            if (pos < buf.len) buf[pos] = fmt[i];
            pos += 1;
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

pub fn emerg(comptime fmt: []const u8, args: anytype) void { klog(.emerg, fmt, args); }
pub fn alert(comptime fmt: []const u8, args: anytype) void { klog(.alert, fmt, args); }
pub fn crit(comptime fmt: []const u8, args: anytype) void { klog(.crit, fmt, args); }
pub fn err(comptime fmt: []const u8, args: anytype) void { klog(.err, fmt, args); }
pub fn warn(comptime fmt: []const u8, args: anytype) void { klog(.warning, fmt, args); }
pub fn notice(comptime fmt: []const u8, args: anytype) void { klog(.notice, fmt, args); }
pub fn info(comptime fmt: []const u8, args: anytype) void { klog(.info, fmt, args); }
pub fn debug(comptime fmt: []const u8, args: anytype) void { klog(.debug, fmt, args); }
