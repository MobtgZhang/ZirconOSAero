// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/builtin_apps.zig
// Purpose: Shell-hosted built-in app windows (Win7-style) — launch, hit-test, minimal clients.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/ (shell / public API names only).
// See docs/cn/BuiltinApps_NT61_Roadmap.md

const std = @import("std");
const fb = @import("framebuffer.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const klog = @import("../../rtl/klog.zig");
const vfs = @import("../../fs/vfs.zig");
const hdmi = @import("hdmi.zig");
const mouse = @import("../input/mouse.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme.rgb(r, g, b);
}

/// 与 `display.AERO_TITLEBAR_H` 对齐（标题栏高度）。
const CAPTION_H: i32 = 32;
const DEF_W: i32 = 380;
const DEF_H: i32 = 300;

pub const ShellRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const AeroCaptionBtnHover = enum { none, minimize, maximize, close };

// ── 剪贴板 / 文件对话框（记事本/字符映射表/截图 DIB 占位）────────────────────

/// 与截图工具一致：BGRA 紧密行，最大 320×200（内核占位，非完整 CF_DIB）。
pub const clip_dib_cap_bytes: usize = 320 * 200 * 4;
var g_clip_dib: [clip_dib_cap_bytes]u8 = [_]u8{0} ** clip_dib_cap_bytes;

pub const ClipboardPrimary = enum { none, text, dib_bgr32 };

pub const Clipboard = struct {
    primary: ClipboardPrimary = .none,
    text_buf: [2048]u8 = undefined,
    text_len: usize = 0,
    dib_w: u32 = 0,
    dib_h: u32 = 0,
    dib_byte_len: usize = 0,

    pub fn setText(c: *Clipboard, s: []const u8) void {
        c.primary = .text;
        c.dib_w = 0;
        c.dib_h = 0;
        c.dib_byte_len = 0;
        const n = @min(s.len, c.text_buf.len);
        @memcpy(c.text_buf[0..n], s[0..n]);
        c.text_len = n;
    }

    /// 占位位图（截图工具写入；与 `text` 互斥主格式）。
    pub fn setDibBgr32(c: *Clipboard, w: u32, h: u32, src: []const u8) void {
        const need = @as(usize, w) * @as(usize, h) * 4;
        if (need > g_clip_dib.len or need != src.len) return;
        @memcpy(g_clip_dib[0..need], src);
        c.primary = .dib_bgr32;
        c.dib_w = w;
        c.dib_h = h;
        c.dib_byte_len = need;
        c.text_len = 0;
    }

    pub fn text(c: *const Clipboard) []const u8 {
        return c.text_buf[0..c.text_len];
    }

    pub fn dibBytes(c: *const Clipboard) []const u8 {
        return g_clip_dib[0..c.dib_byte_len];
    }

    pub fn clear(c: *Clipboard) void {
        c.text_len = 0;
        c.primary = .none;
        c.dib_w = 0;
        c.dib_h = 0;
        c.dib_byte_len = 0;
    }
};

var g_clipboard: Clipboard = .{ .text_buf = undefined };

pub fn getClipboard() *Clipboard {
    return &g_clipboard;
}

/// 演示用 VFS 路径（FAT 根目录文件；不存在时 Open 返回 cancelled）。
pub const demo_notepad_vfs_path: []const u8 = "C:\\NOTEPAD.TXT";

pub const FileDialogResult = enum { cancelled, not_implemented, ok };

pub const FileDialog = struct {
    pub fn openText(path: []const u8) FileDialogResult {
        if (!vfs.isInitialized() or vfs.getMountCount() == 0) return .not_implemented;
        const f = vfs.open(path, .read) orelse return .cancelled;
        defer _ = vfs.close(f);
        notepad_len = 0;
        var total: usize = 0;
        while (total < notepad_buf.len) {
            var chunk: [512]u8 = undefined;
            const space = notepad_buf.len - total;
            const to_read = @min(chunk.len, space);
            const rr = vfs.read(f, chunk[0..to_read]);
            if (rr.status != .success or rr.bytes_read == 0) break;
            @memcpy(notepad_buf[total..][0..rr.bytes_read], chunk[0..rr.bytes_read]);
            total += rr.bytes_read;
        }
        notepad_len = total;
        return .ok;
    }

    pub fn openTextWordpad(path: []const u8) FileDialogResult {
        if (!vfs.isInitialized() or vfs.getMountCount() == 0) return .not_implemented;
        const f = vfs.open(path, .read) orelse return .cancelled;
        defer _ = vfs.close(f);
        wordpad_len = 0;
        var total: usize = 0;
        while (total < wordpad_buf.len) {
            var chunk: [512]u8 = undefined;
            const space = wordpad_buf.len - total;
            const to_read = @min(chunk.len, space);
            const rr = vfs.read(f, chunk[0..to_read]);
            if (rr.status != .success or rr.bytes_read == 0) break;
            @memcpy(wordpad_buf[total..][0..rr.bytes_read], chunk[0..rr.bytes_read]);
            total += rr.bytes_read;
        }
        wordpad_len = total;
        return .ok;
    }

    pub fn saveText(path: []const u8, data: []const u8) FileDialogResult {
        if (!vfs.isInitialized() or vfs.getMountCount() == 0) return .not_implemented;
        const f = vfs.open(path, .write) orelse return .cancelled;
        defer _ = vfs.close(f);
        var off: usize = 0;
        while (off < data.len) {
            const end = @min(off + 512, data.len);
            const wr = vfs.write(f, data[off..end]);
            if (wr.status != .success or wr.bytes_written == 0) return .cancelled;
            off += wr.bytes_written;
        }
        return .ok;
    }

    pub fn saveTextWordpad(path: []const u8) FileDialogResult {
        return saveText(path, wordpad_buf[0..wordpad_len]);
    }
};

// ── 应用 ID ────────────────────────────────────────────────────────────────

pub const BuiltinAppId = enum(u16) {
    paint = 0,
    wordpad = 1,
    notepad = 2,
    calculator = 3,
    snipping_tool = 4,
    magnifier = 5,
    narrator = 6,
    osk = 7,
    charmap = 8,
    sync_center = 9,
    projector = 10,
    wmp = 11,
    media_center = 12,
    dvd_maker = 13,
    sound_recorder = 14,
    ie8 = 15,
    live_mail = 16,
    fax_scan = 17,
    taskmgr_focus = 18,
    control_panel = 19,
    regedit = 20,
    disk_cleanup = 21,
    defrag = 22,
    backup_restore = 23,
    system_restore = 24,
    eventvwr = 25,
    devmgmt = 26,
    compmgmt = 27,
    resmon = 28,
    perfmon = 29,
    taskschd = 30,
    cmd_shell = 31,
    powershell_shell = 32,
    minesweeper = 33,
    solitaire = 34,
    spider_solitaire = 35,
    freecell = 36,
    hearts = 37,
    chess_titans = 38,
    mahjong_titans = 39,
    purble_place = 40,
    games_internet = 41,
    shell_documents = 42,
    shell_pictures = 43,
    shell_music = 44,
    shell_videos = 45,
    shell_downloads = 46,
    games_folder = 47,
    shell_computer = 48,
    shell_network = 49,
    shell_devices_printers = 50,
    shell_default_programs = 51,
    shell_help = 52,
    shell_run = 53,
    defender = 54,
    firewall = 55,
    windows_update = 56,
    bitlocker = 57,
    uac_info = 58,
    explorer_libraries_hint = 59,
    generic_stub = 60,
};

/// 侧栏高度有限；条目数变更时请同步 `docs/*/BuiltinApps_NT61_Roadmap.md`「与代码对齐」。
pub const ALL_PROGRAMS: []const BuiltinAppId = &.{
    .notepad,     .wordpad,       .paint,        .calculator,
    .minesweeper, .solitaire,     .spider_solitaire, .freecell,
    .hearts,
    .osk,         .charmap,      .cmd_shell,    .powershell_shell,
};

pub fn allProgramsCount() usize {
    return ALL_PROGRAMS.len;
}

pub fn allProgramsId(row: usize) BuiltinAppId {
    if (row >= ALL_PROGRAMS.len) return .generic_stub;
    return ALL_PROGRAMS[row];
}

pub fn titleOf(id: BuiltinAppId) []const u8 {
    return switch (id) {
        .paint => "Paint",
        .wordpad => "WordPad",
        .notepad => "Notepad",
        .calculator => "Calculator",
        .snipping_tool => "Snipping Tool",
        .magnifier => "Magnifier",
        .narrator => "Narrator",
        .osk => "On-Screen Keyboard",
        .charmap => "Character Map",
        .sync_center => "Sync Center",
        .projector => "Connect to a Projector",
        .wmp => "Zircon Media Player",
        .media_center => "Zircon Media Center",
        .dvd_maker => "Zircon DVD Maker",
        .sound_recorder => "Sound Recorder",
        .ie8 => "Internet Explorer",
        .live_mail => "Zircon Mail",
        .fax_scan => "Zircon Fax and Scan",
        .taskmgr_focus => "Zircon Task Manager",
        .control_panel => "Control Panel",
        .regedit => "Registry Editor",
        .disk_cleanup => "Disk Cleanup",
        .defrag => "Disk Defragmenter",
        .backup_restore => "Backup and Restore",
        .system_restore => "System Restore",
        .eventvwr => "Event Viewer",
        .devmgmt => "Device Manager",
        .compmgmt => "Computer Management",
        .resmon => "Resource Monitor",
        .perfmon => "Performance Monitor",
        .taskschd => "Task Scheduler",
        .cmd_shell => "Command Prompt",
        .powershell_shell => "Zircon Shell",
        .minesweeper => "Minesweeper",
        .solitaire => "Solitaire",
        .spider_solitaire => "Spider Solitaire",
        .freecell => "FreeCell",
        .hearts => "Hearts",
        .chess_titans => "Chess Titans",
        .mahjong_titans => "Mahjong Titans",
        .purble_place => "Purble Place",
        .games_internet => "Internet Games",
        .shell_documents => "Documents",
        .shell_pictures => "Pictures",
        .shell_music => "Music",
        .shell_videos => "Videos",
        .shell_downloads => "Downloads",
        .games_folder => "Games",
        .shell_computer => "Computer",
        .shell_network => "Network",
        .shell_devices_printers => "Devices and Printers",
        .shell_default_programs => "Default Programs",
        .shell_help => "Help and Support",
        .shell_run => "Run",
        .defender => "Zircon Security",
        .firewall => "Zircon Firewall",
        .windows_update => "Zircon Update",
        .bitlocker => "BitLocker Drive Encryption",
        .uac_info => "User Account Control",
        .explorer_libraries_hint => "Libraries",
        .generic_stub => "ZirconOS",
    };
}

fn iconOf(id: BuiltinAppId) ?icons.IconId {
    return switch (id) {
        .paint, .shell_pictures => .pictures,
        .notepad, .wordpad => .text_editor,
        .calculator => .calculator,
        .cmd_shell, .powershell_shell, .shell_run => .terminal,
        .ie8 => .browser,
        .wmp, .shell_music => .music,
        .control_panel, .shell_default_programs, .defender, .firewall, .windows_update, .uac_info => .settings,
        .shell_documents => .documents,
        .shell_computer => .computer,
        .shell_network => .network,
        .shell_devices_printers => .printer,
        .taskmgr_focus, .eventvwr, .resmon, .perfmon => .settings,
        else => .info,
    };
}

// ── 标题栏按钮几何（与 display.aeroCaptionButtonLayout 同步）────────────────

fn clampI32FromI64(v: i64) i32 {
    return @intCast(@min(@max(v, std.math.minInt(i32)), std.math.maxInt(i32)));
}

fn aeroCaptionButtonLayout(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32) struct {
    min_x: i32,
    max_x: i32,
    close_x: i32,
    btn_w: i32,
    btn_w_close: i32,
    btn_y: i32,
    btn_h: i32,
    group_sep_x: i32,
} {
    const vpad: i32 = 2;
    const btn_h = @max(18, titlebar_h - 2 * vpad);
    const btn_y = win_y + @divTrunc(titlebar_h - btn_h, 2);
    const btn_w: i32 = if (titlebar_h >= 28) 40 else @max(34, titlebar_h + 2);
    const btn_w_close: i32 = btn_w + 8;
    const close_x = clampI32FromI64(@as(i64, win_x) + @as(i64, win_w) - @as(i64, btn_w_close));
    const max_x = clampI32FromI64(@as(i64, close_x) - @as(i64, btn_w));
    const min_x = clampI32FromI64(@as(i64, max_x) - @as(i64, btn_w));
    const group_sep_x = clampI32FromI64(@as(i64, min_x) - 1);
    return .{
        .min_x = min_x,
        .max_x = max_x,
        .close_x = close_x,
        .btn_w = btn_w,
        .btn_w_close = btn_w_close,
        .btn_y = btn_y,
        .btn_h = btn_h,
        .group_sep_x = group_sep_x,
    };
}

fn hitTestCaption(px: i32, py: i32, win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32) AeroCaptionBtnHover {
    if (titlebar_h < 4 or win_w < 96) return .none;
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const wx = @as(i64, win_x);
    const wy = @as(i64, win_y);
    const ww = @as(i64, win_w);
    const th = @as(i64, titlebar_h);
    if (pxi < wx or pyi < wy or pxi >= wx + ww or pyi >= wy + th) return .none;
    const L = aeroCaptionButtonLayout(win_x, win_y, win_w, titlebar_h);
    if (pxi < @as(i64, L.min_x)) return .none;
    if (pxi >= @as(i64, L.close_x) + @as(i64, L.btn_w_close)) return .none;
    if (pxi >= @as(i64, L.close_x)) return .close;
    if (pxi >= @as(i64, L.max_x)) return .maximize;
    return .minimize;
}

fn drawCaptionButtons(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32, hover: AeroCaptionBtnHover) void {
    if (titlebar_h < 8 or win_w < 96) return;
    const L = aeroCaptionButtonLayout(win_x, win_y, win_w, titlebar_h);
    const div_dark = rgb(0x3A, 0x5A, 0x78);
    const div_light = rgb(0xB8, 0xD0, 0xE8);
    const glyph_idle = rgb(0xE8, 0xF2, 0xFA);
    const glyph_on_red = rgb(0xFF, 0xFF, 0xFF);
    if (L.group_sep_x > win_x + 4) {
        fb.drawVLine(L.group_sep_x, win_y + 1, titlebar_h - 2, div_light);
        fb.drawVLine(L.group_sep_x + 1, win_y + 2, titlebar_h - 4, div_dark);
    }
    fb.drawVLine(L.max_x, win_y + 1, titlebar_h - 2, div_dark);
    fb.drawVLine(L.close_x, win_y + 1, titlebar_h - 2, div_dark);
    if (hover == .minimize) {
        fb.blendTintRect(L.min_x, L.btn_y, L.btn_w, L.btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .maximize) {
        fb.blendTintRect(L.max_x, L.btn_y, L.btn_w, L.btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .close) {
        fb.fillRect(L.close_x, L.btn_y, L.btn_w_close, L.btn_h, rgb(0xE8, 0x11, 0x23));
    }
    drawMinGlyph(L.min_x, L.btn_y, L.btn_w, L.btn_h, glyph_idle);
    drawMaxGlyph(L.max_x, L.btn_y, L.btn_w, L.btn_h, glyph_idle);
    drawCloseGlyph(L.close_x, L.btn_y, L.btn_w_close, L.btn_h, if (hover == .close) glyph_on_red else glyph_idle);
}

fn drawMinGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 8 or bh < 8) return;
    const bar_w = @max(6, @min(bw - 4, 12));
    const sx = bx + @divTrunc(bw - bar_w, 2);
    const sy = by + bh - @divTrunc(bh, 3);
    fb.fillRect(sx, sy, bar_w, 2, fg);
}

fn drawMaxGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 10 or bh < 10) return;
    const m = @max(5, @min(8, @divTrunc(@min(bw, bh), 5)));
    const sz = @max(7, @min(bw, bh) - 2 * m);
    const ox = bx + @divTrunc(bw - sz, 2);
    const oy = by + @divTrunc(bh - sz, 2);
    fb.drawRect(ox, oy, sz, sz, fg);
    fb.drawHLine(ox, oy + 1, sz, fg);
}

fn drawCloseGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 8 or bh < 8) return;
    const cx = bx + @divTrunc(bw, 2);
    const cy = by + @divTrunc(bh, 2);
    const arm: i32 = @min(5, @max(3, @divTrunc(@min(bw, bh), 2) - 3));
    var d: i32 = -arm;
    while (d <= arm) : (d += 1) {
        fb.putPixel32(@intCast(cx + d), @intCast(cy + d), fg);
        fb.putPixel32(@intCast(cx + d), @intCast(cy - d), fg);
    }
}

// ── 每窗口状态 ─────────────────────────────────────────────────────────────

const MAX_SLOTS: usize = 5;

const CalcOp = enum { none, add, sub, mul, div };

var calc_acc: i64 = 0;
var calc_cur: i64 = 0;
var calc_op: CalcOp = .none;
var calc_display: [24]u8 = [_]u8{0} ** 24;
var calc_display_len: usize = 1;

var notepad_buf: [4096]u8 = [_]u8{' '} ** 4096;
var notepad_len: usize = 0;

var wordpad_buf: [8192]u8 = [_]u8{' '} ** 8192;
var wordpad_len: usize = 0;

var snip_have_a: bool = false;
var snip_ax: i32 = 0;
var snip_ay: i32 = 0;

var sol_stack: [13]u8 = undefined;
var sol_len: u8 = 0;
var sol_need: u8 = 1;

var spider_stack: [10]u8 = undefined;
var spider_len: u8 = 0;
var spider_need: u8 = 1;

var narr_last_focus_app: BuiltinAppId = .generic_stub;

fn narrOnFocus(app: BuiltinAppId) void {
    if (app == narr_last_focus_app) return;
    narr_last_focus_app = app;
    klog.info("Narrator cue: %s", .{titleOf(app)});
}

fn lcgNext(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn solitaireReset() void {
    var i: u8 = 0;
    while (i < 13) : (i += 1) {
        sol_stack[i] = i + 1;
    }
    sol_len = 13;
    sol_need = 1;
    var s: u32 = 0xC001D00D ^ @as(u32, @intCast(@intFromPtr(&sol_len)));
    var n: u8 = 13;
    while (n > 1) {
        n -= 1;
        const j = @as(u8, @truncate(lcgNext(&s) % (n + 1)));
        const t = sol_stack[n];
        sol_stack[n] = sol_stack[j];
        sol_stack[j] = t;
    }
}

fn spiderReset() void {
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        spider_stack[i] = i + 1;
    }
    spider_len = 10;
    spider_need = 1;
    var s: u32 = 0x501D3000 ^ @as(u32, @intCast(@intFromPtr(&spider_len)));
    var n: u8 = 10;
    while (n > 1) {
        n -= 1;
        const j = @as(u8, @truncate(lcgNext(&s) % (n + 1)));
        const t = spider_stack[n];
        spider_stack[n] = spider_stack[j];
        spider_stack[j] = t;
    }
}

const PAINT_W: i32 = 200;
const PAINT_H: i32 = 120;
var paint_pix: [(@as(usize, @intCast(PAINT_W)) * @as(usize, @intCast(PAINT_H)))]u8 = [_]u8{0xFF} ** (@as(usize, @intCast(PAINT_W)) * @as(usize, @intCast(PAINT_H)));
var paint_down: bool = false;

const MS_GRID: usize = 8;
var ms_mine: [MS_GRID * MS_GRID]bool = [_]bool{false} ** (MS_GRID * MS_GRID);
var ms_open: [MS_GRID * MS_GRID]bool = [_]bool{false} ** (MS_GRID * MS_GRID);
var ms_dead: bool = false;
var ms_inited: bool = false;

var charmap_page: u32 = 0;
var charmap_sel: u21 = 'A';

fn minesInit() void {
    if (ms_inited) return;
    ms_inited = true;
    var i: usize = 0;
    while (i < ms_mine.len) : (i += 1) {
        ms_mine[i] = (i % 7 == 0 or i % 11 == 0) and i != 0;
        ms_open[i] = false;
    }
    ms_dead = false;
}

fn calcFmt() void {
    var v = calc_cur;
    const neg = v < 0;
    if (neg) v = -v;
    var tmp: [22]u8 = undefined;
    var k: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        k = 1;
    } else {
        var n = v;
        while (n > 0) : (n = @divTrunc(n, 10)) {
            tmp[k] = @as(u8, @intCast(@rem(n, 10))) + '0';
            k += 1;
        }
        var a: usize = 0;
        var b = k;
        while (a < b) {
            b -= 1;
            const t2 = tmp[a];
            tmp[a] = tmp[b];
            tmp[b] = t2;
            a += 1;
        }
    }
    calc_display_len = 0;
    if (neg and calc_display_len < calc_display.len) {
        calc_display[calc_display_len] = '-';
        calc_display_len += 1;
    }
    var j: usize = 0;
    while (j < k and calc_display_len < calc_display.len) : (j += 1) {
        calc_display[calc_display_len] = tmp[j];
        calc_display_len += 1;
    }
    if (calc_display_len == 0) {
        calc_display[0] = '0';
        calc_display_len = 1;
    }
}

fn calcApplyOp() void {
    switch (calc_op) {
        .none => calc_acc = calc_cur,
        .add => calc_acc +%= calc_cur,
        .sub => calc_acc -%= calc_cur,
        .mul => calc_acc *%= calc_cur,
        .div => {
            if (calc_cur == 0) calc_acc = 0 else calc_acc = @divTrunc(calc_acc, calc_cur);
        },
    }
    calc_cur = calc_acc;
    calcFmt();
}

const WinSlot = struct {
    open: bool = false,
    app: BuiltinAppId = .generic_stub,
    x: i32 = 40,
    y: i32 = 48,
    cap_hover: AeroCaptionBtnHover = .none,
};

var slots: [MAX_SLOTS]WinSlot = [_]WinSlot{.{}} ** MAX_SLOTS;
var drag_slot: ?usize = null;
var drag_off_x: i32 = 0;
var drag_off_y: i32 = 0;
var drag_prev: ShellRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var focused_slot: usize = 0;

pub fn getDragState() struct { active: bool, prev: ShellRect } {
    return .{ .active = drag_slot != null, .prev = drag_prev };
}

/// 与 `display.setTaskMgrDragPrev` 同理：每帧 patch 壁纸后将 prev 推进到当前几何，供下一帧 dirty 并集。
pub fn advanceBuiltinDragPrev() void {
    if (drag_slot) |si| {
        if (slots[si].open)
            drag_prev = .{ .x = slots[si].x, .y = slots[si].y, .w = DEF_W, .h = DEF_H };
    }
}

pub fn topDraggedWindowRect() ?ShellRect {
    if (drag_slot) |si| {
        if (!slots[si].open) return null;
        return .{ .x = slots[si].x, .y = slots[si].y, .w = DEF_W, .h = DEF_H };
    }
    return null;
}

pub fn isDragging() bool {
    return drag_slot != null;
}

pub fn onMouseRelease() void {
    paint_down = false;
    drag_slot = null;
}

/// 返回 true 表示内置窗位置或客户区（画图笔划）有变化，需重绘。
pub fn onMouseMove(x: i32, y: i32, scr_w: i32, scr_h: i32, tb_h: i32) bool {
    updateCaptionHover(x, y);
    var dirty = false;
    if (drag_slot) |si| {
        if (!slots[si].open) {
            drag_slot = null;
        } else {
            const ox = slots[si].x;
            const oy = slots[si].y;
            const nx = x - drag_off_x;
            const ny = y - drag_off_y;
            const pad: i32 = 2;
            const cx = @max(pad, @min(nx, scr_w - pad - DEF_W));
            const cy = @max(pad, @min(ny, scr_h - tb_h - DEF_H - pad));
            slots[si].x = cx;
            slots[si].y = cy;
            if (ox != cx or oy != cy) dirty = true;
        }
    }
    if (paint_down) {
        paintStrokeAt(x, y);
        dirty = true;
    }
    return dirty;
}

fn paintStrokeAt(px: i32, py: i32) void {
    const si = focused_slot;
    if (si >= slots.len or !slots[si].open or slots[si].app != .paint) return;
    const wx = slots[si].x;
    const wy = slots[si].y + CAPTION_H + 40;
    const lx = px - wx - 8;
    const ly = py - wy - 8;
    if (lx < 0 or ly < 0 or lx >= PAINT_W or ly >= PAINT_H) return;
    const ux: usize = @intCast(lx);
    const uy: usize = @intCast(ly);
    const idx = uy * @as(usize, @intCast(PAINT_W)) + ux;
    if (idx < paint_pix.len) paint_pix[idx] = 0x20;
}

pub fn updateCaptionHover(px: i32, py: i32) void {
    for (&slots) |*s| {
        s.cap_hover = .none;
    }
    var s: usize = MAX_SLOTS;
    while (s > 0) {
        s -= 1;
        if (!slots[s].open) continue;
        const w = slots[s];
        if (px >= w.x and px < w.x + DEF_W and py >= w.y and py < w.y + CAPTION_H) {
            slots[s].cap_hover = hitTestCaption(px, py, w.x, w.y, DEF_W, CAPTION_H);
            return;
        }
    }
}

pub fn captionHoverForTopmost(px: i32, py: i32) AeroCaptionBtnHover {
    var s: usize = MAX_SLOTS;
    while (s > 0) {
        s -= 1;
        if (!slots[s].open) continue;
        const w = slots[s];
        if (px >= w.x and px < w.x + DEF_W and py >= w.y and py < w.y + CAPTION_H) {
            return hitTestCaption(px, py, w.x, w.y, DEF_W, CAPTION_H);
        }
    }
    return .none;
}

/// 返回 true 表示已消费点击（含标题栏）。
pub fn handleClick(px: i32, py: i32, scr_w: i32, scr_h: i32, tb_h: i32) bool {
    _ = scr_w;
    _ = scr_h;
    // 顶槽优先
    var s: isize = @as(isize, @intCast(MAX_SLOTS)) - 1;
    while (s >= 0) : (s -= 1) {
        const si: usize = @intCast(s);
        if (!slots[si].open) continue;
        const w = slots[si];
        if (px < w.x or px >= w.x + DEF_W or py < w.y or py >= w.y + DEF_H) continue;

        focused_slot = si;
        narrOnFocus(slots[si].app);
        if (py < w.y + CAPTION_H) {
            const h = hitTestCaption(px, py, w.x, w.y, DEF_W, CAPTION_H);
            switch (h) {
                .close => {
                    slots[si].open = false;
                    klog.info("builtin: close %s", .{titleOf(w.app)});
                },
                .minimize, .maximize => klog.info("builtin: min/max stub", .{}),
                .none => {
                    drag_slot = si;
                    drag_off_x = px - w.x;
                    drag_off_y = py - w.y;
                    drag_prev = .{ .x = w.x, .y = w.y, .w = DEF_W, .h = DEF_H };
                },
            }
            return true;
        }
        handleClientClick(si, px, py, tb_h);
        return true;
    }
    return false;
}

fn handleClientClick(si: usize, px: i32, py: i32, tb_h: i32) void {
    const w = slots[si];
    const cx = w.x + 6;
    const cy = w.y + CAPTION_H + 6;
    switch (w.app) {
        .calculator => calcClick(cx, cy, px, py),
        .minesweeper => msClick(cx, cy, px, py),
        .osk => oskClick(cx, cy, px, py),
        .charmap => charmapClick(cx, cy, px, py),
        .notepad => notepadClick(si, px, py),
        .wordpad => wordpadClick(si, px, py),
        .snipping_tool => snippingClick(si, px, py),
        .solitaire => solitaireClick(si, px, py),
        .spider_solitaire => spiderSolitaireClick(si, px, py),
        .compmgmt => compmgmtClick(px, py),
        .paint => {
            _ = tb_h;
            paint_down = true;
            paintStrokeAt(px, py);
        },
        else => {},
    }
}

fn notepadClick(si: usize, px: i32, py: i32) void {
    const w = slots[si];
    const btn_top = w.y + DEF_H - 26;
    if (py < btn_top or py >= w.y + DEF_H - 4) return;
    const mid = w.x + @divTrunc(DEF_W, 2);
    if (px < mid) {
        _ = FileDialog.openText(demo_notepad_vfs_path);
    } else {
        _ = FileDialog.saveText(demo_notepad_vfs_path, notepad_buf[0..notepad_len]);
    }
}

fn wordpadClick(si: usize, px: i32, py: i32) void {
    const w = slots[si];
    const btn_top = w.y + DEF_H - 26;
    if (py < btn_top or py >= w.y + DEF_H - 4) return;
    const mid = w.x + @divTrunc(DEF_W, 2);
    if (px < mid) {
        _ = FileDialog.openTextWordpad(demo_notepad_vfs_path);
    } else {
        _ = FileDialog.saveTextWordpad(demo_notepad_vfs_path);
    }
}

fn snippingClick(si: usize, px: i32, py: i32) void {
    _ = si;
    if (!snip_have_a) {
        snip_ax = px;
        snip_ay = py;
        snip_have_a = true;
        klog.info("Snipping: first corner", .{});
        return;
    }
    const x0 = @min(snip_ax, px);
    const y0 = @min(snip_ay, py);
    const x1 = @max(snip_ax, px);
    const y1 = @max(snip_ay, py);
    var rw = x1 - x0;
    var rh = y1 - y0;
    if (rw <= 0 or rh <= 0) {
        snip_have_a = false;
        return;
    }
    const max_w: i32 = 320;
    const max_h: i32 = 200;
    if (rw > max_w) rw = max_w;
    if (rh > max_h) rh = max_h;
    var buf: [clip_dib_cap_bytes]u8 = undefined;
    const n = fb.copyDrawBufferRectBytes(x0, y0, rw, rh, &buf);
    if (n > 0) {
        getClipboard().setDibBgr32(@intCast(rw), @intCast(rh), buf[0..n]);
        klog.info("Snipping: DIB stub to clipboard", .{});
    }
    snip_have_a = false;
}

fn solitaireClick(si: usize, px: i32, py: i32) void {
    const w = slots[si];
    if (!w.open or w.app != .solitaire) return;
    const pile_x0 = w.x + 12;
    const pile_y0 = w.y + CAPTION_H + 80;
    if (px < pile_x0 or px >= pile_x0 + 100 or py < pile_y0 or py >= pile_y0 + 100) return;
    if (sol_len == 0) return;
    const top = sol_stack[sol_len - 1];
    if (top == sol_need) {
        sol_len -= 1;
        sol_need += 1;
        if (sol_need == 14) klog.info("Solitaire: ordered stack complete", .{});
    } else {
        klog.info("Solitaire: need %u, top %u", .{ sol_need, top });
    }
}

fn spiderSolitaireClick(si: usize, px: i32, py: i32) void {
    const w = slots[si];
    if (!w.open or w.app != .spider_solitaire) return;
    const pile_x0 = w.x + 12;
    const pile_y0 = w.y + CAPTION_H + 80;
    if (px < pile_x0 or px >= pile_x0 + 100 or py < pile_y0 or py >= pile_y0 + 100) return;
    if (spider_len == 0) return;
    const top = spider_stack[spider_len - 1];
    if (top == spider_need) {
        spider_len -= 1;
        spider_need += 1;
        if (spider_need == 11) klog.info("Spider mini: stack complete", .{});
    } else {
        klog.info("Spider: need %u, top %u", .{ spider_need, top });
    }
}

fn compmgmtClick(_: i32, py: i32) void {
    var s: usize = MAX_SLOTS;
    while (s > 0) {
        s -= 1;
        if (!slots[s].open or slots[s].app != .compmgmt) continue;
        const w = slots[s];
        const cy = py - w.y - CAPTION_H;
        if (cy >= 32 and cy < 52) {
            launch(.eventvwr);
            return;
        }
        if (cy >= 52 and cy < 74) {
            launch(.devmgmt);
            return;
        }
        return;
    }
}

fn calcClick(cx: i32, cy: i32, px: i32, py: i32) void {
    const bw: i32 = 44;
    const bh: i32 = 32;
    const gap: i32 = 4;
    var row: i32 = 0;
    while (row < 4) : (row += 1) {
        var col: i32 = 0;
        while (col < 4) : (col += 1) {
            const bx = cx + col * (bw + gap);
            const by = cy + 40 + row * (bh + gap);
            if (px >= bx and px < bx + bw and py >= by and py < by + bh) {
                calcKey(@intCast(row), @intCast(col));
                return;
            }
        }
    }
}

fn calcKey(row: u8, col: u8) void {
    const keys = [_][4]u8{
        .{ '7', '8', '9', '/' },
        .{ '4', '5', '6', '*' },
        .{ '1', '2', '3', '-' },
        .{ 'C', '0', '=', '+' },
    };
    const ch = keys[row][col];
    switch (ch) {
        '0'...'9' => {
            const d: i64 = ch - '0';
            if (calc_cur <= 999_999_999) calc_cur = calc_cur * 10 + d;
            calcFmt();
        },
        '+' => {
            calcApplyOp();
            calc_op = .add;
            calc_cur = 0;
            calc_display[0] = '0';
            calc_display_len = 1;
        },
        '-' => {
            calcApplyOp();
            calc_op = .sub;
            calc_cur = 0;
            calc_display[0] = '0';
            calc_display_len = 1;
        },
        '*' => {
            calcApplyOp();
            calc_op = .mul;
            calc_cur = 0;
            calc_display[0] = '0';
            calc_display_len = 1;
        },
        '/' => {
            calcApplyOp();
            calc_op = .div;
            calc_cur = 0;
            calc_display[0] = '0';
            calc_display_len = 1;
        },
        '=' => {
            calcApplyOp();
            calc_op = .none;
        },
        'C' => {
            calc_cur = 0;
            calc_acc = 0;
            calc_op = .none;
            calc_display[0] = '0';
            calc_display_len = 1;
        },
        else => {},
    }
}

fn msClick(cx: i32, cy: i32, px: i32, py: i32) void {
    minesInit();
    const cell: i32 = 22;
    const gx = @divTrunc(px - cx, cell);
    const gy = @divTrunc(py - cy, cell);
    if (gx < 0 or gy < 0 or gx >= MS_GRID or gy >= MS_GRID) return;
    const idx: usize = @intCast(@as(i64, gy) * MS_GRID + @as(i64, gx));
    if (ms_dead) return;
    if (ms_mine[idx]) {
        ms_dead = true;
        return;
    }
    ms_open[idx] = true;
}

fn oskClick(cx: i32, cy: i32, px: i32, py: i32) void {
    const arch_mod = @import("../../arch.zig");
    const keys = "1234567890QWERTYUIOPASDFGHJKLZXCVBNM";
    const kw: i32 = 22;
    const kh: i32 = 20;
    var i: usize = 0;
    while (i < keys.len) : (i += 1) {
        const col = @as(i32, @intCast(i % 10));
        const row = @as(i32, @intCast(i / 10));
        const bx = cx + col * (kw + 2);
        const by = cy + 30 + row * (kh + 2);
        if (px >= bx and px < bx + kw and py >= by and py < by + kh) {
            const ch = keys[i];
            var one: [1]u8 = .{ch};
            getClipboard().setText(&one);
            const inject_ch: u8 = if (ch >= 'A' and ch <= 'Z') ch - 'A' + 'a' else ch;
            arch_mod.injectSyntheticChar(inject_ch);
            klog.info("OSK: clip + inject input ring", .{});
            return;
        }
    }
}

fn charmapClick(cx: i32, cy: i32, px: i32, py: i32) void {
    const cell: i32 = 18;
    const cols: i32 = 16;
    const base: u32 = charmap_page * 256;
    var gy: i32 = 0;
    while (gy < 8) : (gy += 1) {
        var gx: i32 = 0;
        while (gx < cols) : (gx += 1) {
            const bx = cx + gx * cell;
            const by = cy + 24 + gy * cell;
            if (px >= bx and px < bx + cell - 1 and py >= by and py < by + cell - 1) {
                const code: u32 = base + @as(u32, @intCast(gy * cols + gx));
                if (code <= 0x10FFFF) {
                    charmap_sel = @truncate(code);
                    var utf8: [4]u8 = undefined;
                    const n = encodeUtf8Char(charmap_sel, &utf8);
                    getClipboard().setText(utf8[0..n]);
                }
                return;
            }
        }
    }
}

fn encodeUtf8Char(cp: u21, out: *[4]u8) usize {
    if (cp < 0x80) {
        out[0] = @truncate(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @truncate(0xC0 | (cp >> 6));
        out[1] = @truncate(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @truncate(0xE0 | (cp >> 12));
        out[1] = @truncate(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @truncate(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @truncate(0xF0 | (cp >> 18));
    out[1] = @truncate(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @truncate(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @truncate(0x80 | (cp & 0x3F));
    return 4;
}

pub fn launch(id: BuiltinAppId) void {
    if (id == .taskmgr_focus) {
        klog.info("builtin: Task Manager — Ctrl+Shift+Esc or tray", .{});
        return;
    }
    var free: ?usize = null;
    for (&slots, 0..) |*sl, i| {
        if (!sl.open) {
            free = i;
            break;
        }
    }
    const si = free orelse blk: {
        slots[0].open = false;
        break :blk 0;
    };
    slots[si] = .{
        .open = true,
        .app = id,
        .x = 48 + @as(i32, @intCast(si * 28)),
        .y = 52 + @as(i32, @intCast(si * 24)),
        .cap_hover = .none,
    };
    focused_slot = si;
    if (id == .calculator) {
        calc_cur = 0;
        calc_acc = 0;
        calc_op = .none;
        calc_display[0] = '0';
        calc_display_len = 1;
    }
    if (id == .minesweeper) {
        ms_inited = false;
        minesInit();
    }
    if (id == .notepad and notepad_len == 0) {
        const greet = "ZirconOS Notepad — type text; bottom: Open/Save C:\\NOTEPAD.TXT (VFS).";
        @memcpy(notepad_buf[0..greet.len], greet);
        notepad_len = greet.len;
    }
    if (id == .wordpad and wordpad_len == 0) {
        const greet = "WordPad — plain text full(min). RTF subset: planned. Open/Save same demo path.";
        @memcpy(wordpad_buf[0..greet.len], greet);
        wordpad_len = greet.len;
    }
    if (id == .snipping_tool) snip_have_a = false;
    if (id == .solitaire) solitaireReset();
    if (id == .spider_solitaire) spiderReset();
    narrOnFocus(slots[si].app);
    klog.info("builtin: launch %s", .{titleOf(id)});
}

/// 从 PS/2 / VirtIO 环取字符，写入聚焦记事本类窗口。
pub fn pollKeyboardToFocused() bool {
    const arch_mod = @import("../../arch.zig");
    var dirty = false;
    while (arch_mod.readInputChar()) |c| {
        if (!slots[focused_slot].open) continue;
        const app = slots[focused_slot].app;
        if (app != .notepad and app != .wordpad) continue;
        if (app == .notepad) {
            if (c == 0x08) {
                if (notepad_len > 0) {
                    notepad_len -= 1;
                    dirty = true;
                }
            } else if (c >= 32 and c < 127 and notepad_len + 1 < notepad_buf.len) {
                notepad_buf[notepad_len] = c;
                notepad_len += 1;
                dirty = true;
            }
        } else {
            if (c == 0x08) {
                if (wordpad_len > 0) {
                    wordpad_len -= 1;
                    dirty = true;
                }
            } else if (c >= 32 and c < 127 and wordpad_len + 1 < wordpad_buf.len) {
                wordpad_buf[wordpad_len] = c;
                wordpad_len += 1;
                dirty = true;
            }
        }
    }
    return dirty;
}

pub const RenderMode = enum { normal, drag_light };

/// 绘制 Shell 托管的内置应用窗口层（开始菜单「所有程序」缩略窗格等）。
pub fn renderShellHostedApps(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors, mode: RenderMode) void {
    _ = scr_w;
    _ = scr_h;
    for (&slots, 0..) |*w, i| {
        if (!w.open) continue;
        const light = mode == .drag_light and drag_slot == i;
        if (light) renderOneWindowLight(w, t) else renderOneWindow(w, t);
    }
}

fn renderOneWindowLight(w: *WinSlot, t: *const theme.ThemeColors) void {
    const wx = w.x;
    const wy = w.y;
    fb.fillRect(wx + 3, wy + 3, DEF_W, DEF_H, rgb(0x30, 0x30, 0x30));
    fb.fillRect(wx, wy + CAPTION_H, DEF_W, DEF_H - CAPTION_H, t.window_bg);
    const dwm = @import("dwm.zig");
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassTintOnly(wx, wy, DEF_W, CAPTION_H, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(wx, wy, DEF_W, CAPTION_H, t.titlebar_active_left, t.titlebar_active_right);
    }
    drawCaptionButtons(wx, wy, DEF_W, CAPTION_H, w.cap_hover);
    fb.drawTextTransparent(wx + 8, wy + 6, titleOf(w.app), t.titlebar_text);
    fb.draw3DRect(wx, wy, DEF_W, DEF_H, rgb(0xC8, 0xD8, 0xE8), rgb(0x40, 0x50, 0x60));
    fb.fillRect(wx + 2, wy + CAPTION_H, DEF_W - 4, DEF_H - CAPTION_H - 2, rgb(0xFE, 0xFE, 0xFF));
}

fn renderOneWindow(w: *WinSlot, t: *const theme.ThemeColors) void {
    const wx = w.x;
    const wy = w.y;
    const dwm = @import("dwm.zig");
    if (dwm.isInitialized() and dwm.getConfig().shadow_enabled) {
        fb.fillRect(wx + 4, wy + 4, DEF_W, DEF_H, rgb(0x28, 0x28, 0x30));
    }
    fb.fillRect(wx, wy + CAPTION_H, DEF_W, DEF_H - CAPTION_H, t.window_bg);
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(wx, wy, DEF_W, CAPTION_H, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(wx, wy, DEF_W, CAPTION_H, t.titlebar_active_left, t.titlebar_active_right);
    }
    drawCaptionButtons(wx, wy, DEF_W, CAPTION_H, w.cap_hover);
    if (iconOf(w.app)) |ic| {
        icons.drawThemedIcon(ic, wx + 6, wy + 6, 1, .aero);
        fb.drawTextTransparent(wx + 30, wy + 6, titleOf(w.app), t.titlebar_text);
    } else {
        fb.drawTextTransparent(wx + 8, wy + 6, titleOf(w.app), t.titlebar_text);
    }
    fb.draw3DRect(wx, wy, DEF_W, DEF_H, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    renderClient(w, t);
}

fn drawEditorLines(x0: i32, y0: i32, body_h: i32, buf: []const u8) void {
    const text_bottom = y0 + body_h - 28;
    var yy: i32 = y0 + 4;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= buf.len) : (i += 1) {
        const brk = i == buf.len or buf[i] == '\n';
        if (brk) {
            fb.drawTextTransparent(x0 + 4, yy, buf[line_start..i], rgb(0x10, 0x10, 0x18));
            yy += 14;
            line_start = i + 1;
            if (yy > text_bottom) break;
        }
    }
}

fn drawOpenSaveFooter(x0: i32, y0: i32, body_w: i32, body_h: i32) void {
    const yy = y0 + body_h - 22;
    fb.drawHLine(x0 + 4, yy - 3, body_w - 8, rgb(0xB8, 0xC0, 0xCC));
    const hw = @divTrunc(body_w - 20, 2);
    fb.fillRect(x0 + 6, yy, hw - 4, 18, rgb(0xE4, 0xE8, 0xF0));
    fb.drawRect(x0 + 6, yy, hw - 4, 18, rgb(0x90, 0x98, 0xA8));
    fb.drawTextTransparent(x0 + 12, yy + 4, "Open", rgb(0x18, 0x20, 0x30));
    fb.fillRect(x0 + 8 + hw, yy, hw - 4, 18, rgb(0xE4, 0xE8, 0xF0));
    fb.drawRect(x0 + 8 + hw, yy, hw - 4, 18, rgb(0x90, 0x98, 0xA8));
    fb.drawTextTransparent(x0 + 14 + hw, yy + 4, "Save", rgb(0x18, 0x20, 0x30));
}

fn renderControlPanel(x0: i32, y0: i32, t: *const theme.ThemeColors) void {
    _ = t;
    const fg = rgb(0x22, 0x2C, 0x3C);
    var yy: i32 = y0 + 6;
    const lines = [_][]const u8{
        "System and Security",
        "  Zircon Update, Security (stubs)",
        "Network and Internet",
        "  (stubs)",
        "Hardware and Sound",
        "  (stubs)",
        "Programs",
        "  Default Programs -> shell link",
    };
    for (lines) |ln| {
        fb.drawTextTransparent(x0 + 4, yy, ln, fg);
        yy += 14;
    }
}

fn renderClient(w: *WinSlot, t: *const theme.ThemeColors) void {
    const x0 = w.x + 4;
    const y0 = w.y + CAPTION_H + 4;
    const body_w = DEF_W - 8;
    const body_h = DEF_H - CAPTION_H - 8;
    fb.fillRect(x0, y0, body_w, body_h, rgb(0xFA, 0xFA, 0xFC));
    switch (w.app) {
        .notepad => {
            drawEditorLines(x0, y0, body_h, notepad_buf[0..notepad_len]);
            drawOpenSaveFooter(x0, y0, body_w, body_h);
        },
        .wordpad => {
            drawEditorLines(x0, y0, body_h, wordpad_buf[0..wordpad_len]);
            drawOpenSaveFooter(x0, y0, body_w, body_h);
        },
        .calculator => {
            fb.fillRect(x0 + 4, y0 + 4, body_w - 8, 28, rgb(0xE8, 0xEC, 0xF0));
            fb.drawTextTransparent(x0 + 8, y0 + 10, calc_display[0..calc_display_len], rgb(0x10, 0x18, 0x28));
            const bw: i32 = 44;
            const bh: i32 = 32;
            const gap: i32 = 4;
            const keys = [_][4]u8{
                .{ '7', '8', '9', '/' },
                .{ '4', '5', '6', '*' },
                .{ '1', '2', '3', '-' },
                .{ 'C', '0', '=', '+' },
            };
            var row: i32 = 0;
            while (row < 4) : (row += 1) {
                var col: i32 = 0;
                while (col < 4) : (col += 1) {
                    const bx = x0 + 6 + col * (bw + gap);
                    const by = y0 + 44 + row * (bh + gap);
                    fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0x88, 0x88, 0x90));
                    fb.fillRect(bx + 1, by + 1, bw - 2, bh - 2, rgb(0xE4, 0xE8, 0xF0));
                    var ch: [1]u8 = .{keys[@intCast(row)][@intCast(col)]};
                    fb.drawTextTransparent(bx + 16, by + 10, &ch, rgb(0x20, 0x20, 0x28));
                }
            }
        },
        .paint => {
            const px0 = x0 + 6;
            const py0 = y0 + 32;
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Pencil on white (drag)", rgb(0x40, 0x40, 0x50));
            fb.draw3DRect(px0, py0, PAINT_W + 2, PAINT_H + 2, rgb(0x80, 0x80, 0x88), rgb(0xD0, 0xD0, 0xD8));
            var yy: i32 = 0;
            while (yy < PAINT_H) : (yy += 1) {
                var xx: i32 = 0;
                while (xx < PAINT_W) : (xx += 1) {
                    const v = paint_pix[@intCast(yy * PAINT_W + xx)];
                    const c = rgb(v, v, v);
                    fb.fillRect(px0 + 1 + xx, py0 + 1 + yy, 1, 1, c);
                }
            }
        },
        .minesweeper => {
            minesInit();
            fb.drawTextTransparent(x0 + 4, y0 + 4, if (ms_dead) "BOOM — click menu to reopen" else "Left-click safe cells", rgb(0x30, 0x40, 0x58));
            const cell: i32 = 22;
            var gy: i32 = 0;
            while (gy < MS_GRID) : (gy += 1) {
                var gx: i32 = 0;
                while (gx < MS_GRID) : (gx += 1) {
                    const idx: usize = @intCast(@as(i64, gy) * MS_GRID + @as(i64, gx));
                    const bx = x0 + 8 + gx * cell;
                    const by = y0 + 28 + gy * cell;
                    if (ms_open[idx]) {
                        fb.fillRect(bx, by, cell - 1, cell - 1, rgb(0xD8, 0xDC, 0xE4));
                        if (ms_mine[idx]) {
                            fb.fillRect(bx + 4, by + 4, cell - 9, cell - 9, rgb(0xC0, 0x20, 0x20));
                        }
                    } else {
                        fb.draw3DRect(bx, by, cell - 1, cell - 1, rgb(0xFF, 0xFF, 0xFF), rgb(0x70, 0x70, 0x78));
                    }
                }
            }
        },
        .osk => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Key: UTF-8 text clip + inject input ring (inputdev)", rgb(0x40, 0x48, 0x55));
            const keys = "1234567890QWERTYUIOPASDFGHJKLZXCVBNM";
            const kw: i32 = 22;
            const kh: i32 = 20;
            var i: usize = 0;
            while (i < keys.len) : (i += 1) {
                const col = @as(i32, @intCast(i % 10));
                const row = @as(i32, @intCast(i / 10));
                const bx = x0 + 6 + col * (kw + 2);
                const by = y0 + 28 + row * (kh + 2);
                fb.draw3DRect(bx, by, kw, kh, rgb(0xFF, 0xFF, 0xFF), rgb(0x88, 0x88, 0x90));
                var ch: [1]u8 = .{keys[i]};
                fb.drawTextTransparent(bx + 7, by + 5, &ch, rgb(0x20, 0x20, 0x28));
            }
        },
        .charmap => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Click cell — UTF-8 to clipboard", rgb(0x40, 0x48, 0x55));
            const cell: i32 = 18;
            const cols: i32 = 16;
            const base: u32 = charmap_page * 256;
            var gy: i32 = 0;
            while (gy < 8) : (gy += 1) {
                var gx: i32 = 0;
                while (gx < cols) : (gx += 1) {
                    const bx = x0 + 4 + gx * cell;
                    const by = y0 + 22 + gy * cell;
                    const code: u32 = base + @as(u32, @intCast(gy * cols + gx));
                    fb.draw3DRect(bx, by, cell - 1, cell - 1, rgb(0xEE, 0xEE, 0xF2), rgb(0x90, 0x90, 0x98));
                    if (code >= 32 and code < 127) {
                        var ch: [1]u8 = .{@truncate(code)};
                        fb.drawTextTransparent(bx + 4, by + 3, &ch, rgb(0x20, 0x20, 0x28));
                    }
                }
            }
        },
        .snipping_tool => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Click two screen corners; ROI -> clipboard DIB stub (320x200 max).", rgb(0x38, 0x40, 0x50));
            if (snip_have_a) {
                fb.drawTextTransparent(x0 + 4, y0 + 22, "First corner set — click second.", rgb(0x60, 0x68, 0x78));
            }
        },
        .magnifier => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "ROI x3 nearest (draw buffer)", rgb(0x40, 0x48, 0x55));
            const mx = mouse.getX();
            const my = mouse.getY();
            const rw: i32 = 40;
            const rh: i32 = 30;
            const z: i32 = 3;
            var src: [40 * 30 * 4]u8 = undefined;
            const got = fb.copyDrawBufferRectBytes(mx - rw / 2, my - rh / 2, rw, rh, &src);
            if (got != 0) {
                const dx0 = x0 + 8;
                const dy0 = y0 + 24;
                var uy: i32 = 0;
                while (uy < rh * z) : (uy += 1) {
                    var ux: i32 = 0;
                    while (ux < rw * z) : (ux += 1) {
                        const sx = @divTrunc(ux, z);
                        const sy = @divTrunc(uy, z);
                        const si_b = @as(usize, @intCast(sy)) * @as(usize, @intCast(rw)) * 4 + @as(usize, @intCast(sx)) * 4;
                        if (si_b + 3 >= src.len) continue;
                        const c = rgb(src[si_b + 2], src[si_b + 1], src[si_b]);
                        fb.fillRect(dx0 + ux, dy0 + uy, 1, 1, c);
                    }
                }
            }
        },
        .narrator => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "No TTS: focus changes logged as Narrator cues (klog).", rgb(0x38, 0x40, 0x50));
        },
        .sync_center => {
            const nout: u32 = @intCast(if (hdmi.isInitialized()) hdmi.getOutputCount() else 1);
            var nb: [72]u8 = undefined;
            const msg = std.fmt.bufPrint(&nb, "Outputs: {d} (hdmi.zig; IOCTL_DISPLAY_ENUMERATE)", .{nout}) catch "Outputs: ?";
            fb.drawTextTransparent(x0 + 4, y0 + 6, msg, rgb(0x28, 0x30, 0x40));
            fb.drawTextTransparent(x0 + 4, y0 + 24, "Sync providers: not wired.", rgb(0x50, 0x58, 0x64));
        },
        .projector => {
            const nout: u32 = @intCast(if (hdmi.isInitialized()) hdmi.getOutputCount() else 1);
            var nb: [72]u8 = undefined;
            const msg = std.fmt.bufPrint(&nb, "Duplicate / projector: {d} output(s) reported.", .{nout}) catch "Projector: ?";
            fb.drawTextTransparent(x0 + 4, y0 + 6, msg, rgb(0x28, 0x30, 0x40));
        },
        .wmp => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "No kernel PCM/WAV buffer yet — decoder HAL later.", rgb(0x30, 0x38, 0x48));
            fb.drawTextTransparent(x0 + 4, y0 + 24, "See roadmap: WMP partial when audio path exists.", rgb(0x58, 0x60, 0x70));
        },
        .sound_recorder => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "Capture IOCTL stub — idle VU (decorative).", rgb(0x30, 0x38, 0x48));
            var i: u32 = 0;
            while (i < 12) : (i += 1) {
                const h: i32 = 10 + @as(i32, @intCast((i * 7) % 23));
                fb.fillRect(x0 + 10 + @as(i32, @intCast(i * 18)), y0 + 100 - h, 14, @intCast(h), rgb(0x58, 0xA8, 0x68));
            }
        },
        .control_panel => renderControlPanel(x0, y0, t),
        .eventvwr => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "Application log: ring buffer TBD", rgb(0x28, 0x30, 0x40));
            fb.drawTextTransparent(x0 + 4, y0 + 22, "System: boot events (stub)", rgb(0x28, 0x30, 0x40));
            fb.drawTextTransparent(x0 + 4, y0 + 38, "Security: Se audit channel (future)", rgb(0x28, 0x30, 0x40));
        },
        .devmgmt => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "Root\\PCI — ECAM-capable arches: pcie.zig", rgb(0x28, 0x30, 0x40));
            fb.drawTextTransparent(x0 + 4, y0 + 22, "VirtIO / QEMU devices when bus scan runs.", rgb(0x40, 0x48, 0x55));
        },
        .compmgmt => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "MMC-style launcher (click row)", rgb(0x28, 0x30, 0x40));
            fb.drawTextTransparent(x0 + 4, y0 + 32, "> Event Viewer", rgb(0x20, 0x50, 0x90));
            fb.drawTextTransparent(x0 + 4, y0 + 52, "> Device Manager", rgb(0x20, 0x50, 0x90));
        },
        .regedit => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "HKLM\\SOFTWARE\\ZirconOS\\Status = Running", t.titlebar_text);
            fb.drawTextTransparent(x0 + 4, y0 + 22, "HKCU\\ZirconOS\\DemoValue = 1 (read-only tree)", rgb(0x28, 0x30, 0x40));
        },
        .solitaire => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Order stack: click pile when top == next (1..13).", rgb(0x30, 0x38, 0x48));
            var nb: [48]u8 = undefined;
            const st: []const u8 = if (sol_len == 0)
                "Done — reshuffle from Start."
            else blk: {
                const top = sol_stack[sol_len - 1];
                break :blk std.fmt.bufPrint(&nb, "Top {d}  need {d}", .{ top, sol_need }) catch "pile";
            };
            fb.drawTextTransparent(x0 + 4, y0 + 22, st, rgb(0x18, 0x20, 0x30));
            fb.draw3DRect(x0 + 10, y0 + 78, 100, 100, rgb(0x88, 0x90, 0x98), rgb(0xD0, 0xD8, 0xE0));
            fb.fillRect(x0 + 12, y0 + 80, 96, 96, rgb(0xF0, 0xF4, 0xFA));
        },
        .spider_solitaire => {
            fb.drawTextTransparent(x0 + 4, y0 + 4, "Spider mini: order 1..10 (subset rules).", rgb(0x30, 0x38, 0x48));
            var nb: [48]u8 = undefined;
            const st: []const u8 = if (spider_len == 0)
                "Done."
            else blk: {
                const top = spider_stack[spider_len - 1];
                break :blk std.fmt.bufPrint(&nb, "Top {d}  need {d}", .{ top, spider_need }) catch "pile";
            };
            fb.drawTextTransparent(x0 + 4, y0 + 22, st, rgb(0x18, 0x20, 0x30));
            fb.draw3DRect(x0 + 10, y0 + 78, 100, 100, rgb(0x88, 0x90, 0x98), rgb(0xD0, 0xD8, 0xE0));
            fb.fillRect(x0 + 12, y0 + 80, 96, 96, rgb(0xF0, 0xF4, 0xFA));
        },
        .freecell => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "FreeCell: rules + free cells — planned (see roadmap).", rgb(0x30, 0x38, 0x48));
        },
        .hearts => {
            fb.drawTextTransparent(x0 + 4, y0 + 6, "Hearts: trick-taking game — planned.", rgb(0x30, 0x38, 0x48));
        },
        else => drawStubLines(w.app, x0, y0, body_w, t),
    }
}

fn drawStubLines(id: BuiltinAppId, x0: i32, y0: i32, body_w: i32, t: *const theme.ThemeColors) void {
    _ = t;
    const fg = rgb(0x28, 0x30, 0x40);
    const lines = switch (id) {
        .media_center => "Media Center: low priority shell.",
        .dvd_maker => "DVD Maker: out of scope for this tree.",
        .ie8 => "IE shell: no Trident; pluggable renderer (Gecko/WebKit-class) — policy in roadmap.",
        .live_mail => "Zircon Mail: optional; not in default preload.",
        .fax_scan => "Fax/Scan: TWAIN/WIA concepts (Learn win32/twain, wia_*).",
        .disk_cleanup => "Disk Cleanup: stub — no destructive erase until VFS quota API; see roadmap safety.",
        .defrag => "Defrag: stub — block IOCTL not wired; safe to skip on flash.",
        .backup_restore => "Backup: stub — no VSS; do not assume snapshots exist.",
        .system_restore => "System Restore: stub — SR points not persisted.",
        .resmon => "Resource Monitor: CPU/mem graphs need KE/PS sampling (phase 2).",
        .perfmon => "Performance Monitor: counters TBD (same model as Resmon).",
        .taskschd => "Task Scheduler: job store / triggers not implemented.",
        .cmd_shell => "CMD: full UI in Win32 cmd.zig; this window is a desktop hint only.",
        .powershell_shell => "PowerShell: full UI in powershell.zig; desktop hint only.",
        .chess_titans, .mahjong_titans, .purble_place => "Game: 3D/assets later (planned).",
        .games_internet => "Internet games: planned after network stack.",
        .shell_documents, .shell_pictures, .shell_music, .shell_videos, .shell_downloads => "Use Explorer — Libraries pane.",
        .games_folder => "Games folder: launch from All Programs.",
        .shell_computer, .shell_network => "Use Explorer window (Computer / Network).",
        .shell_devices_printers => "Devices and Printers: spooler TBD.",
        .shell_default_programs => "Default Programs: file assoc TBD.",
        .shell_help => "Help: documentation on host.",
        .shell_run => "Run dialog: shell_execute TBD.",
        .defender => "Zircon Security policy UI — hardening concepts only (no third-party AV path).",
        .firewall => "Firewall policy UI — WDK/WFP public docs (no packet path yet).",
        .windows_update => "Zircon Update: trusted servicing channel TBD — design follows public OS update concepts only.",
        .bitlocker => "BitLocker: enterprise disclaimer; FVE driver TBD — cross-ref src/se (tokens).",
        .uac_info => "UAC: elevation flow TBD — cross-ref src/se/token.zig and security roadmap.",
        .explorer_libraries_hint => "Libraries: Explorer command bar.",
        .generic_stub => "Placeholder window.",
        else => "Built-in stub — see BuiltinApps_NT61_Roadmap.md.",
    };
    fb.drawTextTransparentClipped(x0 + 4, y0 + 6, x0 + body_w - 4, lines, fg);
}

pub fn anyWindowOpen() bool {
    for (slots) |w| {
        if (w.open) return true;
    }
    return false;
}

/// 所有打开的内置窗外包矩形（无打开窗时宽/高为 0）。
pub fn openSlotsBoundsUnion() ShellRect {
    var first = true;
    var u = ShellRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (slots) |s| {
        if (!s.open) continue;
        const r = ShellRect{ .x = s.x, .y = s.y, .w = DEF_W, .h = DEF_H };
        if (first) {
            u = r;
            first = false;
        } else {
            u = shellRectUnion(u, r);
        }
    }
    return u;
}

fn shellRectUnion(a: ShellRect, b: ShellRect) ShellRect {
    const ax2 = @as(i64, a.x) + @as(i64, a.w);
    const ay2 = @as(i64, a.y) + @as(i64, a.h);
    const bx2 = @as(i64, b.x) + @as(i64, b.w);
    const by2 = @as(i64, b.y) + @as(i64, b.h);
    const x0 = @min(@as(i64, a.x), @as(i64, b.x));
    const y0 = @min(@as(i64, a.y), @as(i64, b.y));
    const x1 = @max(ax2, bx2);
    const y1 = @max(ay2, by2);
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
    };
}
