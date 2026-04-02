//! ZirconOS Boot Manager — 共享 UEFI 菜单模块
//!
//! Windows 7 文本启动管理器风格：灰顶栏/灰底栏、全行高亮与右侧 `>`、F8 高级选项、
//! Tools 区与 TAB 切换、ESC 退出应用返回固件。
const std = @import("std");
const uefi = std.os.uefi;
const unicode = std.unicode;

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
    g_text_in_ex = b.locateProtocol(uefi.protocol.SimpleTextInputEx, null) catch null;
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
            _ = bs.stall(5_000) catch {};
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
            _ = bs.stall(100_000) catch {};
        }
    }

    return .{ .selected = selected };
}

fn readKeyStrokeSimple(cin: *uefi.protocol.SimpleTextInput) ?KeyInput {
    return cin.readKeyStroke() catch null;
}

fn tryReadKeyUnified(cin: *uefi.protocol.SimpleTextInput) ?KeyInput {
    if (g_text_in_ex) |ex| {
        if (ex.readKeyStroke()) |full| {
            return full.input;
        } else |_| {}
        if (bs.checkEvent(ex.wait_for_key_ex) catch false) {
            if (ex.readKeyStroke()) |full| return full.input else |_| {}
        }
    }
    if (readKeyStrokeSimple(cin)) |k| return k;
    if (bs.checkEvent(cin.wait_for_key) catch false) {
        return readKeyStrokeSimple(cin);
    }
    return null;
}

fn waitForKey(b: *uefi.tables.BootServices, cin: *uefi.protocol.SimpleTextInput) void {
    while (true) {
        if (tryReadKeyUnified(cin)) |_| return;

        if (g_text_in_ex) |ex| {
            const evs = [_]uefi.Event{ ex.wait_for_key_ex, cin.wait_for_key };
            _ = b.waitForEvent(evs[0..]) catch {
                _ = b.stall(10_000) catch {};
            };
        } else {
            _ = b.waitForEvent(&.{cin.wait_for_key}) catch {
                _ = b.stall(10_000) catch {};
            };
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
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&SPACES_79_U16))) catch {};
    _ = out.setCursorPosition(0, row) catch {};
}

const LINE_MAX = 78;

fn printLinePadded(out: anytype, prefix: []const u8, desc: []const u8) void {
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = @intCast(c);
        i += 1;
    }
    for (desc) |c| {
        if (i >= LINE_MAX) break;
        buf[i] = @intCast(c);
        i += 1;
    }
    while (i < LINE_MAX) : (i += 1) buf[i] = ' ';
    buf[i] = 0;
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&buf))) catch {};
}

fn printOsEntryHighlighted(out: anytype, desc: []const u8) void {
    _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
    var buf: [80]u16 = undefined;
    var i: usize = 0;
    const left_margin = 4;
    while (i < left_margin) : (i += 1) buf[i] = ' ';
    var di: usize = 0;
    const max_desc = LINE_MAX - left_margin - 2;
    while (di < desc.len and i < left_margin + max_desc) {
        buf[i] = @intCast(desc[di]);
        i += 1;
        di += 1;
    }
    while (i < LINE_MAX - 1) : (i += 1) buf[i] = ' ';
    buf[LINE_MAX - 1] = '>';
    buf[LINE_MAX] = 0;
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&buf))) catch {};
}

fn printToolEntryHighlighted(out: anytype, desc: []const u8) void {
    printOsEntryHighlighted(out, desc);
}

fn drawHeaderBar(out: anytype) void {
    _ = out.setCursorPosition(0, 0) catch return;
    _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&SPACES_79_U16))) catch {};
    const title = "ZirconOSAero Boot Manager";
    const col = (80 - title.len) / 2;
    _ = out.setCursorPosition(col, 0) catch return;
    putsRuntime(out, title);
}

fn drawFooterBar(out: anytype) void {
    _ = out.setCursorPosition(0, row_footer) catch return;
    _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&SPACES_79_U16))) catch {};
    const left = "ENTER=Choose";
    const mid = "TAB=Menu";
    const right = "ESC=Cancel";
    _ = out.setCursorPosition(2, row_footer) catch return;
    putsRuntime(out, left);
    const mid_col = (80 - mid.len) / 2;
    _ = out.setCursorPosition(mid_col, row_footer) catch return;
    putsRuntime(out, mid);
    _ = out.setCursorPosition(80 - right.len - 1, row_footer) catch return;
    putsRuntime(out, right);
}

fn redrawOsEntryRows(out: anytype) void {
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const row = rowEntryFirst() + i;
        clearTextRow(out, row);
        _ = out.setCursorPosition(0, row) catch return;
        const hi = (menu_focus == .os_list) and (i == selected);
        if (hi) {
            printOsEntryHighlighted(out, entries[i].description);
        } else {
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
            printLinePadded(out, "    ", entries[i].description);
        }
    }
}

fn redrawToolRows(out: anytype) void {
    const base = rowToolsFirst();
    var t: usize = 0;
    while (t < tool_descriptions.len) : (t += 1) {
        const row = base + t;
        clearTextRow(out, row);
        _ = out.setCursorPosition(0, row) catch return;
        const hi = (menu_focus == .tools_list) and (t == tool_selected);
        if (hi) {
            printToolEntryHighlighted(out, tool_descriptions[t]);
        } else {
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
            printLinePadded(out, "    ", tool_descriptions[t]);
        }
    }
}

fn refreshTimerLine(out: anytype) void {
    if (!timer_active or countdown == 0) return;
    const row = rowTimer();
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.enableCursor(false) catch {};
    clearTextRow(out, row);
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    Seconds until the highlighted choice will be started automatically: ");
    printDecimal(out, countdown);
    puts(out, "  ");
}

pub fn displayBootManagerMenu(out: anytype, arch_name: []const u8, debug_mode: bool) void {
    _ = arch_name;
    _ = debug_mode;
    out.reset(false) catch {};
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};

    drawHeaderBar(out);

    clearTextRow(out, 1);

    _ = out.setCursorPosition(0, 2) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    Choose an operating system to start, or press TAB to select a tool:\r\n");

    _ = out.setCursorPosition(0, 3) catch return;
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");

    clearTextRow(out, 4);

    redrawOsEntryRows(out);

    const gap_row = 5 + entry_count;
    clearTextRow(out, gap_row);

    _ = out.setCursorPosition(0, rowF8()) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    To specify an advanced option for this choice, press F8.\r\n");

    clearTextRow(out, rowF8() + 1);

    if (timer_active and countdown > 0) {
        _ = out.setCursorPosition(0, rowTimer()) catch return;
        _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
        puts(out, "    Seconds until the highlighted choice will be started automatically: ");
        printDecimal(out, countdown);
        puts(out, "\r\n");
    } else {
        clearTextRow(out, rowTimer());
    }

    clearTextRow(out, rowTimer() + 1);

    _ = out.setCursorPosition(0, rowToolsLabel()) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    Tools:\r\n");

    redrawToolRows(out);

    var r: usize = rowToolsFirst() + tool_descriptions.len;
    while (r < row_footer) : (r += 1) {
        clearTextRow(out, r);
    }

    drawFooterBar(out);
    _ = out.enableCursor(false) catch {};
}

fn showToolPlaceholderScreen(out: anytype, cin: ?*const anyopaque) void {
    out.reset(false) catch {};
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
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
    _ = out.outputString(unicode.utf8ToUtf16LeStringLiteral(s)) catch false;
}

fn putsRuntime(out: anytype, s: []const u8) void {
    for (s) |c| {
        var buf: [1:0]u16 = .{@intCast(c)};
        _ = out.outputString(&buf) catch false;
    }
}

pub fn printDecimal(out: anytype, value: u32) void {
    if (value >= 10) printDecimal(out, value / 10);
    var buf: [1:0]u16 = .{@intCast('0' + (value % 10))};
    _ = out.outputString(&buf) catch false;
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
    g_text_in_ex = boot_services.locateProtocol(uefi.protocol.SimpleTextInputEx, null) catch null;
    out.reset(false) catch {};
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "                ZirconOS Advanced Boot Options                                 \r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Boot Information:\r\n");
    puts(out, "      Architecture : ");
    putsRuntime(out, arch_name);
    puts(out, "\r\n");
    puts(out, "      Boot Method  : UEFI Application\r\n");
    puts(out, "      Firmware     : ");
    _ = out.outputString(firmware_vendor) catch {};
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
    putsRuntime(out, entries[0].description);
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
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};

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
    for (buf) |c| {
        var u16buf: [1:0]u16 = .{@intCast(c)};
        _ = out.outputString(&u16buf) catch false;
    }
}
