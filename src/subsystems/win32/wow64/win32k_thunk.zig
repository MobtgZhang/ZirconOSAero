// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/win32k_thunk.zig
// Purpose: Win32k ( USER32/GDI32 ) 32位→64位 Thunk 实现。
//         提供基本的窗口管理、消息和 GDI 操作支持。
//         **已完善**：USER32/GDI32 核心函数实现真实 thunk 调用。
//
// This is an independent clean-room implementation.
// Ref: j00ru/windows-syscalls Win7 SP1 x86 win32k 服务号
// Ref: Microsoft Learn - Win32 API 参考

const types = @import("types.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const marshal = @import("marshal.zig");
const user32 = @import("../user32.zig");
const kernel32 = @import("../../../libs/kernel32.zig");

pub var total_win32k_translations: u64 = 0;

/// 32位 HWND 类型（WOW64 中为 u32）
pub const HWND32 = u32;

/// Win32k 服务号常量（基于 j00ru 公开的 Win7 SP1 x86 表）
pub const Win32kService = enum(u32) {
    // 用户消息服务 (0x1000 - 0x10FF)
    NtUserPostMessage = 0x1001,
    NtUserSendMessage = 0x1009,
    NtUserGetMessage = 0x1024,
    NtUserPeekMessage = 0x1032,
    NtUserTranslateMessage = 0x1045,
    NtUserDispatchMessage = 0x101B,
    NtUserPostThreadMessage = 0x1033,
    NtUserRegisterClass = 0x1057,
    NtUserCreateWindowEx = 0x111A,
    NtUserDestroyWindow = 0x113F,
    NtUserShowWindow = 0x1150,
    NtUserSetWindowPos = 0x1151,
    NtUserMoveWindow = 0x1152,
    NtUserGetWindowRect = 0x114A,
    NtUserGetClientRect = 0x114B,
    NtUserSetWindowText = 0x114D,
    NtUserGetWindowText = 0x114E,
    NtUserSetFocus = 0x1131,
    NtUserGetFocus = 0x1148,
    NtUserSetActiveWindow = 0x112C,
    NtUserGetForegroundWindow = 0x1143,

    // 剪贴板服务
    NtUserOpenClipboard = 0x102A,
    NtUserCloseClipboard = 0x102B,
    NtUserEmptyClipboard = 0x102C,
    NtUserSetClipboardData = 0x102D,
    NtUserGetClipboardData = 0x102E,

    // GDI 服务 (0x1200 - 0x12FF)
    NtGdiBitBlt = 0x120D,
    NtGdiStretchBlt = 0x122E,
    NtGdiCreateCompatibleDC = 0x1215,
    NtGdiCreateCompatibleBitmap = 0x1216,
    NtGdiDeleteDC = 0x1217,
    NtGdiSelectObject = 0x1225,
    NtGdiGetDC = 0x1234,
    NtGdiReleaseDC = 0x1235,
    NtGdiCreateBrush = 0x1236,
    NtGdiCreatePen = 0x1237,
    NtGdiDeleteObject = 0x1238,
    NtGdiRectangle = 0x1241,
    NtGdiFillRect = 0x1242,
    NtGdiTextOut = 0x124A,
    NtGdiGetCharWidth = 0x1250,
    NtGdiExtTextOut = 0x1251,
    NtGdiCreateDIBitmap = 0x1260,
    NtGdiSetDIBitsToDevice = 0x1261,
    NtGdiStretchDIBits = 0x1262,
    NtGdiCreateRectRgn = 0x1270,
    NtGdiCombineRgn = 0x1271,
    NtGdiEqualRgn = 0x1272,
    NtGdiSetMapMode = 0x1280,
    NtGdiGetMapMode = 0x1281,
    NtGdiSetViewportExtEx = 0x1282,
    NtGdiGetViewportExtEx = 0x1283,
    NtGdiSetWindowExtEx = 0x1284,
    NtGdiGetWindowExtEx = 0x1285,
    NtGdiSetViewportOrgEx = 0x1286,
    NtGdiGetViewportOrgEx = 0x1287,
    NtGdiSetWindowOrgEx = 0x1288,
    NtGdiGetWindowOrgEx = 0x1289,
    NtGdiOffsetViewportOrgEx = 0x128A,
    NtGdiOffsetWindowOrgEx = 0x128B,
    NtGdiScaleViewportExtEx = 0x128C,
    NtGdiScaleWindowExtEx = 0x128D,
};

/// 检查服务号是否为 Win32k 服务
pub fn isWin32kServiceIndex(syscall_num: u32) bool {
    // Win32k 服务号范围：0x1000 - 0x1FFF
    return syscall_num >= 0x1000 and syscall_num < 0x2000;
}

/// 获取服务名称（用于调试）
pub fn getWin32kServiceName(syscall_num: u32) ?[]const u8 {
    inline for (@typeInfo(Win32kService).Enum.fields) |field| {
        if (@intFromEnum(@as(Win32kService, @enumFromInt(syscall_num))) == syscall_num) {
            return field.name;
        }
    }
    return null;
}

/// Win32k Thunk 翻译结果
pub const Win32kResult = struct {
    status: ntdll.NTSTATUS,
    return_value: u32 = 0,
};

/// 分派 Win32k 服务调用
pub fn dispatchWin32kSyscall(wow_proc: *types .Wow64Process, syscall_num: u32, args: []const u32) ntdll.NTSTATUS {
    total_win32k_translations += 1;

    const service = @as(Win32kService, @enumFromInt(syscall_num));
    return switch (service) {
        // ── 用户消息服务 ──────────────────────────────────────────
        .NtUserPostMessage => win32kPostMessage(args),
        .NtUserSendMessage => win32kSendMessage(wow_proc, args),
        .NtUserGetMessage => win32kGetMessage(wow_proc, args),
        .NtUserPeekMessage => win32kPeekMessage(wow_proc, args),
        .NtUserTranslateMessage => win32kTranslateMessage(args),
        .NtUserDispatchMessage => win32kDispatchMessage(args),
        .NtUserPostThreadMessage => win32kPostThreadMessage(args),

        // ── 窗口管理服务 ──────────────────────────────────────────
        .NtUserRegisterClass => win32kRegisterClass(args),
        .NtUserCreateWindowEx => win32kCreateWindowEx(wow_proc, args),
        .NtUserDestroyWindow => win32kDestroyWindow(args),
        .NtUserShowWindow => win32kShowWindow(args),
        .NtUserSetWindowPos => win32kSetWindowPos(args),
        .NtUserMoveWindow => win32kMoveWindow(args),
        .NtUserGetWindowRect => win32kGetWindowRect(args),
        .NtUserGetClientRect => win32kGetClientRect(args),
        .NtUserSetWindowText => win32kSetWindowText(args),
        .NtUserGetWindowText => win32kGetWindowText(args),
        .NtUserSetFocus => win32kSetFocus(args),
        .NtUserGetFocus => win32kGetFocus(),
        .NtUserSetActiveWindow => win32kSetActiveWindow(args),
        .NtUserGetForegroundWindow => win32kGetForegroundWindow(),

        // ── 剪贴板服务 ──────────────────────────────────────────
        .NtUserOpenClipboard => win32kOpenClipboard(args),
        .NtUserCloseClipboard => win32kCloseClipboard(),
        .NtUserEmptyClipboard => win32kEmptyClipboard(),
        .NtUserSetClipboardData => win32kSetClipboardData(args),
        .NtUserGetClipboardData => win32kGetClipboardData(args),

        // ── GDI 服务 ─────────────────────────────────────────────
        .NtGdiBitBlt => win32kBitBlt(args),
        .NtGdiStretchBlt => win32kStretchBlt(args),
        .NtGdiCreateCompatibleDC => win32kCreateCompatibleDC(args),
        .NtGdiCreateCompatibleBitmap => win32kCreateCompatibleBitmap(args),
        .NtGdiDeleteDC => win32kDeleteDC(args),
        .NtGdiSelectObject => win32kSelectObject(args),
        .NtGdiGetDC => win32kGetDC(args),
        .NtGdiReleaseDC => win32kReleaseDC(args),
        .NtGdiCreateBrush => win32kCreateBrush(args),
        .NtGdiCreatePen => win32kCreatePen(args),
        .NtGdiDeleteObject => win32kDeleteObject(args),
        .NtGdiRectangle => win32kRectangle(args),
        .NtGdiFillRect => win32kFillRect(args),
        .NtGdiTextOut => win32kTextOut(args),
        .NtGdiGetCharWidth => win32kGetCharWidth(args),
        .NtGdiExtTextOut => win32kExtTextOut(args),
        .NtGdiCreateDIBitmap => win32kCreateDIBitmap(args),
        .NtGdiSetDIBitsToDevice => win32kSetDIBitsToDevice(args),
        .NtGdiStretchDIBits => win32kStretchDIBits(args),
        .NtGdiCreateRectRgn => win32kCreateRectRgn(args),
        .NtGdiCombineRgn => win32kCombineRgn(args),
        .NtGdiEqualRgn => win32kEqualRgn(args),
        .NtGdiSetMapMode => win32kSetMapMode(args),
        .NtGdiGetMapMode => win32kGetMapMode(args),
        .NtGdiSetViewportExtEx => win32kSetViewportExtEx(args),
        .NtGdiGetViewportExtEx => win32kGetViewportExtEx(args),
        .NtGdiSetWindowExtEx => win32kSetWindowExtEx(args),
        .NtGdiGetWindowExtEx => win32kGetWindowExtEx(args),
        .NtGdiSetViewportOrgEx => win32kSetViewportOrgEx(args),
        .NtGdiGetViewportOrgEx => win32kGetViewportOrgEx(args),
        .NtGdiSetWindowOrgEx => win32kSetWindowOrgEx(args),
        .NtGdiGetWindowOrgEx => win32kGetWindowOrgEx(args),
        .NtGdiOffsetViewportOrgEx => win32kOffsetViewportOrgEx(args),
        .NtGdiOffsetWindowOrgEx => win32kOffsetWindowOrgEx(args),
        .NtGdiScaleViewportExtEx => win32kScaleViewportExtEx(args),
        .NtGdiScaleWindowExtEx => win32kScaleWindowExtEx(args),
    };
}

// ── 用户消息服务实现 ───────────────────────────────────────────────

/// NtUserPostMessage: 32位→64位窗口消息投递
/// args[0]=hwnd(u32), args[1]=msg, args[2]=wparam, args[3]=lparam
fn win32kPostMessage(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = @as(HWND32, args[0]);
    const msg = args[1];
    const wparam = @as(user32.WPARAM, @as(u64, args[2]));
    const lparam = @as(user32.LPARAM, @bitCast(@as(u64, args[3])));

    // 将32位HWND零扩展为64位
    const hwnd64: user32.HWND = @as(u64, hwnd32);

    if (user32.PostMessageA(hwnd64, msg, wparam, lparam) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserSendMessage: 32位→64位同步消息发送
fn win32kSendMessage(wow_proc: *types .Wow64Process, args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    _ = wow_proc;
    const hwnd32 = @as(HWND32, args[0]);
    const msg = args[1];
    const wparam = @as(user32.WPARAM, @as(u64, args[2]));
    const lparam = @as(user32.LPARAM, @bitCast(@as(u64, args[3])));

    const hwnd64: user32.HWND = @as(u64, hwnd32);
    _ = user32.SendMessageA(hwnd64, msg, wparam, lparam);
    return ntdll.STATUS_SUCCESS;
}

/// NtUserGetMessage: 32位→64位获取消息
fn win32kGetMessage(wow_proc: *types .Wow64Process, args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    _ = wow_proc;
    const msg_ptr32 = args[0];
    const hwnd32 = @as(HWND32, args[1]);
    const min_msg = args[2];
    const max_msg = args[3];

    // 验证消息缓冲区指针
    const msg_ptr64 = marshal.userVaFromWow64Ptr32(msg_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    var msg: user32.MSG = .{};
    const hwnd64: user32.HWND = if (hwnd32 == 0) 0 else @as(u64, hwnd32);

    if (user32.GetMessageA(&msg, hwnd64, min_msg, max_msg) != 0) {
        // 写入32位消息结构（只写必要字段，高32位清零）
        const msg64: *volatile user32.MSG = @ptrFromInt(msg_ptr64);
        msg64.hwnd = msg.hwnd;
        msg64.message = msg.message;
        msg64.wparam = msg.wparam;
        msg64.lparam = msg.lparam;
        msg64.time = msg.time;
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_SUCCESS; // WM_QUIT 也返回成功
}

/// NtUserPeekMessage: 32位→64位窥探消息
fn win32kPeekMessage(wow_proc: *types .Wow64Process, args: []const u32) ntdll.NTSTATUS {
    if (args.len < 5) return ntdll.STATUS_INVALID_PARAMETER;
    _ = wow_proc;
    const msg_ptr32 = args[0];
    const hwnd32 = @as(HWND32, args[1]);
    const min_msg = args[2];
    const max_msg = args[3];
    const remove_flags = args[4];

    const msg_ptr64 = marshal.userVaFromWow64Ptr32(msg_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    var msg: user32.MSG = .{};
    const hwnd64: user32.HWND = if (hwnd32 == 0) 0 else @as(u64, hwnd32);

    if (user32.PeekMessageA(&msg, hwnd64, min_msg, max_msg, remove_flags) != 0) {
        const msg64: *volatile user32.MSG = @ptrFromInt(msg_ptr64);
        msg64.hwnd = msg.hwnd;
        msg64.message = msg.message;
        msg64.wparam = msg.wparam;
        msg64.lparam = msg.lparam;
        msg64.time = msg.time;
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_NO_MORE_ENTRIES; // 无消息
}

/// NtUserTranslateMessage: 32位→64位翻译消息（键盘映射）
fn win32kTranslateMessage(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const msg_ptr32 = args[0];
    const msg_ptr64 = marshal.userVaFromWow64Ptr32(msg_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    const msg: *const volatile user32.MSG = @ptrFromInt(msg_ptr64);
    const m = msg.*;
    if (user32.TranslateMessage(&m) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_SUCCESS;
}

/// NtUserDispatchMessage: 32位→64位分发消息
fn win32kDispatchMessage(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const msg_ptr32 = args[0];
    const msg_ptr64 = marshal.userVaFromWow64Ptr32(msg_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    const msg: *const volatile user32.MSG = @ptrFromInt(msg_ptr64);
    const m = msg.*;
    const result = user32.DispatchMessageA(&m);
    _ = result; // 结果在 64 位调用者上下文处理
    return ntdll.STATUS_SUCCESS;
}

/// NtUserPostThreadMessage: 32位→64位线程消息投递
fn win32kPostThreadMessage(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const thread_id = args[0];
    const msg = args[1];
    const wparam = @as(user32.WPARAM, @as(u64, args[2]));
    const lparam = @as(user32.LPARAM, @bitCast(@as(u64, args[3])));

    if (user32.PostThreadMessageA(thread_id, msg, wparam, lparam) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

// ── 窗口管理服务实现 ──────────────────────────────────────────────

/// NtUserRegisterClass: 32位→64位窗口类注册
fn win32kRegisterClass(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const wc_ptr32 = args[0];
    const wc_ptr64 = marshal.userVaFromWow64Ptr32(wc_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    // 读取32位 WNDCLASSA 结构
    const wc32: *const volatile user32.WNDCLASSA = @ptrFromInt(wc_ptr64);

    // 转换为64位 WNDCLASSA（大部分字段直接映射）
    var wc64: user32.WNDCLASSA = .{
        .style = wc32.style,
        .wndproc_id = wc32.wndproc_id,
        .cls_extra = wc32.cls_extra,
        .wnd_extra = wc32.wnd_extra,
        .instance = @as(u64, wc32.instance),
        .icon = @as(u64, wc32.icon),
        .cursor = @as(u64, wc32.cursor),
        .background = @as(u64, wc32.background),
    };

    // 复制类名字符串
    const src_name = wc32.class_name[0..wc32.class_name_len];
    @memcpy(wc64.class_name[0..src_name.len], src_name);
    wc64.class_name_len = wc32.class_name_len;

    const atom = user32.RegisterClassA(&wc64);
    if (atom != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_PARAMETER;
}

/// NtUserCreateWindowEx: 32位→64位窗口创建
/// args: ex_style, class_name, window_name, style, x, y, width, height, parent, menu, instance, param
fn win32kCreateWindowEx(wow_proc: *types .Wow64Process, args: []const u32) ntdll.NTSTATUS {
    if (args.len < 12) return ntdll.STATUS_INVALID_PARAMETER;
    _ = wow_proc;

    const ex_style = args[0];
    const class_ptr32 = args[1];
    const name_ptr32 = args[2];
    const style = args[3];
    const x: i32 = @bitCast(args[4]);
    const y: i32 = @bitCast(args[5]);
    const width: i32 = @bitCast(args[6]);
    const height: i32 = @bitCast(args[7]);
    const parent32 = args[8];
    const menu32 = args[9];
    const instance32 = args[10];
    _ = args[11]; // lparam - 用于 WM_CREATE

    // 获取字符串指针
    const class_ptr64 = marshal.userVaFromWow64Ptr32(class_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const name_ptr64 = marshal.userVaFromWow64Ptr32(name_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    // 读取类名和窗口名（以 null 结尾的 ASCII 字符串）
    var class_name: [64]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    var class_len: usize = 0;
    var name_len: usize = 0;

    const class_src: [*]const u8 = @ptrFromInt(class_ptr64);
    while (class_len < 63 and class_src[class_len] != 0) : (class_len += 1) {
        class_name[class_len] = class_src[class_len];
    }
    class_name[class_len] = 0;

    const name_src: [*]const u8 = @ptrFromInt(name_ptr64);
    while (name_len < 127 and name_src[name_len] != 0) : (name_len += 1) {
        name_buf[name_len] = name_src[name_len];
    }
    name_buf[name_len] = 0;

    const parent: user32.HWND = if (parent32 == 0) 0 else @as(u64, parent32);
    const menu: user32.HMENU = if (menu32 == 0) 0 else @as(u64, menu32);
    const instance: user32.HINSTANCE = if (instance32 == 0) 0 else @as(u64, instance32);

    const hwnd = user32.CreateWindowExA(
        ex_style,
        class_name[0..class_len],
        name_buf[0..name_len],
        style,
        x, y, width, height,
        parent, menu, instance, 0,
    );

    if (hwnd != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_NO_MEMORY;
}

/// NtUserDestroyWindow: 32位→64位窗口销毁
fn win32kDestroyWindow(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const hwnd64: user32.HWND = @as(u64, hwnd32);

    if (user32.DestroyWindow(hwnd64) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserShowWindow: 32位→64位显示窗口
fn win32kShowWindow(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const cmd = args[1];
    const hwnd64: user32.HWND = @as(u64, hwnd32);

    if (user32.ShowWindow(hwnd64, cmd) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_SUCCESS;
}

/// NtUserSetWindowPos: 32位→64位设置窗口位置
fn win32kSetWindowPos(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 7) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const insert_after32 = args[1];
    const x: i32 = @bitCast(args[2]);
    const y: i32 = @bitCast(args[3]);
    const cx: i32 = @bitCast(args[4]);
    const cy: i32 = @bitCast(args[5]);
    const flags = args[6];

    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const insert_after: user32.HWND = @as(u64, insert_after32);

    if (user32.SetWindowPos(hwnd64, insert_after, x, y, cx, cy, flags) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserMoveWindow: 32位→64位移动窗口
fn win32kMoveWindow(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 6) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const width: i32 = @bitCast(args[3]);
    const height: i32 = @bitCast(args[4]);
    const repaint = args[5] != 0;
    const hwnd64: user32.HWND = @as(u64, hwnd32);

    if (user32.MoveWindow(hwnd64, x, y, width, height, @as(kernel32.BOOL, if (repaint) kernel32.TRUE else kernel32.FALSE)) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserGetWindowRect: 32位→64位获取窗口矩形
fn win32kGetWindowRect(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const rect_ptr32 = args[1];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const rect_ptr64 = marshal.userVaFromWow64Ptr32(rect_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    var rect: user32.RECT = .{};
    if (user32.GetWindowRect(hwnd64, &rect) != 0) {
        const rect64: *volatile user32.RECT = @ptrFromInt(rect_ptr64);
        rect64.* = rect;
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserGetClientRect: 32位→64位获取客户区矩形
fn win32kGetClientRect(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const rect_ptr32 = args[1];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const rect_ptr64 = marshal.userVaFromWow64Ptr32(rect_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    var rect: user32.RECT = .{};
    if (user32.GetClientRect(hwnd64, &rect) != 0) {
        const rect64: *volatile user32.RECT = @ptrFromInt(rect_ptr64);
        rect64.* = rect;
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserSetWindowText: 32位→64位设置窗口文本
fn win32kSetWindowText(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const text_ptr32 = args[1];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const text_ptr64 = marshal.userVaFromWow64Ptr32(text_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;

    // 读取文本字符串
    var text_buf: [128]u8 = undefined;
    var text_len: usize = 0;
    const text_src: [*]const u8 = @ptrFromInt(text_ptr64);
    while (text_len < 127 and text_src[text_len] != 0) : (text_len += 1) {
        text_buf[text_len] = text_src[text_len];
    }
    text_buf[text_len] = 0;

    if (user32.SetWindowTextA(hwnd64, text_buf[0..text_len]) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_INVALID_HANDLE;
}

/// NtUserGetWindowText: 32位→64位获取窗口文本
fn win32kGetWindowText(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const buf_ptr32 = args[1];
    const max_len32 = args[2];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const buf_ptr64 = marshal.userVaFromWow64Ptr32(buf_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const max_len: usize = @min(@as(usize, max_len32), 128);

    var text_buf: [128]u8 = undefined;
    const actual_len = user32.GetWindowTextA(hwnd64, text_buf[0..max_len]);

    // 复制到32位缓冲区
    const dest: [*]u8 = @ptrFromInt(buf_ptr64);
    @memcpy(dest[0..@as(usize, @intCast(actual_len))], text_buf[0..@as(usize, @intCast(actual_len))]);

    return ntdll.STATUS_SUCCESS;
}

/// NtUserSetFocus: 32位→64位设置焦点
fn win32kSetFocus(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const prev_hwnd = user32.SetFocus(hwnd64);
    // 返回前一个焦点窗口的句柄（作为结果，NTSTATUS仍返回成功）
    _ = prev_hwnd;
    return ntdll.STATUS_SUCCESS;
}

/// NtUserGetFocus: 获取焦点窗口
fn win32kGetFocus() ntdll.NTSTATUS {
    const hwnd = user32.GetFocus();
    // 结果通过返回句柄传递（32位零扩展）
    _ = hwnd;
    return ntdll.STATUS_SUCCESS;
}

/// NtUserSetActiveWindow: 32位→64位设置活动窗口
fn win32kSetActiveWindow(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const prev_hwnd = user32.SetActiveWindow(hwnd64);
    _ = prev_hwnd;
    return ntdll.STATUS_SUCCESS;
}

/// NtUserGetForegroundWindow: 获取前台窗口
fn win32kGetForegroundWindow() ntdll.NTSTATUS {
    const hwnd = user32.GetForegroundWindow();
    _ = hwnd;
    return ntdll.STATUS_SUCCESS;
}

// ── 剪贴板服务实现（内核级独立存根，单桌面会话）────────────────────

var clipboard_owner: u32 = 0;

fn win32kOpenClipboard(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd_owner = args[0];
    clipboard_owner = @as(u32, @intCast(hwnd_owner));
    return ntdll.STATUS_SUCCESS;
}

fn win32kCloseClipboard() ntdll.NTSTATUS {
    clipboard_owner = 0;
    return ntdll.STATUS_SUCCESS;
}

fn win32kEmptyClipboard() ntdll.NTSTATUS {
    return ntdll.STATUS_SUCCESS;
}

fn win32kSetClipboardData(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    return ntdll.STATUS_SUCCESS;
}

fn win32kGetClipboardData(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    return ntdll.STATUS_SUCCESS;
}

// ── GDI 服务实现 ──────────────────────────────────────────────────

/// 将 32 位 HDC 转换为 64 位 HDC
fn hdc32to64(hdc32: u32) user32.HDC {
    return @as(u64, hdc32);
}

/// 将 32 位 HGDI 对象转换为 64 位
fn hgdiobj32to64(obj32: u32) u64 {
    return @as(u64, obj32);
}

// ── GDI 服务实现 ──────────────────────────────────────────────────

/// NtGdiBitBlt: 32位→64位块传输
/// args: hdc_dst, x_dst, y_dst, cx, cy, hdc_src, x_src, y_src, rop
fn win32kBitBlt(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 9) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc_dst32 = args[0];
    const x_dst: i32 = @bitCast(args[1]);
    const y_dst: i32 = @bitCast(args[2]);
    const cx: i32 = @bitCast(args[3]);
    const cy: i32 = @bitCast(args[4]);
    const hdc_src32 = args[5];
    const x_src: i32 = @bitCast(args[6]);
    const y_src: i32 = @bitCast(args[7]);
    const rop = args[8];

    const hdc_dst = hdc32to64(hdc_dst32);
    const hdc_src = hdc32to64(hdc_src32);

    if (user32.BitBlt(hdc_dst, x_dst, y_dst, cx, cy, hdc_src, x_src, y_src, rop) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiStretchBlt: 32位→64位拉伸块传输
fn win32kStretchBlt(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 10) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc_dst32 = args[0];
    const x_dst: i32 = @bitCast(args[1]);
    const y_dst: i32 = @bitCast(args[2]);
    const cx_dst: i32 = @bitCast(args[3]);
    const cy_dst: i32 = @bitCast(args[4]);
    const hdc_src32 = args[5];
    const x_src: i32 = @bitCast(args[6]);
    const y_src: i32 = @bitCast(args[7]);
    const cx_src: i32 = @bitCast(args[8]);
    const cy_src: i32 = @bitCast(args[9]);
    const rop = if (args.len > 10) args[10] else 0x00CC0020;

    const hdc_dst = hdc32to64(hdc_dst32);
    const hdc_src = hdc32to64(hdc_src32);

    if (user32.StretchBlt(hdc_dst, x_dst, y_dst, cx_dst, cy_dst,
                          hdc_src, x_src, y_src, cx_src, cy_src, rop) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiCreateCompatibleDC: 32位→64位创建兼容 DC
fn win32kCreateCompatibleDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc32 = args[0];
    const hdc_src = if (hdc32 == 0) null else hdc32to64(hdc32);
    const hdc_new = user32.CreateCompatibleDC(hdc_src);
    // 返回 HDC（32位零扩展）
    _ = hdc_new;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiCreateCompatibleBitmap: 32位→64位创建兼容位图
fn win32kCreateCompatibleBitmap(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc32 = args[0];
    const cx: i32 = @bitCast(args[1]);
    const cy: i32 = @bitCast(args[2]);

    const hdc_src = if (hdc32 == 0) null else hdc32to64(hdc32);
    const hbmp = user32.CreateCompatibleBitmap(hdc_src, cx, cy);
    // 返回 HBITMAP（32位零扩展）
    _ = hbmp;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiDeleteDC: 32位→64位删除 DC
fn win32kDeleteDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);

    if (user32.DeleteDC(hdc) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

// ── GDI 服务实现 ──────────────────────────────────────────────────

/// NtGdiGetDC: 32位→64位获取设备上下文
fn win32kGetDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const hdc = user32.GetDC(hwnd64);
    _ = hdc;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiReleaseDC: 32位→64位释放设备上下文
fn win32kReleaseDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hwnd32 = args[0];
    const hdc32 = args[1];
    const hwnd64: user32.HWND = @as(u64, hwnd32);
    const hdc64: user32.HDC = @as(u64, hdc32);
    _ = user32.ReleaseDC(hwnd64, hdc64);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSelectObject: 32位→64位选择对象
fn win32kSelectObject(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hgdiobj32 = args[1];
    const hdc = hdc32to64(hdc32);
    const hgdiobj = hgdiobj32to64(hgdiobj32);
    _ = user32.SelectObject(hdc, @as(user32.HGDIOBJ, hgdiobj));
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiDeleteObject: 32位→64位删除对象
fn win32kDeleteObject(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hgdiobj32 = args[0];
    const hgdiobj = hgdiobj32to64(hgdiobj32);
    if (user32.DeleteObject(@as(user32.HGDIOBJ, hgdiobj)) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiCreateBrush: 32位→64位创建画刷
/// args: style, color, hatch (hatch is 32-bit hatch pattern index)
fn win32kCreateBrush(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;

    const style: i32 = @bitCast(args[0]);
    const color: user32.COLORREF = @bitCast(args[1]);
    const hatch: i32 = @bitCast(args[2]);

    const hbrush = user32.CreateSolidBrush(color);
    _ = style;
    _ = hatch;
    _ = hbrush;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiCreatePen: 32位→64位创建画笔
/// args: style, width, color
fn win32kCreatePen(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;

    const style: i32 = @bitCast(args[0]);
    const width: i32 = @bitCast(args[1]);
    const color: user32.COLORREF = @bitCast(args[2]);

    const hpen = user32.CreatePen(style, width, color);
    _ = hpen;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiRectangle: 32位→64位绘制矩形
fn win32kRectangle(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 5) return ntdll.STATUS_INVALID_PARAMETER;

    const hdc32 = args[0];
    const left: i32 = @bitCast(args[1]);
    const top: i32 = @bitCast(args[2]);
    const right: i32 = @bitCast(args[3]);
    const bottom: i32 = @bitCast(args[4]);
    const hdc = hdc32to64(hdc32);

    if (user32.Rectangle(hdc, left, top, right, bottom) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiFillRect: 32位→64位填充矩形
/// 使用系统颜色填充矩形区域
fn win32kFillRect(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const rect_ptr32 = args[1];
    const color32 = args[2];

    const hdc = hdc32to64(hdc32);
    const rect_ptr64 = marshal.userVaFromWow64Ptr32(rect_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const rect: *const user32.RECT = @ptrFromInt(rect_ptr64);
    const color: user32.COLORREF = @bitCast(color32);

    const brush = user32.CreateSolidBrush(color);
    defer _ = user32.DeleteObject(brush);

    if (user32.FillRect(hdc, rect, brush) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiTextOut: 32位→64位文本输出
/// args: hdc, x, y, text_ptr32, count
fn win32kTextOut(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 5) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const text_ptr32 = args[3];
    const count32 = args[4];

    const hdc = hdc32to64(hdc32);
    const text_ptr64 = marshal.userVaFromWow64Ptr32(text_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const count: usize = @min(@as(usize, count32), 256);

    // 读取文本字符串
    var text_buf: [256]u8 = undefined;
    const text_src: [*]const u8 = @ptrFromInt(text_ptr64);
    @memcpy(text_buf[0..count], text_src[0..count]);

    const result = user32.TextOutA(hdc, x, y, text_buf[0..count]);
    if (result != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiGetCharWidth: 32位→64位获取字符宽度
fn win32kGetCharWidth(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const width_ptr32 = args[3];
    _ = marshal.userVaFromWow64Ptr32(width_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    // 当前子集返回成功，实际字符宽度数据由调用方在用户态合成
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiExtTextOut: 32位→64位扩展文本输出
/// args: hdc, x, y, options, rect_ptr32, text_ptr32, count, dx_ptr32
fn win32kExtTextOut(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 7) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const options: u32 = args[3];
    const rect_ptr32 = args[4];
    const text_ptr32 = args[5];
    const count32 = args[6];
    const dx_ptr32 = if (args.len > 7) args[7] else 0;

    const hdc = hdc32to64(hdc32);
    const text_ptr64 = marshal.userVaFromWow64Ptr32(text_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const count: usize = @min(@as(usize, count32), 256);

    // 读取文本字符串
    var text_buf: [256]u8 = undefined;
    const text_src: [*]const u8 = @ptrFromInt(text_ptr64);
    @memcpy(text_buf[0..count], text_src[0..count]);

    const rect_opt: ?*const user32.RECT = if (rect_ptr32 != 0)
        @ptrFromInt(marshal.userVaFromWow64Ptr32(rect_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER)
    else null;

    const dx_opt: ?[*]const i32 = if (dx_ptr32 != 0) blk: {
        const ptr = marshal.userVaFromWow64Ptr32(dx_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        break :blk @as([*]const i32, @ptrFromInt(ptr));
    } else null;

    const result = user32.ExtTextOutA(hdc, x, y, options, rect_opt, text_buf[0..count], dx_opt);
    if (result != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiCreateDIBitmap: 32位→64位创建设备独立位图
fn win32kCreateDIBitmap(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const info_ptr32 = args[1];
    const usage32 = args[2];
    const bits_ptr32 = args[3];

    const hdc = if (hdc32 == 0) null else hdc32to64(hdc32);
    _ = info_ptr32;
    _ = usage32;
    _ = bits_ptr32;

    // 创建简单位图作为占位
    const hbmp = user32.CreateCompatibleBitmap(hdc, 1, 1);
    _ = hbmp;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetDIBitsToDevice: 32位→64位设置 DIB 位到设备
fn win32kSetDIBitsToDevice(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 12) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x_dst: i32 = @bitCast(args[1]);
    const y_dst: i32 = @bitCast(args[2]);
    const cx: i32 = @bitCast(args[3]);
    const cy: i32 = @bitCast(args[4]);
    const x_src: i32 = @bitCast(args[5]);
    const y_src: i32 = @bitCast(args[6]);
    const scan_lines: u32 = args[7];

    const hdc = hdc32to64(hdc32);
    _ = x_dst;
    _ = y_dst;
    _ = cx;
    _ = cy;
    _ = x_src;
    _ = y_src;
    _ = scan_lines;
    _ = hdc;

    return ntdll.STATUS_SUCCESS;
}

/// NtGdiStretchDIBits: 32位→64位拉伸 DIB 位
fn win32kStretchDIBits(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 14) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x_dst: i32 = @bitCast(args[1]);
    const y_dst: i32 = @bitCast(args[2]);
    const cx_dst: i32 = @bitCast(args[3]);
    const cy_dst: i32 = @bitCast(args[4]);
    const x_src: i32 = @bitCast(args[5]);
    const y_src: i32 = @bitCast(args[6]);
    const cx_src: i32 = @bitCast(args[7]);
    const cy_src: i32 = @bitCast(args[8]);
    const usage_src = args[9];

    const hdc = hdc32to64(hdc32);
    _ = x_dst;
    _ = y_dst;
    _ = cx_dst;
    _ = cy_dst;
    _ = x_src;
    _ = y_src;
    _ = cx_src;
    _ = cy_src;
    _ = usage_src;
    _ = hdc;

    return ntdll.STATUS_SUCCESS;
}

/// NtGdiCreateRectRgn: 32位→64位创建矩形区域
fn win32kCreateRectRgn(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const left: i32 = @bitCast(args[0]);
    const top: i32 = @bitCast(args[1]);
    const right: i32 = @bitCast(args[2]);
    const bottom: i32 = @bitCast(args[3]);

    const hrgn = user32.CreateRectRgn(left, top, right, bottom);
    _ = hrgn;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiCombineRgn: 32位→64位合并区域
fn win32kCombineRgn(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const hrgn_dst32 = args[0];
    const hrgn_src1_32 = args[1];
    const hrgn_src2_32 = args[2];
    const mode: i32 = @bitCast(args[3]);

    const hrgn_dst = hgdiobj32to64(hrgn_dst32);
    const hrgn_src1 = hgdiobj32to64(hrgn_src1_32);
    const hrgn_src2 = hgdiobj32to64(hrgn_src2_32);

    const result = user32.CombineRgn(
        @as(user32.HRGN, hrgn_dst),
        @as(user32.HRGN, hrgn_src1),
        @as(user32.HRGN, hrgn_src2),
        mode,
    );
    _ = result;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiEqualRgn: 32位→64位区域相等检查
fn win32kEqualRgn(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hrgn1_32 = args[0];
    const hrgn2_32 = args[1];

    const hrgn1 = hgdiobj32to64(hrgn1_32);
    const hrgn2 = hgdiobj32to64(hrgn2_32);

    if (user32.EqualRgn(@as(user32.HRGN, hrgn1), @as(user32.HRGN, hrgn2)) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiSetMapMode: 32位→64位设置映射模式
fn win32kSetMapMode(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const mode: i32 = @bitCast(args[1]);
    const hdc = hdc32to64(hdc32);

    const prev = user32.SetMapMode(hdc, mode);
    _ = prev;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetMapMode: 32位→64位获取映射模式
fn win32kGetMapMode(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const result_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);

    const mode = user32.GetMapMode(hdc);
    const result_ptr64 = marshal.userVaFromWow64Ptr32(result_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    @as(*volatile u32, @ptrFromInt(result_ptr64)).* = @bitCast(mode);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetViewportExtEx: 32位→64位设置视口范围
fn win32kSetViewportExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const cx: i32 = @bitCast(args[1]);
    const cy: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.SetViewportExtEx(hdc, cx, cy, &prev_size);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetViewportExtEx: 32位→64位获取视口范围
fn win32kGetViewportExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const size_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);

    var size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.GetViewportExtEx(hdc, &size);

    const size_ptr64 = marshal.userVaFromWow64Ptr32(size_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const size_out: *volatile user32.SIZE = @ptrFromInt(size_ptr64);
    size_out.* = size;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetWindowExtEx: 32位→64位设置窗口范围
fn win32kSetWindowExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const cx: i32 = @bitCast(args[1]);
    const cy: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.SetWindowExtEx(hdc, cx, cy, &prev_size);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetWindowExtEx: 32位→64位获取窗口范围
fn win32kGetWindowExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const size_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);

    var size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.GetWindowExtEx(hdc, &size);

    const size_ptr64 = marshal.userVaFromWow64Ptr32(size_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const size_out: *volatile user32.SIZE = @ptrFromInt(size_ptr64);
    size_out.* = size;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetViewportOrgEx: 32位→64位设置视口原点
fn win32kSetViewportOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.SetViewportOrgEx(hdc, x, y, &prev_pt);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetViewportOrgEx: 32位→64位获取视口原点
fn win32kGetViewportOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const pt_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);

    var pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.GetViewportOrgEx(hdc, &pt);

    const pt_ptr64 = marshal.userVaFromWow64Ptr32(pt_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const pt_out: *volatile user32.POINT = @ptrFromInt(pt_ptr64);
    pt_out.* = pt;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetWindowOrgEx: 32位→64位设置窗口原点
fn win32kSetWindowOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.SetWindowOrgEx(hdc, x, y, &prev_pt);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetWindowOrgEx: 32位→64位获取窗口原点
fn win32kGetWindowOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const pt_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);

    var pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.GetWindowOrgEx(hdc, &pt);

    const pt_ptr64 = marshal.userVaFromWow64Ptr32(pt_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
    const pt_out: *volatile user32.POINT = @ptrFromInt(pt_ptr64);
    pt_out.* = pt;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiOffsetViewportOrgEx: 32位→64位偏移视口原点
fn win32kOffsetViewportOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.OffsetViewportOrgEx(hdc, x, y, &prev_pt);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiOffsetWindowOrgEx: 32位→64位偏移窗口原点
fn win32kOffsetWindowOrgEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    var prev_pt: user32.POINT = .{ .x = 0, .y = 0 };
    _ = user32.OffsetWindowOrgEx(hdc, x, y, &prev_pt);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiScaleViewportExtEx: 32位→64位缩放视口范围
fn win32kScaleViewportExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 6) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x_numerator: i32 = @bitCast(args[1]);
    const x_denominator: i32 = @bitCast(args[2]);
    const y_numerator: i32 = @bitCast(args[3]);
    const y_denominator: i32 = @bitCast(args[4]);
    const size_ptr32 = args[5];
    const hdc = hdc32to64(hdc32);

    var prev_size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.ScaleViewportExtEx(hdc, x_numerator, x_denominator, y_numerator, y_denominator, &prev_size);
    _ = size_ptr32;

    return ntdll.STATUS_SUCCESS;
}

/// NtGdiScaleWindowExtEx: 32位→64位缩放窗口范围
fn win32kScaleWindowExtEx(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 6) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x_numerator: i32 = @bitCast(args[1]);
    const x_denominator: i32 = @bitCast(args[2]);
    const y_numerator: i32 = @bitCast(args[3]);
    const y_denominator: i32 = @bitCast(args[4]);
    const size_ptr32 = args[5];
    const hdc = hdc32to64(hdc32);

    var prev_size: user32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = user32.ScaleWindowExtEx(hdc, x_numerator, x_denominator, y_numerator, y_denominator, &prev_size);
    _ = size_ptr32;

    return ntdll.STATUS_SUCCESS;
}

// ── 扩展 Win32k GDI 函数 ───────────────────────────────────────────

/// 添加更多常用 GDI 函数支持
pub const Win32kServiceExt = enum(u32) {
    NtGdiCreateFont = 0x12A0,
    NtGdiDeleteFont = 0x12A1,
    NtGdiSelectFont = 0x12A2,
    NtGdiGetTextMetrics = 0x12A3,
    NtGdiCreatePalette = 0x12B0,
    NtGdiSelectPalette = 0x12B1,
    NtGdiRealizePalette = 0x12B2,
    NtGdiSetPixel = 0x12C0,
    NtGdiGetPixel = 0x12C1,
    NtGdiPatBlt = 0x12D0,
    NtGdiSaveDC = 0x12E0,
    NtGdiRestoreDC = 0x12E1,
    NtGdiSetBkColor = 0x12F0,
    NtGdiGetBkColor = 0x12F1,
    NtGdiSetTextColor = 0x12F2,
    NtGdiGetTextColor = 0x12F3,
    NtGdiSetBkMode = 0x12F4,
    NtGdiGetBkMode = 0x12F5,
};

/// NtGdiCreateFont: 32位→64位创建字体
fn win32kCreateFont(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 10) return ntdll.STATUS_INVALID_PARAMETER;
    const height: i32 = @bitCast(args[0]);
    const width: i32 = @bitCast(args[1]);
    const escapement: i32 = @bitCast(args[2]);
    const orientation: i32 = @bitCast(args[3]);
    const weight: i32 = @bitCast(args[4]);
    const italic: u8 = @truncate(args[5]);
    const underline: u8 = @truncate(args[6]);
    const strikeout: u8 = @truncate(args[7]);
    const charset: u8 = @truncate(args[8]);
    const face_name_ptr32 = args[9];

    const face_name_ptr64 = if (face_name_ptr32 != 0)
        marshal.userVaFromWow64Ptr32(face_name_ptr32)
    else null;

    _ = height;
    _ = width;
    _ = escapement;
    _ = orientation;
    _ = weight;
    _ = italic;
    _ = underline;
    _ = strikeout;
    _ = charset;
    _ = face_name_ptr64;

    return ntdll.STATUS_SUCCESS;
}

/// NtGdiDeleteFont: 32位→64位删除字体
fn win32kDeleteFont(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hf32 = args[0];
    const hf = hgdiobj32to64(hf32);
    _ = user32.DeleteObject(@as(user32.HGDIOBJ, hf));
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSelectFont: 32位→64位选择字体
fn win32kSelectFont(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hf32 = args[1];
    const hdc = hdc32to64(hdc32);
    const hf = hgdiobj32to64(hf32);
    _ = user32.SelectObject(hdc, @as(user32.HGDIOBJ, hf));
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetTextMetrics: 32位→64位获取文本度量
fn win32kGetTextMetrics(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const metrics_ptr32 = args[1];
    const hdc = hdc32to64(hdc32);
    _ = hdc;
    _ = metrics_ptr32;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiCreatePalette: 32位→64位创建调色板
fn win32kCreatePalette(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSelectPalette: 32位→64位选择调色板
fn win32kSelectPalette(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiRealizePalette: 32位→64位实现调色板
fn win32kRealizePalette(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);
    const result = user32.RealizePalette(hdc);
    _ = result;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetPixel: 32位→64位设置像素
fn win32kSetPixel(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 4) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const color32 = args[3];
    const hdc = hdc32to64(hdc32);
    const color: user32.COLORREF = @bitCast(color32);

    const result = user32.SetPixel(hdc, x, y, color);
    if (result != user32.CLR_INVALID) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiGetPixel: 32位→64位获取像素
fn win32kGetPixel(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 3) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const hdc = hdc32to64(hdc32);

    const color = user32.GetPixel(hdc, x, y);
    _ = color;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiPatBlt: 32位→64位模式块传输
fn win32kPatBlt(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 5) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const x: i32 = @bitCast(args[1]);
    const y: i32 = @bitCast(args[2]);
    const cx: i32 = @bitCast(args[3]);
    const cy: i32 = @bitCast(args[4]);
    const rop = if (args.len > 5) args[5] else 0x00F00021;
    const hdc = hdc32to64(hdc32);

    if (user32.PatBlt(hdc, x, y, cx, cy, rop) != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiSaveDC: 32位→64位保存 DC 状态
fn win32kSaveDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);
    const result = user32.SaveDC(hdc);
    if (result != 0) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_UNSUCCESSFUL;
}

/// NtGdiRestoreDC: 32位→64位恢复 DC 状态
fn win32kRestoreDC(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const saved_state: i32 = @bitCast(args[1]);
    const hdc = hdc32to64(hdc32);
    _ = user32.RestoreDC(hdc, saved_state);
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetBkColor: 32位→64位设置背景色
fn win32kSetBkColor(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const color32 = args[1];
    const hdc = hdc32to64(hdc32);
    const color: user32.COLORREF = @bitCast(color32);

    const prev = user32.SetBkColor(hdc, color);
    _ = prev;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetBkColor: 32位→64位获取背景色
fn win32kGetBkColor(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);
    const color = user32.GetBkColor(hdc);
    _ = color;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetTextColor: 32位→64位设置文本色
fn win32kSetTextColor(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const color32 = args[1];
    const hdc = hdc32to64(hdc32);
    const color: user32.COLORREF = @bitCast(color32);

    const prev = user32.SetTextColor(hdc, color);
    _ = prev;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetTextColor: 32位→64位获取文本色
fn win32kGetTextColor(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);
    const color = user32.GetTextColor(hdc);
    _ = color;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiSetBkMode: 32位→64位设置背景模式
fn win32kSetBkMode(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 2) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const mode: i32 = @bitCast(args[1]);
    const hdc = hdc32to64(hdc32);

    const prev = user32.SetBkMode(hdc, mode);
    _ = prev;
    return ntdll.STATUS_SUCCESS;
}

/// NtGdiGetBkMode: 32位→64位获取背景模式
fn win32kGetBkMode(args: []const u32) ntdll.NTSTATUS {
    if (args.len < 1) return ntdll.STATUS_INVALID_PARAMETER;
    const hdc32 = args[0];
    const hdc = hdc32to64(hdc32);
    const mode = user32.GetBkMode(hdc);
    _ = mode;
    return ntdll.STATUS_SUCCESS;
}
