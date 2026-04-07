//! LoongArch QEMU TCG：对 `uefi.Status` 的多分支 `switch` 可能生成 **`ldx.d` 跳转表**，会触发 #INE。
//! 本模块在 LoongArch 上直接调用 `SimpleTextOutput` 的 `_*` 函数指针并丢弃 `Status`，其它架构仍走标准 API。
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

inline fn sto(out: anytype) *uefi.protocol.SimpleTextOutput {
    return @ptrCast(@alignCast(out));
}

pub fn reset(out: anytype, verify: bool) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._reset(s, verify);
    } else {
        out.reset(verify) catch {};
    }
}

pub fn setMode(out: anytype, mode_number: usize) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._set_mode(s, mode_number);
    } else {
        _ = out.setMode(mode_number) catch {};
    }
}

pub fn outputString(out: anytype, msg: [*:0]const u16) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._output_string(s, msg);
    } else {
        _ = out.outputString(msg) catch {};
    }
}

pub fn setAttribute(out: anytype, attr_u8: u8) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._set_attribute(s, @intCast(attr_u8));
    } else {
        _ = out.setAttribute(@bitCast(attr_u8)) catch {};
    }
}

pub fn setCursorPosition(out: anytype, column: usize, row: usize) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._set_cursor_position(s, column, row);
    } else {
        _ = out.setCursorPosition(column, row) catch {};
    }
}

pub fn enableCursor(out: anytype, visible: bool) void {
    if (builtin.cpu.arch == .loongarch64) {
        const s = sto(out);
        _ = s._enable_cursor(s, visible);
    } else {
        _ = out.enableCursor(visible) catch {};
    }
}
