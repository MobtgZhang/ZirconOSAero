//! ZirconOS Boot Manager — 共享 UEFI 菜单模块
//!
//! 供 main.zig (x86/aarch64) 与 main_loongarch64.zig 共用。
//! 包含 C stub 改进：updateSelectionOnly 无闪烁、WaitForEvent、扩展按键、100ms 轮询。
const std = @import("std");
const uefi = std.os.uefi;
const unicode = std.unicode;

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

// 扩展按键：EFI 标准 + PC 扩展 + Unicode 箭头 + j/k w/s
const SCAN_UP = 0x01;
const SCAN_DOWN = 0x02;
const SCAN_UP_EXT = 0x48;
const SCAN_DOWN_EXT = 0x50;
const SCAN_ENTER = 0x0D;
const SCAN_ESC = 0x17;
const UNICODE_UP: u21 = 0x2191;
const UNICODE_DOWN: u21 = 0x2193;

const MENU_ENTRY_ROW = 7;

fn rowBelowMenu() usize {
    return MENU_ENTRY_ROW + entry_count;
}

pub var entries: [MAX_ENTRIES]BootEntry = undefined;
pub var entry_count: usize = 0;
pub var selected: usize = 0;
pub var countdown: u32 = DEFAULT_TIMEOUT;
pub var timer_active: bool = true;

pub fn initBootEntries(comptime desktop_theme_name: []const u8, kernel_path: []const u8) void {
    entry_count = 0;
    if (comptime std.mem.eql(u8, desktop_theme_name, "none")) {
        addEntry("ZirconOSAero (NT 6.1)", kernel_path, "console=serial,vga debug=0 shell=cmd", true);
        addEntry("ZirconOSAero (NT 6.1) [Debug Mode]", kernel_path, "console=serial,vga debug=1 verbose=1 shell=cmd", false);
    } else {
        addEntry("ZirconOSAero (NT 6.1)", kernel_path, "console=serial,vga debug=0 desktop=" ++ desktop_theme_name, true);
        addEntry("ZirconOSAero (NT 6.1) [Debug Mode]", kernel_path, "console=serial,vga debug=1 verbose=1 desktop=" ++ desktop_theme_name, false);
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
};

/// 运行菜单循环，返回选中的条目或需显示高级选项。
pub fn runMenuLoop(
    out: anytype,
    b: *uefi.tables.BootServices,
    cin: ?*const anyopaque,
    arch_name: []const u8,
    debug_mode: bool,
) MenuResult {
    bs = b;
    var last_selected: usize = std.math.maxInt(usize);
    var poll_count: u32 = 0;

    while (true) {
        if (last_selected != selected) {
            if (last_selected == std.math.maxInt(usize)) {
                displayBootManagerMenu(out, arch_name, debug_mode);
            } else {
                updateSelectionOnly(out, last_selected, selected);
            }
            last_selected = selected;
        }

        if (cin) |con_in_ptr| {
            const con_in: *uefi.protocol.SimpleTextInput = @ptrCast(@alignCast(@constCast(con_in_ptr)));
            if (readKey(con_in)) |key| {
                timer_active = false;

                const is_up = key.scan_code == SCAN_UP or key.scan_code == SCAN_UP_EXT or
                    key.unicode_char == UNICODE_UP or key.unicode_char == 'k' or key.unicode_char == 'w';
                const is_down = key.scan_code == SCAN_DOWN or key.scan_code == SCAN_DOWN_EXT or
                    key.unicode_char == UNICODE_DOWN or key.unicode_char == 'j' or key.unicode_char == 's';

                if (is_up and selected > 0) {
                    selected -= 1;
                    continue;
                }
                if (is_down and selected + 1 < entry_count) {
                    selected += 1;
                    continue;
                }
                if (key.scan_code == SCAN_ESC) {
                    return .{ .show_advanced = {} };
                }
                if (key.scan_code == SCAN_ENTER or key.unicode_char == '\r' or key.unicode_char == '\n') {
                    break;
                }
                if (key.unicode_char >= '1' and key.unicode_char <= '6') {
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
            _ = bs.stall(5_000) catch {}; // 5ms 轮询，按键响应更快
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

fn readKey(cin: *uefi.protocol.SimpleTextInput) ?uefi.protocol.SimpleTextInput.Key.Input {
    return cin.readKeyStroke() catch return null;
}

fn waitForKey(b: *uefi.tables.BootServices, cin: *uefi.protocol.SimpleTextInput) void {
    while (readKey(cin) == null) {
        _ = b.stall(10_000) catch {};
    }
}

fn bootMenuTimerRow() usize {
    return 11 + entry_count;
}

/// 描述行：有计时器时在计时器下方隔一空行；无计时器时在计时器行位置
fn bootDescRow() usize {
    return if (timer_active and countdown > 0) bootMenuTimerRow() + 2 else bootMenuTimerRow();
}

const SPACES_79_U16 = init: {
    var a: [80]u16 = undefined;
    for (0..79) |i| a[i] = ' ';
    a[79] = 0;
    break :init a;
};

/// 清除单行：79 空格不换行，单次 OutputString 提速
fn clearTextRow(out: anytype, row: usize) void {
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    _ = out.outputString(@as([*:0]const u16, @ptrCast(&SPACES_79_U16))) catch {};
    _ = out.setCursorPosition(0, row) catch {};
}

fn refreshTimerLine(out: anytype) void {
    if (!timer_active or countdown == 0) return;
    const row = bootMenuTimerRow();
    _ = out.setCursorPosition(0, row) catch {
        return;
    };
    _ = out.enableCursor(false) catch {};
    clearTextRow(out, row);
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    Seconds until the highlighted choice will be started automatically: ");
    printDecimal(out, countdown);
    puts(out, "  "); // 两位空格覆盖 "10"->"9" 残留；不输出 \r\n 避免整屏上滚
}

const LINE_MAX = 78; // 避免第79列换行导致重复行

/// 输出一行（前缀+描述+补足78列），单次 OutputString 提速
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

/// 全量重绘所有菜单项+描述行；跳过菜单行清除（直接覆盖78列），仅清除空行与描述行提速
fn updateSelectionOnly(out: anytype, old_sel: usize, new_sel: usize) void {
    if (old_sel == new_sel) return;

    clearTextRow(out, rowBelowMenu());
    clearTextRow(out, bootDescRow());

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const row = MENU_ENTRY_ROW + i;
        _ = out.setCursorPosition(0, row) catch return;
        if (i == new_sel) {
            _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
            printLinePadded(out, "  > ", entries[i].description);
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
        } else {
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
            printLinePadded(out, "    ", entries[i].description);
        }
    }

    const desc_row = bootDescRow();
    _ = out.setCursorPosition(0, desc_row) catch return;
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "    ");
    displayEntryDescription(out, new_sel);
}

fn displayEntryDescription(out: anytype, index: usize) void {
    switch (index) {
        0 => puts(out, "Start ZirconOS normally."),
        1 => puts(out, "Start with debug logging and serial output enabled."),
        2 => puts(out, "Start with minimal drivers and services."),
        3 => puts(out, "Start in safe mode with network support."),
        4 => puts(out, "Start the Recovery Console for system repair."),
        5 => puts(out, "Launch the command-line shell."),
        else => {},
    }
}

pub fn displayBootManagerMenu(out: anytype, arch_name: []const u8, debug_mode: bool) void {
    out.reset(false) catch {};
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};

    puts(out, "\r\n");
    puts(out, "                    ZirconOS Boot Manager                                     \r\n");
    puts(out, "                         Version " ++ ZBM_VERSION ++ "                                             \r\n");

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "    Choose an operating system to start:\r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");
    puts(out, "\r\n");

    for (0..entry_count) |i| {
        if (i == selected) {
            _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
            puts(out, "  > ");
        } else {
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
            puts(out, "    ");
        }
        putsRuntime(out, entries[i].description);
        puts(out, "\r\n");
    }

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    _ = out.setAttribute(@bitCast(Attr.border)) catch {};
    puts(out, "    ");
    for (0..72) |_| puts(out, "-");
    puts(out, "\r\n\r\n");

    if (timer_active and countdown > 0) {
        _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
        puts(out, "    Seconds until the highlighted choice will be started automatically: ");
        printDecimal(out, countdown);
        puts(out, "\r\n");
    }

    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    ");
    displayEntryDescription(out, selected);
    puts(out, "\r\n");

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "  ENTER=Choose  |  ESC=Advanced Options  |  F1=Help                          \r\n");

    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Architecture: ");
    putsRuntime(out, arch_name);
    puts(out, "  |  Boot: UEFI");
    if (debug_mode) {
        puts(out, "  |  Build: DEBUG\r\n");
    } else {
        puts(out, "  |  Build: RELEASE\r\n");
    }

    _ = out.enableCursor(false) catch {};
}

var bs: *uefi.tables.BootServices = undefined;

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

    if (debug_mode) {
        puts(out, "    Debug Features:\r\n");
        puts(out, "      [*] Verbose kernel log (EMERG..DEBUG)\r\n");
        puts(out, "      [*] Dual output: VGA + Serial (COM1)\r\n");
        puts(out, "      [*] GDB remote debugging support\r\n");
        puts(out, "\r\n");
    }

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
