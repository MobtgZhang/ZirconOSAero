//! ZirconOS Boot Manager — 共享 UEFI 菜单模块
//!
//! Windows 7 文本启动管理器风格：灰顶栏/灰底栏、全行高亮与右侧 `>`、F8 高级选项、
//! Tools 区与 TAB 切换、ESC 退出应用返回固件。
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const unicode = std.unicode;

const la = @import("loongarch_tcg_mem.zig");
const zto = @import("zbm_text_out.zig");
const zcall = @import("zbm_uefi_calls.zig");

const KeyInput = uefi.protocol.SimpleTextInput.Key.Input;

pub const ZBM_VERSION = "6.1";
pub const DEFAULT_TIMEOUT: u32 = 10;
pub const MAX_ENTRIES: usize = 8;

pub const Attr = struct {
    pub const normal: u8 = 0x0F;
    pub const dim: u8 = 0x07;
    pub const highlight: u8 = 0x70;
    pub const border: u8 = 0x08;
};

pub const BootEntry = struct {
    description: []const u8,
    kernel_path: []const u8,
    cmdline: []const u8,
    is_default: bool,
};

pub const KERNEL_PATH = "\\boot\\kernel.elf";

/// UEFI Simple Text Input scan codes (see UEFI spec / EDK2 SimpleTextIn.h).
const SCAN_UP = 0x01;
const SCAN_DOWN = 0x02;
const SCAN_HOME = 0x05;
const SCAN_END = 0x06;
const SCAN_PAGE_UP = 0x09;
const SCAN_PAGE_DOWN = 0x0A;
const SCAN_F8 = 0x12;
const SCAN_ESC = 0x17;
const SCAN_UP_EXT = 0x48;
const SCAN_DOWN_EXT = 0x50;
const UNICODE_UP: u21 = 0x2191;
const UNICODE_DOWN: u21 = 0x2193;

pub const MenuFocus = enum { os_list, tools_list };

/// Tools 区条目（占位，与 Win7「Windows Memory Diagnostic」对应）。
pub const tool_descriptions = [_][]const u8{
    "ZirconOS Memory Diagnostic",
};

pub var entries: [MAX_ENTRIES]BootEntry = undefined;
pub var entry_count: usize = 0;
pub var selected: usize = 0;
pub var countdown: u32 = DEFAULT_TIMEOUT;
pub var timer_active: bool = true;
pub var menu_focus: MenuFocus = .os_list;
pub var tool_selected: usize = 0;

pub var build_desktop_theme_runtime: []const u8 = "aero";

var g_text_in_ex: ?*uefi.protocol.SimpleTextInputEx = null;
var bs: *uefi.tables.BootServices = undefined;

fn rowEntryFirst() usize {
    return 5;
}

fn rowF8() usize {
    return 6 + entry_count;
}

pub fn rowTimer() usize {
    return 8 + entry_count;
}

fn rowToolsLabel() usize {
    return 10 + entry_count;
}

fn rowToolsFirst() usize {
    return 11 + entry_count;
}

const row_footer: usize = 24;

fn bootEntryDescription(idx: usize) []const u8 {
    if (builtin.cpu.arch != .loongarch64) return entries[idx].description;
    const base = @intFromPtr(&entries) +% idx *% @sizeOf(BootEntry) +% @offsetOf(BootEntry, "description");
    return la.sliceFromRawParts(base);
}

fn bootEntryCmdline(idx: usize) []const u8 {
    if (builtin.cpu.arch != .loongarch64) return entries[idx].cmdline;
    const base = @intFromPtr(&entries) +% idx *% @sizeOf(BootEntry) +% @offsetOf(BootEntry, "cmdline");
    return la.sliceFromRawParts(base);
}

/// 供 `main_loongarch64` 等在 LoongArch 上避免 `entries[idx]` 变址访存。
pub fn bootEntryDescriptionFor(idx: usize) []const u8 {
    return bootEntryDescription(idx);
}

pub fn bootEntryCmdlineFor(idx: usize) []const u8 {
    return bootEntryCmdline(idx);
}

fn toolDescription(idx: usize) []const u8 {
    if (builtin.cpu.arch != .loongarch64) return tool_descriptions[idx];
    const base = @intFromPtr(&tool_descriptions) +% idx *% @sizeOf([]const u8);
    return la.sliceFromRawParts(base);
}

pub fn initBootEntries(comptime desktop_theme_name: []const u8, kernel_path: []const u8) void {
    entry_count = 0;
    menu_focus = .os_list;
    tool_selected = 0;
    build_desktop_theme_runtime = desktop_theme_name;
    if (comptime std.mem.eql(u8, desktop_theme_name, "none")) {
        addEntry("ZirconOSAero (CMD / text — default)", kernel_path, "console=serial,vga debug=0 shell=cmd", true);
        addEntry("ZirconOSAero [CMD Debug]", kernel_path, "console=serial,vga debug=1 verbose=1 shell=cmd", false);
    } else {
        addEntry("ZirconOSAero (Desktop - " ++ desktop_theme_name ++ ")", kernel_path, "console=serial,vga debug=0 desktop=" ++ desktop_theme_name, true);
        addEntry("ZirconOSAero [Desktop Debug - " ++ desktop_theme_name ++ "]", kernel_path, "console=serial,vga debug=1 verbose=1 desktop=" ++ desktop_theme_name, false);
    }
    addEntry("ZirconOSAero [Safe Mode]", kernel_path, "safe_mode=1 debug=0 minimal=1", false);
    addEntry("ZirconOSAero [Safe Mode with Networking]", kernel_path, "safe_mode=1 network=1", false);
    addEntry("ZirconOSAero [Recovery Console]", kernel_path, "recovery=1 console=serial,vga debug=1", false);
    addEntry("ZirconOSAero [CMD Shell]", kernel_path, "console=serial,vga shell=cmd", false);
}

fn addEntry(desc: []const u8, path: []const u8, cmdline: []const u8, is_default: bool) void {
    if (entry_count >= MAX_ENTRIES) return;
    entries[entry_count] = .{
        .description = desc,
        .kernel_path = path,
        .cmdline = cmdline,
        .is_default = is_default,
    };
    entry_count += 1;
}

pub const MenuResult = union(enum) {
    selected: usize,
    show_advanced: void,
    cancel: void,
};

pub fn runMenuLoop(
    out: anytype,
    b: *uefi.tables.BootServices,
    cin: ?*const anyopaque,
    arch_name: []const u8,
    debug_mode: bool,
) MenuResult {
    bs = b;
    g_text_in_ex = zcall.locateSimpleTextInputEx(b);
    var poll_count: u32 = 0;
    var need_full_redraw = true;

    while (true) {
        if (need_full_redraw) {
            displayBootManagerMenu(out, arch_name, debug_mode);
            need_full_redraw = false;
        }

        if (cin) |con_in_ptr| {
            const con_in: *uefi.protocol.SimpleTextInput = @ptrCast(@alignCast(@constCast(con_in_ptr)));
            if (tryReadKeyUnified(con_in)) |key| {
                timer_active = false;

                if (key.unicode_char == '\t') {
                    menu_focus = if (menu_focus == .os_list) .tools_list else .os_list;
                    need_full_redraw = true;
                    continue;
                }

                if (key.scan_code == SCAN_ESC) {
                    return .{ .cancel = {} };
                }

                if (key.scan_code == SCAN_F8) {
                    return .{ .show_advanced = {} };
                }

                const is_up = key.scan_code == SCAN_UP or key.scan_code == SCAN_UP_EXT or
                    key.scan_code == SCAN_PAGE_UP or key.scan_code == SCAN_HOME or
                    key.unicode_char == UNICODE_UP or key.unicode_char == 'k' or key.unicode_char == 'w';
                const is_down = key.scan_code == SCAN_DOWN or key.scan_code == SCAN_DOWN_EXT or
                    key.scan_code == SCAN_PAGE_DOWN or key.scan_code == SCAN_END or
                    key.unicode_char == UNICODE_DOWN or key.unicode_char == 'j' or key.unicode_char == 's';

                if (menu_focus == .tools_list) {
                    if (key.scan_code == SCAN_HOME) {
                        tool_selected = 0;
                        redrawToolRows(out);
                        continue;
                    }
                    if (key.scan_code == SCAN_END and tool_descriptions.len > 0) {
                        tool_selected = tool_descriptions.len - 1;
                        redrawToolRows(out);
                        continue;
                    }
                    if (is_up and tool_selected > 0) {
                        tool_selected -= 1;
                        redrawToolRows(out);
                        continue;
                    }
                    if (is_down and tool_selected + 1 < tool_descriptions.len) {
                        tool_selected += 1;
                        redrawToolRows(out);
                        continue;
                    }
                    if (key.unicode_char == '\r' or key.unicode_char == '\n') {
                        showToolPlaceholderScreen(out, cin);
                        need_full_redraw = true;
                        continue;
                    }
                    continue;
                }

                // OS 列表焦点：每次移动只重绘条目行（与 Win7 高亮一致）
                if (key.scan_code == SCAN_HOME) {
                    selected = 0;
                    redrawOsEntryRows(out);
                    continue;
                }
                if (key.scan_code == SCAN_END and entry_count > 0) {
                    selected = entry_count - 1;
                    redrawOsEntryRows(out);
                    continue;
                }
                if (is_up and selected > 0) {
                    selected -= 1;
                    redrawOsEntryRows(out);
                    continue;
                }
                if (is_down and selected + 1 < entry_count) {
                    selected += 1;
                    redrawOsEntryRows(out);
                    continue;
                }
                if (key.unicode_char == '\r' or key.unicode_char == '\n') {
                    break;
                }
                if (key.unicode_char >= '1' and key.unicode_char <= '0' + MAX_ENTRIES) {
                    const idx: usize = @intCast(key.unicode_char - '1');
                    if (idx < entry_count) {
                        selected = idx;
                        break;
                    }
                }
                continue;
            }
        }

        if (timer_active) {
            zcall.stallMicroseconds(bs, 5_000);
            poll_count += 1;
            if (poll_count >= 200) {
                poll_count = 0;
                if (countdown > 0) {
                    countdown -= 1;
                    refreshTimerLine(out);
                    if (countdown == 0) break;
                }
            }
        } else if (cin) |con_in_ptr| {
            const con_in: *uefi.protocol.SimpleTextInput = @ptrCast(@alignCast(@constCast(con_in_ptr)));
            waitForKey(bs, con_in);
        } else {
            zcall.stallMicroseconds(bs, 100_000);
        }
    }

    return .{ .selected = selected };
}

fn readKeyStrokeSimple(cin: *uefi.protocol.SimpleTextInput) ?KeyInput {
    return zcall.readKeyStrokeSimple(cin);
}

fn tryReadKeyUnified(cin: *uefi.protocol.SimpleTextInput) ?KeyInput {
    if (g_text_in_ex) |ex| {
        if (zcall.readKeyStrokeEx(ex)) |full| {
            return full.input;
        }
        if (zcall.checkEventSignaled(bs, ex.wait_for_key_ex)) {
            if (zcall.readKeyStrokeEx(ex)) |full| return full.input;
        }
    }
    if (readKeyStrokeSimple(cin)) |k| return k;
    if (zcall.checkEventSignaled(bs, cin.wait_for_key)) {
        return readKeyStrokeSimple(cin);
    }
    return null;
}

fn waitForKey(b: *uefi.tables.BootServices, cin: *uefi.protocol.SimpleTextInput) void {
    while (true) {
        if (tryReadKeyUnified(cin)) |_| return;

        if (g_text_in_ex) |ex| {
            const evs = [_]uefi.Event{ ex.wait_for_key_ex, cin.wait_for_key };
            zcall.waitForEventWithStallFallback(b, evs[0..]);
        } else {
            zcall.waitForEventWithStallFallback(b, &.{cin.wait_for_key});
        }
    }
}

const SPACES_79_U16 = init: {
    var a: [80]u16 = undefined;
    for (0..79) |i| a[i] = ' ';
    a[79] = 0;
    break :init a;
};

fn clearTextRow(out: anytype, row: usize) void {
    zto.setCursorPosition(out, 0, row);
    zto.setAttribute(out, Attr.normal);
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&SPACES_79_U16)));
    zto.setCursorPosition(out, 0, row);
}

const LINE_MAX = 78;

/// LoongArch：避免把 `[]const u8` 作参数/返回值在栈上展开，LLVM 可能为 slice 相关路径生成 **`ldx.d` 跳转表**（QEMU TCG #INE）。
fn printLinePaddedLa(out: anytype, prefix: []const u8, desc_ptr: [*]const u8, desc_len: usize) void {
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    var pi: usize = 0;
    while (pi < prefix.len) : (pi += 1) {
        buf[i] = @intCast(la.loadU8(prefix.ptr, pi));
        i += 1;
    }
    var di: usize = 0;
    while (di < desc_len) : (di += 1) {
        if (i >= LINE_MAX) break;
        buf[i] = @intCast(la.loadU8(desc_ptr, di));
        i += 1;
    }
    while (i < LINE_MAX) : (i += 1) buf[i] = ' ';
    buf[i] = 0;
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&buf)));
}

fn printOsEntryHighlightedLa(out: anytype, desc_ptr: [*]const u8, desc_len: usize) void {
    zto.setAttribute(out, Attr.highlight);
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    const left_margin = 4;
    while (i < left_margin) : (i += 1) buf[i] = ' ';
    var di: usize = 0;
    const max_desc = LINE_MAX - left_margin - 2;
    while (di < desc_len and i < left_margin + max_desc) {
        buf[i] = @intCast(la.loadU8(desc_ptr, di));
        i += 1;
        di += 1;
    }
    while (i < LINE_MAX - 1) : (i += 1) buf[i] = ' ';
    buf[LINE_MAX - 1] = '>';
    buf[LINE_MAX] = 0;
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&buf)));
}

fn printLinePadded(out: anytype, prefix: []const u8, desc: []const u8) void {
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    var pi: usize = 0;
    while (pi < prefix.len) : (pi += 1) {
        buf[i] = @intCast(la.loadU8(prefix.ptr, pi));
        i += 1;
    }
    var di: usize = 0;
    while (di < desc.len) : (di += 1) {
        if (i >= LINE_MAX) break;
        buf[i] = @intCast(la.loadU8(desc.ptr, di));
        i += 1;
    }
    while (i < LINE_MAX) : (i += 1) buf[i] = ' ';
    buf[i] = 0;
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&buf)));
}

fn printOsEntryHighlighted(out: anytype, desc: []const u8) void {
    zto.setAttribute(out, Attr.highlight);
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    const left_margin = 4;
    while (i < left_margin) : (i += 1) buf[i] = ' ';
    var di: usize = 0;
    const max_desc = LINE_MAX - left_margin - 2;
    while (di < desc.len and i < left_margin + max_desc) {
        buf[i] = @intCast(la.loadU8(desc.ptr, di));
        i += 1;
        di += 1;
    }
    while (i < LINE_MAX - 1) : (i += 1) buf[i] = ' ';
    buf[LINE_MAX - 1] = '>';
    buf[LINE_MAX] = 0;
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&buf)));
}

fn printToolEntryHighlighted(out: anytype, desc: []const u8) void {
    printOsEntryHighlighted(out, desc);
}

fn drawHeaderBar(out: anytype) void {
    zto.setCursorPosition(out, 0, 0);
    zto.setAttribute(out, Attr.highlight);
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&SPACES_79_U16)));
    const title = "ZirconOSAero Boot Manager";
    const col = (80 - title.len) / 2;
    zto.setCursorPosition(out, col, 0);
    putsRuntime(out, title);
}

fn drawFooterBar(out: anytype) void {
    zto.setCursorPosition(out, 0, row_footer);
    zto.setAttribute(out, Attr.highlight);
    zto.outputString(out, @as([*:0]const u16, @ptrCast(&SPACES_79_U16)));
    const left = "ENTER=Choose";
    const mid = "TAB=Menu";
    const right = "ESC=Cancel";
    zto.setCursorPosition(out, 2, row_footer);
    putsRuntime(out, left);
    const mid_col = (80 - mid.len) / 2;
    zto.setCursorPosition(out, mid_col, row_footer);
    putsRuntime(out, mid);
    zto.setCursorPosition(out, 80 - right.len - 1, row_footer);
    putsRuntime(out, right);
}

fn redrawOsEntryRows(out: anytype) void {
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const row = rowEntryFirst() + i;
        clearTextRow(out, row);
        zto.setCursorPosition(out, 0, row);
        const hi = (menu_focus == .os_list) and (i == selected);
        if (builtin.cpu.arch == .loongarch64) {
            const desc_base = @intFromPtr(&entries) +% i *% @sizeOf(BootEntry) +% @offsetOf(BootEntry, "description");
            const dptr: [*]const u8 = @ptrFromInt(la.loadU64Abs(desc_base));
            const dlen = la.loadU64Abs(desc_base +% 8);
            if (hi) {
                printOsEntryHighlightedLa(out, dptr, dlen);
            } else {
                zto.setAttribute(out, Attr.normal);
                printLinePaddedLa(out, "    ", dptr, dlen);
            }
        } else {
            if (hi) {
                printOsEntryHighlighted(out, bootEntryDescription(i));
            } else {
                zto.setAttribute(out, Attr.normal);
                printLinePadded(out, "    ", bootEntryDescription(i));
            }
        }
    }
}

fn redrawToolRows(out: anytype) void {
    const base = rowToolsFirst();
    var t: usize = 0;
    while (t < tool_descriptions.len) : (t += 1) {
        const row = base + t;
        clearTextRow(out, row);
        zto.setCursorPosition(out, 0, row);
        const hi = (menu_focus == .tools_list) and (t == tool_selected);
        if (builtin.cpu.arch == .loongarch64) {
            const desc_base = @intFromPtr(&tool_descriptions) +% t *% @sizeOf([]const u8);
            const dptr: [*]const u8 = @ptrFromInt(la.loadU64Abs(desc_base));
            const dlen = la.loadU64Abs(desc_base +% 8);
            if (hi) {
                printOsEntryHighlightedLa(out, dptr, dlen);
            } else {
                zto.setAttribute(out, Attr.normal);
                printLinePaddedLa(out, "    ", dptr, dlen);
            }
        } else {
            if (hi) {
                printToolEntryHighlighted(out, toolDescription(t));
            } else {
                zto.setAttribute(out, Attr.normal);
                printLinePadded(out, "    ", toolDescription(t));
            }
        }
    }
}

fn refreshTimerLine(out: anytype) void {
    if (!timer_active or countdown == 0) return;
    const row = rowTimer();
    zto.setCursorPosition(out, 0, row);
    zto.enableCursor(out, false);
    clearTextRow(out, row);
    zto.setCursorPosition(out, 0, row);
    zto.setAttribute(out, Attr.normal);
    puts(out, "    Seconds until the highlighted choice will be started automatically: ");
    printDecimal(out, countdown);
    puts(out, "  ");
}

pub fn displayBootManagerMenu(out: anytype, arch_name: []const u8, debug_mode: bool) void {
    _ = arch_name;
    _ = debug_mode;
    zto.reset(out, false);
    zto.setAttribute(out, Attr.normal);

    drawHeaderBar(out);

    clearTextRow(out, 1);

    zto.setCursorPosition(out, 0, 2);
    zto.setAttribute(out, Attr.normal);
    puts(out, "    Choose an operating system to start, or press TAB to select a tool:\r\n");

    zto.setCursorPosition(out, 0, 3);
    zto.setAttribute(out, Attr.dim);
    puts(out, "    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");

    clearTextRow(out, 4);

    redrawOsEntryRows(out);

    const gap_row = 5 + entry_count;
    clearTextRow(out, gap_row);

    zto.setCursorPosition(out, 0, rowF8());
    zto.setAttribute(out, Attr.normal);
    puts(out, "    To specify an advanced option for this choice, press F8.\r\n");

    clearTextRow(out, rowF8() + 1);

    if (timer_active and countdown > 0) {
        zto.setCursorPosition(out, 0, rowTimer());
        zto.setAttribute(out, Attr.normal);
        puts(out, "    Seconds until the highlighted choice will be started automatically: ");
        printDecimal(out, countdown);
        puts(out, "\r\n");
    } else {
        clearTextRow(out, rowTimer());
    }

    clearTextRow(out, rowTimer() + 1);

    zto.setCursorPosition(out, 0, rowToolsLabel());
    zto.setAttribute(out, Attr.normal);
    puts(out, "    Tools:\r\n");

    redrawToolRows(out);

    var r: usize = rowToolsFirst() + tool_descriptions.len;
    while (r < row_footer) : (r += 1) {
        clearTextRow(out, r);
    }

    drawFooterBar(out);
    zto.enableCursor(out, false);
}

fn showToolPlaceholderScreen(out: anytype, cin: ?*const anyopaque) void {
    zto.reset(out, false);
    zto.setAttribute(out, Attr.normal);
    puts(out, "\r\n");
    puts(out, "    ZirconOS Boot Manager\r\n\r\n");
    puts(out, "    The selected tool is not available in this build of ZBM.\r\n");
    puts(out, "    (Placeholder for memory diagnostic or firmware tools.)\r\n\r\n");
    puts(out, "    Press any key to return to the boot menu...\r\n");
    if (cin) |c| {
        const con_in: *uefi.protocol.SimpleTextInput = @ptrCast(@alignCast(@constCast(c)));
        waitForKey(bs, con_in);
    }
}

fn puts(out: anytype, comptime s: []const u8) void {
    zto.outputString(out, unicode.utf8ToUtf16LeStringLiteral(s));
}

fn putsRuntime(out: anytype, s: []const u8) void {
    var si: usize = 0;
    while (si < s.len) : (si += 1) {
        const c = la.loadU8(s.ptr, si);
        var buf: [1:0]u16 = .{@intCast(c)};
        zto.outputString(out, &buf);
    }
}

/// `displayBootProgress` / 高级选项等：LoongArch 上避免经 `[]const u8` 传参。
pub fn putsRuntimeBootEntryDesc(out: anytype, idx: usize) void {
    if (builtin.cpu.arch == .loongarch64) {
        const base = @intFromPtr(&entries) +% idx *% @sizeOf(BootEntry) +% @offsetOf(BootEntry, "description");
        const dptr: [*]const u8 = @ptrFromInt(la.loadU64Abs(base));
        const dlen = la.loadU64Abs(base +% 8);
        var si: usize = 0;
        while (si < dlen) : (si += 1) {
            const c = la.loadU8(dptr, si);
            var buf: [1:0]u16 = .{@intCast(c)};
            zto.outputString(out, &buf);
        }
    } else {
        putsRuntime(out, bootEntryDescription(idx));
    }
}

pub fn putsRuntimeBootEntryCmdline(out: anytype, idx: usize) void {
    if (builtin.cpu.arch == .loongarch64) {
        const base = @intFromPtr(&entries) +% idx *% @sizeOf(BootEntry) +% @offsetOf(BootEntry, "cmdline");
        const dptr: [*]const u8 = @ptrFromInt(la.loadU64Abs(base));
        const dlen = la.loadU64Abs(base +% 8);
        var si: usize = 0;
        while (si < dlen) : (si += 1) {
            const c = la.loadU8(dptr, si);
            var buf: [1:0]u16 = .{@intCast(c)};
            zto.outputString(out, &buf);
        }
    } else {
        putsRuntime(out, bootEntryCmdline(idx));
    }
}

pub fn printDecimal(out: anytype, value: u32) void {
    if (value >= 10) printDecimal(out, value / 10);
    var buf: [1:0]u16 = .{@intCast('0' + (value % 10))};
    zto.outputString(out, &buf);
}

pub fn displayAdvancedOptions(
    out: anytype,
    boot_services: *uefi.tables.BootServices,
    cin: ?*const anyopaque,
    arch_name: []const u8,
    kernel_path: []const u8,
    firmware_vendor: [*:0]const u16,
    revision: u32,
    debug_mode: bool,
) void {
    bs = boot_services;
    g_text_in_ex = zcall.locateSimpleTextInputEx(boot_services);
    zto.reset(out, false);
    zto.setAttribute(out, Attr.normal);
    puts(out, "\r\n");
    puts(out, "                ZirconOS Advanced Boot Options                                 \r\n");
    zto.setAttribute(out, Attr.dim);
    puts(out, "\r\n");
    puts(out, "    Boot Information:\r\n");
    puts(out, "      Architecture : ");
    putsRuntime(out, arch_name);
    puts(out, "\r\n");
    puts(out, "      Boot Method  : UEFI Application\r\n");
    puts(out, "      Firmware     : ");
    zto.outputString(out, firmware_vendor);
    puts(out, "\r\n");

    const major = revision >> 16;
    const minor = revision & 0xFFFF;
    puts(out, "      UEFI Rev     : ");
    printDecimal(out, major);
    puts(out, ".");
    printDecimal(out, minor);
    puts(out, "\r\n");

    puts(out, "\r\n");
    puts(out, "    Partition Information:\r\n");
    puts(out, "      Scheme       : GPT (GUID Partition Table)\r\n");
    puts(out, "      Boot Partition: EFI System Partition (ESP)\r\n");
    puts(out, "      Kernel Path  : ");
    putsRuntime(out, kernel_path);
    puts(out, "\r\n\r\n");
    puts(out, "    Boot Configuration Data (BCD):\r\n");
    puts(out, "      Store        : In-memory (default entries)\r\n");
    puts(out, "      Entries      : ");
    printDecimal(out, @intCast(entry_count));
    puts(out, "\r\n");
    puts(out, "      Default      : ");
    putsRuntimeBootEntryDesc(out, 0);
    puts(out, "\r\n");
    puts(out, "      Timeout      : ");
    printDecimal(out, DEFAULT_TIMEOUT);
    puts(out, " seconds\r\n");
    puts(out, "\r\n");
    puts(out, "    Build DESKTOP  : ");
    putsRuntime(out, build_desktop_theme_runtime);
    puts(out, "\r\n");

    if (debug_mode) {
        puts(out, "\r\n");
        puts(out, "    Debug Features:\r\n");
        puts(out, "      [*] Verbose kernel log (EMERG..DEBUG)\r\n");
        puts(out, "      [*] Dual output: VGA + Serial (COM1)\r\n");
        puts(out, "      [*] GDB remote debugging support\r\n");
    }

    puts(out, "\r\n");
    puts(out, "  Press any key to return to boot menu...                                     \r\n");
    zto.setAttribute(out, Attr.dim);

    if (cin) |c| {
        const con_in: *uefi.protocol.SimpleTextInput = @ptrCast(@alignCast(@constCast(c)));
        waitForKey(boot_services, con_in);
    }
    timer_active = false;
}

pub fn printHex64(out: anytype, value: u64) void {
    const hex = "0123456789abcdef";
    var v = value;
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@intCast(v & 0xF)];
        v >>= 4;
    }
    var j: usize = 0;
    while (j < buf.len) : (j += 1) {
        const c = la.loadU8(@ptrCast(&buf), j);
        var u16buf: [1:0]u16 = .{@intCast(c)};
        zto.outputString(out, &u16buf);
    }
}
