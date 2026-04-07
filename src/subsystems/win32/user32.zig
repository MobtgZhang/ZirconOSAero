//! user32 - Win32 User Interface API Subset
//! Phase 10: Window management, message queue, window classes,
//! message loop, input processing, and basic UI primitives.
//! C1：`DefWindowProcA` 处理 `WM_NCHITTEST` / `WM_NCCALCSIZE` / `WM_NCPAINT` 等默认 NC 路径；`broadcastDwm*` 与 `dwm.zig` 合成状态挂钩（`WM_DWM*`）。

const std = @import("std");
const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const build_options = @import("build_options");
const console_mod = @import("console.zig");
const subsystem = @import("subsystem.zig");
const process = @import("../../ps/process.zig");
const ntdll = @import("../../libs/ntdll.zig");
const win32k = @import("../win32k/mod.zig");
const dwm_comp = @import("../../drivers/video/root.zig").dwm_compositor;
const ipc = @import("../../lpc/ipc.zig");
const pm_sem = @import("msg_pm_semantics.zig");
const sched_mod = @import("../../ke/scheduler.zig");
const dwm_nt61_contract = @import("../../config/dwm_nt61_api_contract.zig");
const csr_dwm_listeners = @import("csr_dwm_listeners.zig");
const compositor_sync_nt61 = @import("../../config/compositor_sync_nt61.zig");

comptime {
    _ = @import("user32/split_anchor.zig");
}

/// 未绑定 DWM 重定向表面（`dwm_compositor` 未初始化或分配失败）。
pub const no_compositor_surface: u16 = 0xFFFF;

pub const BOOL = kernel32.BOOL;
pub const TRUE = kernel32.TRUE;
pub const FALSE = kernel32.FALSE;
pub const DWORD = kernel32.DWORD;
pub const WORD = kernel32.WORD;
pub const HANDLE = kernel32.HANDLE;

pub const HWND = u64;
pub const HMENU = u64;
pub const HICON = u64;
pub const HCURSOR = u64;
pub const HBRUSH = u64;
pub const HDC = u64;
pub const HINSTANCE = u64;
pub const WPARAM = u64;
pub const LPARAM = i64;
pub const LRESULT = i64;
pub const ATOM = u16;

pub const HWND_TOP: HWND = 0;
pub const HWND_BOTTOM: HWND = 1;
pub const HWND_TOPMOST: HWND = 0xFFFFFFFFFFFFFFFE;
pub const HWND_NOTOPMOST: HWND = 0xFFFFFFFFFFFFFFFD;
pub const HWND_DESKTOP: HWND = 0;

/// 桌面句柄：本内核为 csrss 活动窗口站内桌面索引的 **1-based** 值（0 表示无效）。
pub const HDESK = u32;

// ── Window Styles ──

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_DISABLED: DWORD = 0x08000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
    WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_ACCEPTFILES: DWORD = 0x00000010;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_WINDOWEDGE: DWORD = 0x00000100;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;

// ── Window Messages ──

pub const WM_NULL: u32 = 0x0000;
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_MOVE: u32 = 0x0003;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_ACTIVATE: u32 = 0x0006;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_ENABLE: u32 = 0x000A;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_NCPAINT: u32 = 0x0085;
pub const WM_NCCALCSIZE: u32 = 0x0083;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_SHOWWINDOW: u32 = 0x0018;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_USER: u32 = 0x0400;
pub const WM_APP: u32 = 0x8000;
pub const WM_SYSCOMMAND: u32 = 0x0112;
pub const WM_ENTERSIZEMOVE: u32 = 0x0231;
pub const WM_EXITSIZEMOVE: u32 = 0x0232;

pub const SC_MOVE: WPARAM = 0xF010;
pub const SC_SIZE: WPARAM = 0xF000;
pub const SC_CLOSE: WPARAM = 0xF060;

pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
pub const SWP_SHOWWINDOW: u32 = 0x0040;
pub const SWP_HIDEWINDOW: u32 = 0x0080;
pub const SWP_DRAWFRAME: u32 = 0x0020;
pub const SWP_FRAMECHANGED: u32 = SWP_DRAWFRAME;
pub const SWP_NOCOPYBITS: u32 = 0x0100;
pub const SWP_NOOWNERZORDER: u32 = 0x0200;
pub const SWP_NOREDRAW: u32 = 0x0800;
pub const SWP_NOSENDCHANGING: u32 = 0x0400;
pub const SWP_DEFERERASE: u32 = 0x2000;
pub const SWP_ASYNCWINDOWPOS: u32 = 0x4000;

pub const PM_NOREMOVE = pm_sem.PM_NOREMOVE;
pub const PM_REMOVE = pm_sem.PM_REMOVE;
pub const PM_NOYIELD = pm_sem.PM_NOYIELD;

pub const VK_ESCAPE: WPARAM = 0x1B;

// DWM 广播（与 Microsoft Learn 常量一致；单一数据源 `dwm_nt61_api_contract.zig`）
pub const WM_DWMCOMPOSITIONCHANGED: u32 = dwm_nt61_contract.WM_DWMCOMPOSITIONCHANGED;
pub const WM_DWMCOLORIZATIONCOLORCHANGED: u32 = dwm_nt61_contract.WM_DWMCOLORIZATIONCOLORCHANGED;
pub const WM_DWMNCRENDERINGCHANGED: u32 = dwm_nt61_contract.WM_DWMNCRENDERINGCHANGED;
pub const WM_DWMWINDOWMAXIMIZEDCHANGE: u32 = dwm_nt61_contract.WM_DWMWINDOWMAXIMIZEDCHANGE;
pub const WM_DWMSENDICONICTHUMBNAIL: u32 = dwm_nt61_contract.WM_DWMSENDICONICTHUMBNAIL;
pub const WM_DWMSENDICONICLIVEPREVIEWBITMAP: u32 = dwm_nt61_contract.WM_DWMSENDICONICLIVEPREVIEWBITMAP;

// 非客户区命中与移动（MSDN 常量值）
pub const WM_NCMOUSEMOVE: u32 = 0x00A0;
pub const WM_NCLBUTTONDOWN: u32 = 0x00A1;
pub const WM_NCLBUTTONUP: u32 = 0x00A2;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const WM_MOVING: u32 = 0x0216;

pub const HTERROR: i32 = -2;
pub const HTTRANSPARENT: i32 = -1;
pub const HTNOWHERE: i32 = 0;
pub const HTCLIENT: i32 = 1;
pub const HTCAPTION: i32 = 2;
pub const HTSYSMENU: i32 = 3;
pub const HTGROWBOX: i32 = 4;
pub const HTMENU: i32 = 5;
pub const HTHSCROLL: i32 = 6;
pub const HTVSCROLL: i32 = 7;
pub const HTMINBUTTON: i32 = 8;
pub const HTMAXBUTTON: i32 = 9;
pub const HTLEFT: i32 = 10;
pub const HTRIGHT: i32 = 11;
pub const HTTOP: i32 = 12;
pub const HTTOPLEFT: i32 = 13;
pub const HTTOPRIGHT: i32 = 14;
pub const HTBOTTOM: i32 = 15;
pub const HTBOTTOMLEFT: i32 = 16;
pub const HTBOTTOMRIGHT: i32 = 17;
pub const HTBORDER: i32 = 18;
pub const HTOBJECT: i32 = 19;
pub const HTCLOSE: i32 = 20;
pub const HTHELP: i32 = 21;

// ── Show Window Commands ──

pub const SW_HIDE: u32 = 0;
pub const SW_SHOWNORMAL: u32 = 1;
pub const SW_SHOWMINIMIZED: u32 = 2;
pub const SW_SHOWMAXIMIZED: u32 = 3;
pub const SW_SHOW: u32 = 5;
pub const SW_MINIMIZE: u32 = 6;
pub const SW_RESTORE: u32 = 9;

// ── System Metrics ──

pub const SM_CXSCREEN: u32 = 0;
pub const SM_CYSCREEN: u32 = 1;
pub const SM_CXFULLSCREEN: u32 = 16;
pub const SM_CYFULLSCREEN: u32 = 17;

// ── MessageBox Styles ──

pub const MB_OK: u32 = 0x00000000;
pub const MB_OKCANCEL: u32 = 0x00000001;
pub const MB_YESNOCANCEL: u32 = 0x00000003;
pub const MB_YESNO: u32 = 0x00000004;
pub const MB_ICONERROR: u32 = 0x00000010;
pub const MB_ICONQUESTION: u32 = 0x00000020;
pub const MB_ICONWARNING: u32 = 0x00000030;
pub const MB_ICONINFORMATION: u32 = 0x00000040;

pub const IDOK: u32 = 1;
pub const IDCANCEL: u32 = 2;
pub const IDYES: u32 = 6;
pub const IDNO: u32 = 7;

// ── Color Constants ──

pub const COLOR_WINDOW: u32 = 5;
pub const COLOR_WINDOWFRAME: u32 = 6;
pub const COLOR_WINDOWTEXT: u32 = 8;
pub const COLOR_BTNFACE: u32 = 15;
pub const COLOR_DESKTOP: u32 = 1;

// ── Cursor Constants ──

pub const IDC_ARROW: u32 = 32512;
pub const IDC_IBEAM: u32 = 32513;
pub const IDC_WAIT: u32 = 32514;
pub const IDC_CROSS: u32 = 32515;
pub const IDC_HAND: u32 = 32649;

// ── Structures ──

pub const POINT = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const SIZE = struct {
    cx: i32 = 0,
    cy: i32 = 0,
};

pub const RECT = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: *const RECT) i32 {
        return self.right - self.left;
    }

    pub fn height(self: *const RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const MSG = struct {
    hwnd: HWND = 0,
    message: u32 = 0,
    wparam: WPARAM = 0,
    lparam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const WNDCLASSA = struct {
    style: u32 = 0,
    wndproc_id: u32 = 0,
    cls_extra: i32 = 0,
    wnd_extra: i32 = 0,
    instance: HINSTANCE = 0,
    icon: HICON = 0,
    cursor: HCURSOR = 0,
    background: HBRUSH = 0,
    menu_name: [64]u8 = [_]u8{0} ** 64,
    menu_name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
};

pub const WNDCLASSEXA = struct {
    cb_size: u32 = @sizeOf(WNDCLASSEXA),
    style: u32 = 0,
    wndproc_id: u32 = 0,
    cls_extra: i32 = 0,
    wnd_extra: i32 = 0,
    instance: HINSTANCE = 0,
    icon: HICON = 0,
    cursor: HCURSOR = 0,
    background: HBRUSH = 0,
    menu_name: [64]u8 = [_]u8{0} ** 64,
    menu_name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    icon_sm: HICON = 0,
};

pub const PAINTSTRUCT = struct {
    hdc: HDC = 0,
    erase: BOOL = TRUE,
    paint_rect: RECT = .{},
    restore: BOOL = FALSE,
    inc_update: BOOL = FALSE,
    reserved: [32]u8 = [_]u8{0} ** 32,
};

/// `min=max=0` 时 **不过滤**（含 `WM_DWMCOMPOSITIONCHANGED` 等 DWM 广播）；否则为半开区间 `[min,max]`。
fn msgMatchesFilter(message: u32, min: u32, max: u32) bool {
    if (min == 0 and max == 0) return true;
    return message >= min and message <= max;
}

const MAX_THREAD_POSTED: usize = 24;
const ThreadPostedSlot = struct {
    tid: u32 = 0,
    used: bool = false,
    m: MSG = .{},
};
var thread_posted: [MAX_THREAD_POSTED]ThreadPostedSlot = [_]ThreadPostedSlot{.{}} ** MAX_THREAD_POSTED;

/// 调度线程 `tid`（`scheduler.getCurrentThreadId()`，小于 32）在 `GetMessage` 空队列上阻塞时的等待位（与 `wakeOneMsgWaiter` 配对）。
var msg_wait_mask: u32 = 0;

fn msgWaitBit(sched_tid: usize) u32 {
    if (sched_tid >= 32) return 0;
    const sh: u5 = @intCast(sched_tid);
    return @as(u32, 1) << sh;
}

fn clearMsgWaitBit(sched_tid: usize) void {
    msg_wait_mask &= ~msgWaitBit(sched_tid);
}

/// 是否有线程在 `GetMessage` 空队列路径上 `blockThread` 等待（`msg_wait_mask` 非零）。供桌面主循环加大 `input_hub` 轮询，缩短投递延迟（阶段 D）。
pub fn msgPumpThreadsBlockedApprox() bool {
    return msg_wait_mask != 0;
}

/// 唤醒首个在消息等待掩码上的线程（`PostMessage` / `PostThreadMessage` 路径调用）。
fn wakeOneMsgWaiter() void {
    if (!sched_mod.isInitialized()) return;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const sh: u5 = @truncate(i);
        const b = @as(u32, 1) << sh;
        if ((msg_wait_mask & b) != 0) {
            msg_wait_mask &= ~b;
            sched_mod.unblockThread(@intCast(i));
            return;
        }
    }
}

/// DWM 状态广播：除各窗口队列外，向登记线程投递 `PostThreadMessage`（权威 tid 表见 `csr_dwm_listeners.zig`）。
/// **首选**：用户进程经 csrss LPC `CsrApiNumber.register_dwm_listener` 登记（载荷布局见 `csr_lpc_policy` / `LPC_NT61_HANDSHAKE.md`）。
/// 本函数供内核/bootstrap 同址登记，与 LPC 写入同一表，广播路径一致（`broadcastDwmToListenerThreads`）。
pub fn registerDwmNotificationListener(tid: u32) void {
    csr_dwm_listeners.register(tid);
}

fn broadcastDwmToListenerThreads(msg: u32, wp: WPARAM, lp: LPARAM) void {
    var buf: [8]u32 = undefined;
    const n = csr_dwm_listeners.copyTids(&buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = PostThreadMessageA(buf[i], msg, wp, lp);
    }
}

fn tryQueueThreadPosted(tid: u32, m: MSG) bool {
    if (tid == 0) return false;
    for (&thread_posted) |*slot| {
        if (!slot.used) {
            slot.* = .{ .tid = tid, .used = true, .m = m };
            wakeOneMsgWaiter();
            return true;
        }
    }
    return false;
}

fn tryDequeueThreadPosted(tid: u32, min: u32, max: u32, out: *MSG) bool {
    for (&thread_posted) |*slot| {
        if (!slot.used or slot.tid != tid) continue;
        if (slot.m.message != WM_QUIT and !msgMatchesFilter(slot.m.message, min, max)) continue;
        out.* = slot.m;
        slot.used = false;
        return true;
    }
    return false;
}

fn packMsgForLpc(m: *const MSG, buf: *[44]u8) void {
    std.mem.writeInt(u64, buf[0..8], m.hwnd, .little);
    std.mem.writeInt(u32, buf[8..12], m.message, .little);
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    std.mem.writeInt(u64, buf[16..24], m.wparam, .little);
    std.mem.writeInt(i64, buf[24..32], m.lparam, .little);
    std.mem.writeInt(u32, buf[32..36], m.time, .little);
    std.mem.writeInt(i32, buf[36..40], m.pt.x, .little);
    std.mem.writeInt(i32, buf[40..44], m.pt.y, .little);
}

pub const CREATESTRUCTA = struct {
    create_params: u64 = 0,
    instance: HINSTANCE = 0,
    menu: HMENU = 0,
    parent: HWND = 0,
    cy: i32 = 0,
    cx: i32 = 0,
    y: i32 = 0,
    x: i32 = 0,
    style: DWORD = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    ex_style: DWORD = 0,
};

// ── Internal Window Object ──

const MAX_WINDOWS: usize = 64;
const MAX_WINDOW_CLASSES: usize = 32;
const MAX_MSG_QUEUE: usize = 128;

const Window = struct {
    hwnd: HWND = 0,
    is_valid: bool = false,
    is_visible: bool = false,
    is_enabled: bool = false,
    is_minimized: bool = false,
    is_maximized: bool = false,
    style: DWORD = 0,
    ex_style: DWORD = 0,
    class_id: u32 = 0,
    owner_pid: u32 = 0,
    /// 创建该窗口的线程（`GetMessage` hwnd==0 时仅投递到此线程；0 表示任意线程可读，兼容旧路径）。
    thread_id: u32 = 0,
    /// 内核 `dwm_compositor` 表面索引；`no_compositor_surface` 表示无。
    compositor_surface_id: u16 = no_compositor_surface,
    parent: HWND = 0,
    rect: RECT = .{},
    client_rect: RECT = .{},
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,
    instance: HINSTANCE = 0,
    menu: HMENU = 0,
    user_data: u64 = 0,
    wndproc_id: u32 = 0,
    needs_paint: bool = false,
    msg_queue: [MAX_MSG_QUEUE]MSG = [_]MSG{.{}} ** MAX_MSG_QUEUE,
    msg_head: usize = 0,
    msg_tail: usize = 0,
    msg_count: usize = 0,
    timer_id: u32 = 0,
    timer_interval: u32 = 0,
    timer_ticks: u32 = 0,
    /// `BeginPaint` 活跃：合成器可跳过覆盖客户区（与 `WM_PAINT` 懒惰语义配合的钩子）。
    app_painting: bool = false,
    /// `WS_EX_TOPMOST` / `SetWindowPos(HWND_TOPMOST|NOTOPMOST)`；与合成 Z 序「普通层→顶层」两趟一致。
    is_topmost: bool = false,

    pub fn getTitle(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn postMessage(self: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) bool {
        if (self.msg_count >= MAX_MSG_QUEUE) return false;
        self.msg_queue[self.msg_tail] = .{
            .hwnd = self.hwnd,
            .message = msg,
            .wparam = wparam,
            .lparam = lparam,
            .time = kernel32.GetTickCount(),
        };
        self.msg_tail = (self.msg_tail + 1) % MAX_MSG_QUEUE;
        self.msg_count += 1;
        wakeOneMsgWaiter();
        return true;
    }

    pub fn peekMessage(self: *Window) ?MSG {
        if (self.msg_count == 0) return null;
        return self.msg_queue[self.msg_head];
    }

    pub fn getMessage(self: *Window) ?MSG {
        if (self.msg_count == 0) return null;
        const msg = self.msg_queue[self.msg_head];
        self.msg_head = (self.msg_head + 1) % MAX_MSG_QUEUE;
        self.msg_count -= 1;
        return msg;
    }

    /// `WM_QUIT` 始终可取；否则在 `(min,max)` 非 `(0,0)` 时轮转队列以找到首条匹配（简化版过滤语义）。
    pub fn getMessageFiltered(self: *Window, min: u32, max: u32) ?MSG {
        if (self.msg_count == 0) return null;
        const n = self.msg_count;
        var step: usize = 0;
        while (step < n) : (step += 1) {
            const m = self.getMessage() orelse return null;
            if (m.message == WM_QUIT or msgMatchesFilter(m.message, min, max)) {
                return m;
            }
            _ = self.postMessage(m.message, m.wparam, m.lparam);
        }
        return null;
    }

    pub fn peekMessageFiltered(self: *Window, min: u32, max: u32) ?MSG {
        if (self.msg_count == 0) return null;
        var i: usize = 0;
        while (i < self.msg_count) : (i += 1) {
            const idx = (self.msg_head + i) % MAX_MSG_QUEUE;
            const m = self.msg_queue[idx];
            if (m.message == WM_QUIT or msgMatchesFilter(m.message, min, max)) {
                return m;
            }
        }
        return null;
    }
};

const WindowClass = struct {
    is_registered: bool = false,
    style: u32 = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    wndproc_id: u32 = 0,
    background: HBRUSH = 0,
    cursor: HCURSOR = 0,
    icon: HICON = 0,
    instance: HINSTANCE = 0,
    atom: ATOM = 0,

    pub fn getName(self: *const WindowClass) []const u8 {
        return self.class_name[0..self.class_name_len];
    }
};

// ── Global State ──

var windows: [MAX_WINDOWS]Window = [_]Window{.{}} ** MAX_WINDOWS;
var window_count: usize = 0;
var next_hwnd: HWND = 0x10000;

var window_classes: [MAX_WINDOW_CLASSES]WindowClass = [_]WindowClass{.{}} ** MAX_WINDOW_CLASSES;
var class_count: usize = 0;
var next_atom: ATOM = 0xC000;

var focus_hwnd: HWND = 0;
var capture_hwnd: HWND = 0;
var active_hwnd: HWND = 0;
var foreground_hwnd: HWND = 0;

/// 内核侧 **WndProc 子集**：`RegisterClass*` 的 `wndproc_id` 非 0 时，在此表登记则 `DispatchMessageA` 优先调用（矩阵 §5；非用户 VA 函数指针）。
const max_kernel_wndproc: usize = 8;
var kernel_wndproc_ids: [max_kernel_wndproc]u32 = [_]u32{0} ** max_kernel_wndproc;
var kernel_wndproc_fns: [max_kernel_wndproc]?KernelWndProcFn = [_]?KernelWndProcFn{null} ** max_kernel_wndproc;
var kernel_wndproc_count: usize = 0;

pub const KernelWndProcFn = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.c) LRESULT;

/// 登记 `wndproc_id` → 内核可调用例程；`id==0` 拒绝。供测试或内置类使用。
pub fn registerKernelWndProc(id: u32, pfn: KernelWndProcFn) bool {
    if (id == 0 or kernel_wndproc_count >= max_kernel_wndproc) return false;
    kernel_wndproc_ids[kernel_wndproc_count] = id;
    kernel_wndproc_fns[kernel_wndproc_count] = pfn;
    kernel_wndproc_count += 1;
    return true;
}

fn dispatchKernelWndProcById(id: u32, hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) ?LRESULT {
    var i: usize = 0;
    while (i < kernel_wndproc_count) : (i += 1) {
        if (kernel_wndproc_ids[i] == id) {
            if (kernel_wndproc_fns[i]) |f| return f(hwnd, msg, wp, lp);
        }
    }
    return null;
}

/// 与 `build_options.kernel_preferred_fb_*`（build.conf RESOLUTION / sync）一致；桌面就绪后 `syncScreenFromFramebuffer()` 与内核 FB 再对齐。
var screen_width: i32 = @as(i32, @intCast(build_options.kernel_preferred_fb_width));
var screen_height: i32 = @as(i32, @intCast(build_options.kernel_preferred_fb_height));

pub fn getScreenWidth() i32 {
    return screen_width;
}

pub fn getScreenHeight() i32 {
    return screen_height;
}

/// 向已创建 **顶级**（`parent == 0`）窗口投递 `WM_DWMCOMPOSITIONCHANGED`（合成启用/关闭）；供 csrss / 壳层在 DWM 状态变化时调用。
/// **尚无 HWND**：不向窗口队列投递（与 `dwm.syncPolicyFromRegistry` 启动豁免一致）；仍向 `register_dwm_listener` 线程投递，以便 `initGuiSubsystem` 等引导路径可收通知。
pub fn broadcastDwmCompositionChanged(composition_on: BOOL) void {
    const wp: WPARAM = dwm_nt61_contract.compositionChangedWParam(composition_on != 0);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMCOMPOSITIONCHANGED, wp, 0);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMCOMPOSITIONCHANGED, wp, 0);
}

/// `WM_DWMCOLORIZATIONCOLORCHANGED`：`wParam` 为 `COLORREF` 风格 ARGB，`lParam` 非零表示启用混合（简化语义）。
pub fn broadcastDwmColorizationChanged(argb: u32, blend_enabled: BOOL) void {
    const wp: WPARAM = argb;
    const lp: LPARAM = dwm_nt61_contract.colorizationChangedLParam(blend_enabled != 0);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMCOLORIZATIONCOLORCHANGED, wp, lp);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMCOLORIZATIONCOLORCHANGED, wp, lp);
}

/// 内核 `dwm.zig` → **专用 inbox（PID 62）** → `handleApiCall` → `broadcastDwm*`，避免 `dwm` 直接依赖 `subsystem` 产生模块环。
pub fn notifyDwmCompositionKernelToUserspace(composition_on: BOOL) void {
    const wp: u32 = @truncate(dwm_nt61_contract.compositionChangedWParam(composition_on != 0));
    subsystem.queueKernelDwmNotifyLpc(.composition, wp, 0);
    subsystem.drainKernelDwmLpcInbox(16);
}

pub fn notifyDwmColorizationKernelToUserspace(argb: u32, blend_enabled: BOOL) void {
    const lp: i64 = dwm_nt61_contract.colorizationChangedLParam(blend_enabled != 0);
    subsystem.queueKernelDwmNotifyLpc(.colorization, argb, lp);
    subsystem.drainKernelDwmLpcInbox(16);
}

pub fn notifyDwmNcRenderingKernelToUserspace(policy_enabled: BOOL) void {
    const wp: u32 = @truncate(dwm_nt61_contract.ncRenderingChangedWParam(policy_enabled != 0));
    subsystem.queueKernelDwmNotifyLpc(.nc_rendering, wp, 0);
    subsystem.drainKernelDwmLpcInbox(16);
}

pub fn broadcastDwmNcRenderingChanged(policy_enabled: BOOL) void {
    const wp: WPARAM = dwm_nt61_contract.ncRenderingChangedWParam(policy_enabled != 0);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMNCRENDERINGCHANGED, wp, 0);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMNCRENDERINGCHANGED, wp, 0);
}

/// Ref: Learn — WM_DWMSENDICONICTHUMBNAIL；`lParam` 低 16 位为请求最大宽度、高 16 位为最大高度（与 `MAKELPARAM` 布局一致）。
pub fn broadcastDwmIconicThumbnailRequested(max_w: u32, max_h: u32) void {
    const lp: LPARAM = dwm_nt61_contract.iconicSizeRequestLParam(max_w, max_h);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMSENDICONICTHUMBNAIL, 0, lp);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMSENDICONICTHUMBNAIL, 0, lp);
}

/// Ref: Learn — `WM_DWMWINDOWMAXIMIZEDCHANGE`；`wParam` 非零表示最大化状态。
pub fn broadcastDwmWindowMaximizedChanged(maximized: BOOL) void {
    const wp: WPARAM = dwm_nt61_contract.windowMaximizedChangeWParam(maximized != 0);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMWINDOWMAXIMIZEDCHANGE, wp, 0);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMWINDOWMAXIMIZEDCHANGE, wp, 0);
}

/// Ref: Learn — `WM_DWMSENDICONICLIVEPREVIEWBITMAP`；`lParam` 与缩略图请求相同的宽高打包。
pub fn broadcastDwmIconicLivePreviewBitmapRequested(max_w: u32, max_h: u32) void {
    const lp: LPARAM = dwm_nt61_contract.iconicSizeRequestLParam(max_w, max_h);
    if (getWindowCount() != 0) {
        var wi: usize = 0;
        while (wi < window_count) : (wi += 1) {
            if (windows[wi].is_valid and windows[wi].parent == 0) {
                _ = windows[wi].postMessage(WM_DWMSENDICONICLIVEPREVIEWBITMAP, 0, lp);
            }
        }
    }
    broadcastDwmToListenerThreads(WM_DWMSENDICONICLIVEPREVIEWBITMAP, 0, lp);
}

fn syncWin32kFromUser32() void {
    win32k.clearWindowTableForSync();
    var z: i32 = 0;
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        const w = &windows[i];
        if (!w.is_valid or w.is_topmost) continue;
        const r = win32k.Rect{
            .left = w.rect.left,
            .top = w.rect.top,
            .right = w.rect.right,
            .bottom = w.rect.bottom,
        };
        _ = win32k.windowAttach(.{
            .hwnd = w.hwnd,
            .parent = if (w.parent == 0) null else w.parent,
            .rect = r,
            .z_order = z,
            .visible = w.is_visible,
        });
        z += 1;
    }
    i = 0;
    while (i < window_count) : (i += 1) {
        const w = &windows[i];
        if (!w.is_valid or !w.is_topmost) continue;
        const r = win32k.Rect{
            .left = w.rect.left,
            .top = w.rect.top,
            .right = w.rect.right,
            .bottom = w.rect.bottom,
        };
        _ = win32k.windowAttach(.{
            .hwnd = w.hwnd,
            .parent = if (w.parent == 0) null else w.parent,
            .rect = r,
            .z_order = z,
            .visible = w.is_visible,
        });
        z += 1;
    }
}

/// `CreateWindowEx` 与 csrss `register_window`（`onCsrssRegisterGuiWindow`）共用的表面绑定 + 几何 + Z + win32k 同步（DesktopManagerSpec §3.3 单真源）。
fn refreshGuiWindowCompositorAndTables(w: *Window) void {
    ensureCompositorSurface(w);
    notifyCompositorWindowGeometry(w);
    syncCompositorZOrderForUserWindows();
    syncWin32kFromUser32();
}

/// LPC `register_window` 与 `CreateWindowEx` 共用的合成表面分配（问题五 P5-5）：避免两处 `createSurface` 分叉漂移。
fn ensureCompositorSurface(w: *Window) void {
    if (!dwm_comp.isInitialized()) return;
    if (w.compositor_surface_id != no_compositor_surface) return;
    const aw: u32 = @intCast(@max(0, w.rect.width()));
    const ah: u32 = @intCast(@max(0, w.rect.height()));
    if (dwm_comp.createSurface(w.rect.left, w.rect.top, aw, ah, w.owner_pid)) |sid| {
        w.compositor_surface_id = sid;
        notifyCompositorWindowGeometry(w);
        syncCompositorZOrderForUserWindows();
    }
}

fn notifyCompositorWindowGeometry(w: *Window) void {
    if (!dwm_comp.isInitialized()) return;
    if (w.compositor_surface_id == no_compositor_surface) return;
    const id = w.compositor_surface_id;
    const cw: u32 = @intCast(@max(0, w.rect.width()));
    const ch: u32 = @intCast(@max(0, w.rect.height()));
    dwm_comp.moveSurface(id, w.rect.left, w.rect.top);
    dwm_comp.resizeSurface(id, cw, ch);
    dwm_comp.markSurfaceDirty(id);
}

var compositor_tree_sync_gen: u32 = 0;

fn syncCompositorZOrderForUserWindows() void {
    if (!dwm_comp.isInitialized()) return;
    compositor_tree_sync_gen +%= 1;
    if (compositor_tree_sync_gen == 0) compositor_tree_sync_gen = 1;
    const gen = compositor_tree_sync_gen;

    var buf: [MAX_WINDOWS]compositor_sync_nt61.TreeSurfaceEntryV1 = undefined;
    var n: usize = 0;
    var zi: i16 = 10;
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        const w = &windows[i];
        if (!w.is_valid or w.is_topmost) continue;
        if (w.compositor_surface_id == no_compositor_surface) continue;
        buf[n] = .{ .surface_id = w.compositor_surface_id, .z_order = zi };
        n += 1;
        zi += 10;
    }
    i = 0;
    while (i < window_count) : (i += 1) {
        const w = &windows[i];
        if (!w.is_valid or !w.is_topmost) continue;
        if (w.compositor_surface_id == no_compositor_surface) continue;
        buf[n] = .{ .surface_id = w.compositor_surface_id, .z_order = zi };
        n += 1;
        zi += 10;
    }
    const max_chunk: usize = compositor_sync_nt61.compositor_tree_sync_v1_max_entries;
    var off: usize = 0;
    while (off < n) {
        const take = @min(max_chunk, n - off);
        subsystem.queueCompositorTreeSyncLpc(gen, buf[off..][0..take]);
        off += take;
    }
    if (n > 0) subsystem.drainKernelDwmLpcInbox(64);
}

var user32_initialized: bool = false;
var total_messages_processed: u64 = 0;
var total_windows_created: u64 = 0;

// ── Window Class Registration ──

pub fn RegisterClassA(wc: *const WNDCLASSA) ATOM {
    if (class_count >= MAX_WINDOW_CLASSES) return 0;

    var cls = &window_classes[class_count];
    cls.* = .{};
    cls.is_registered = true;
    cls.style = wc.style;
    cls.wndproc_id = wc.wndproc_id;
    cls.background = wc.background;
    cls.cursor = wc.cursor;
    cls.icon = wc.icon;
    cls.instance = wc.instance;

    const n = @min(wc.class_name_len, cls.class_name.len);
    @memcpy(cls.class_name[0..n], wc.class_name[0..n]);
    cls.class_name_len = n;

    cls.atom = next_atom;
    next_atom += 1;
    class_count += 1;

    klog.debug("user32: RegisterClass '%s' -> atom=%u", .{ cls.getName(), cls.atom });
    return cls.atom;
}

pub fn RegisterClassExA(wc: *const WNDCLASSEXA) ATOM {
    var simple: WNDCLASSA = .{};
    simple.style = wc.style;
    simple.wndproc_id = wc.wndproc_id;
    simple.cls_extra = wc.cls_extra;
    simple.wnd_extra = wc.wnd_extra;
    simple.instance = wc.instance;
    simple.icon = wc.icon;
    simple.cursor = wc.cursor;
    simple.background = wc.background;
    @memcpy(&simple.class_name, &wc.class_name);
    simple.class_name_len = wc.class_name_len;
    return RegisterClassA(&simple);
}

pub fn UnregisterClassA(class_name: []const u8, _: HINSTANCE) BOOL {
    for (window_classes[0..class_count]) |*cls| {
        if (cls.is_registered and strEqlI(cls.getName(), class_name)) {
            cls.is_registered = false;
            return TRUE;
        }
    }
    return FALSE;
}

fn findClass(class_name: []const u8) ?*WindowClass {
    for (window_classes[0..class_count]) |*cls| {
        if (cls.is_registered and strEqlI(cls.getName(), class_name)) return cls;
    }
    return null;
}

fn findClassByAtom(atom: ATOM) ?*WindowClass {
    for (window_classes[0..class_count]) |*cls| {
        if (cls.is_registered and cls.atom == atom) return cls;
    }
    return null;
}

/// 供测试 / 将来 `NtUser` 对齐：窗口类 ATOM 是否仍登记。
pub fn isClassAtomLive(atom: ATOM) bool {
    return findClassByAtom(atom) != null;
}

// ── Window Creation/Destruction ──

fn detachCompositorSurface(w: *Window) void {
    if (w.compositor_surface_id != no_compositor_surface) {
        dwm_comp.destroySurface(w.compositor_surface_id);
        w.compositor_surface_id = no_compositor_surface;
    }
}

pub const CW_USEDEFAULT: i32 = @as(i32, @bitCast(@as(u32, 0x80000000)));

/// Ref: Microsoft Learn — `CreateWindowEx` 成功返回 HWND、失败 `NULL` 与 `SetLastError`（矩阵 §5）。
pub fn CreateWindowExA(
    ex_style: DWORD,
    class_name: []const u8,
    window_name: []const u8,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: HWND,
    menu: HMENU,
    instance: HINSTANCE,
    _: u64,
) HWND {
    if (window_count >= MAX_WINDOWS) {
        kernel32.SetLastError(kernel32.ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    if (class_name.len > 0 and findClass(class_name) == null) {
        kernel32.SetLastError(kernel32.ERROR_CANNOT_FIND_WND_CLASS);
        return 0;
    }

    const cls = findClass(class_name);
    const cls_id: u32 = if (cls) |c| c.atom else 0;

    var wnd = &windows[window_count];
    wnd.* = .{};
    wnd.hwnd = next_hwnd;
    wnd.is_valid = true;
    wnd.style = style;
    wnd.ex_style = ex_style;
    wnd.is_topmost = (ex_style & WS_EX_TOPMOST) != 0;
    wnd.class_id = cls_id;
    wnd.parent = parent;
    wnd.instance = instance;
    wnd.menu = menu;
    wnd.owner_pid = kernel32.GetCurrentProcessId();

    if (cls) |c| {
        wnd.wndproc_id = c.wndproc_id;
    }

    const actual_x = if (x == CW_USEDEFAULT) @as(i32, 100) else x;
    const actual_y = if (y == CW_USEDEFAULT) @as(i32, 100) else y;
    const actual_w = if (width == CW_USEDEFAULT) @as(i32, 640) else width;
    const actual_h = if (height == CW_USEDEFAULT) @as(i32, 480) else height;

    wnd.rect = .{
        .left = actual_x,
        .top = actual_y,
        .right = actual_x + actual_w,
        .bottom = actual_y + actual_h,
    };
    wnd.client_rect = .{
        .left = 0,
        .top = 0,
        .right = actual_w,
        .bottom = actual_h,
    };

    const tn = @min(window_name.len, wnd.title.len);
    @memcpy(wnd.title[0..tn], window_name[0..tn]);
    wnd.title_len = tn;

    next_hwnd += 1;
    window_count += 1;
    total_windows_created += 1;

    wnd.thread_id = kernel32.GetCurrentThreadId();
    wnd.compositor_surface_id = no_compositor_surface;

    _ = wnd.postMessage(WM_CREATE, 0, 0);

    if ((style & WS_VISIBLE) != 0) {
        wnd.is_visible = true;
        _ = wnd.postMessage(WM_SHOWWINDOW, 1, 0);
    }

    refreshGuiWindowCompositorAndTables(wnd);

    klog.debug("user32: CreateWindow '%s' hwnd=0x%x (%dx%d)", .{
        window_name, wnd.hwnd, actual_w, actual_h,
    });

    kernel32.SetLastError(kernel32.ERROR_SUCCESS);
    return wnd.hwnd;
}

pub fn DestroyWindow(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse {
        kernel32.SetLastError(kernel32.ERROR_INVALID_HANDLE);
        return FALSE;
    };
    // 先释放合成表面再失效窗口，避免 `dwm_compositor` 残留 id 指向已释放槽位（与 `onCsrssRegisterGuiWindow` 分配路径对偶）。
    detachCompositorSurface(wnd);
    _ = wnd.postMessage(WM_DESTROY, 0, 0);
    wnd.is_valid = false;
    wnd.is_visible = false;

    if (focus_hwnd == hwnd) focus_hwnd = 0;
    if (active_hwnd == hwnd) active_hwnd = 0;
    if (foreground_hwnd == hwnd) foreground_hwnd = 0;

    syncWin32kFromUser32();
    syncCompositorZOrderForUserWindows();
    return TRUE;
}

// ── Window Properties ──

pub fn ShowWindow(hwnd: HWND, cmd: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const was_visible = wnd.is_visible;

    switch (cmd) {
        SW_HIDE => wnd.is_visible = false,
        SW_SHOW, SW_SHOWNORMAL, SW_RESTORE => {
            wnd.is_visible = true;
            wnd.is_minimized = false;
            wnd.is_maximized = false;
        },
        SW_SHOWMINIMIZED, SW_MINIMIZE => {
            wnd.is_visible = true;
            wnd.is_minimized = true;
        },
        SW_SHOWMAXIMIZED => {
            wnd.is_visible = true;
            wnd.is_maximized = true;
            wnd.rect = .{ .left = 0, .top = 0, .right = screen_width, .bottom = screen_height };
        },
        else => {},
    }

    _ = wnd.postMessage(WM_SHOWWINDOW, if (wnd.is_visible) 1 else 0, 0);
    notifyCompositorWindowGeometry(wnd);
    syncWin32kFromUser32();
    return if (was_visible) TRUE else FALSE;
}

pub fn UpdateWindow(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.needs_paint = true;
    _ = wnd.postMessage(WM_PAINT, 0, 0);
    return TRUE;
}

pub fn EnableWindow(hwnd: HWND, enable: BOOL) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const was_enabled = wnd.is_enabled;
    wnd.is_enabled = (enable == TRUE);
    _ = wnd.postMessage(WM_ENABLE, if (wnd.is_enabled) 1 else 0, 0);
    return if (!was_enabled) TRUE else FALSE;
}

pub fn IsWindow(hwnd: HWND) BOOL {
    return if (findWindow(hwnd) != null) TRUE else FALSE;
}

pub fn IsWindowVisible(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    return if (wnd.is_visible) TRUE else FALSE;
}

pub fn IsWindowEnabled(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    return if (wnd.is_enabled) TRUE else FALSE;
}

pub fn GetWindowRect(hwnd: HWND, rect: *RECT) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    rect.* = wnd.rect;
    return TRUE;
}

pub fn GetClientRect(hwnd: HWND, rect: *RECT) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    rect.* = wnd.client_rect;
    return TRUE;
}

pub fn BringWindowToTop(hwnd: HWND) BOOL {
    bringHwndToTop(hwnd);
    return TRUE;
}

/// 将窗口移到 **同 band**（`is_topmost`）内的最前（合成最高 z）；不与另一 band 交叉换位。
fn bringHwndToTop(hw: HWND) void {
    while (true) {
        var i: usize = 0;
        var cur: ?usize = null;
        while (i < window_count) : (i += 1) {
            if (windows[i].hwnd == hw and windows[i].is_valid) {
                cur = i;
                break;
            }
        }
        const ci = cur orelse return;
        const topmost = windows[ci].is_topmost;
        var j = ci + 1;
        var next: ?usize = null;
        while (j < window_count) : (j += 1) {
            if (!windows[j].is_valid) continue;
            if (windows[j].is_topmost != topmost) continue;
            next = j;
            break;
        }
        const nx = next orelse break;
        std.mem.swap(Window, &windows[ci], &windows[nx]);
    }
    syncCompositorZOrderForUserWindows();
    syncWin32kFromUser32();
}

/// 与 `bringHwndToTop` 对称：同 band 内最低 z（`windows` 数组更靠前的一侧）。
fn sendHwndToBottom(hw: HWND) void {
    while (true) {
        var i: usize = 0;
        var cur: ?usize = null;
        while (i < window_count) : (i += 1) {
            if (windows[i].hwnd == hw and windows[i].is_valid) {
                cur = i;
                break;
            }
        }
        const ci = cur orelse return;
        if (ci == 0) break;
        const topmost = windows[ci].is_topmost;
        var j: isize = @as(isize, @intCast(ci)) - 1;
        var prev: ?usize = null;
        while (j >= 0) : (j -= 1) {
            const uj: usize = @intCast(j);
            if (!windows[uj].is_valid) continue;
            if (windows[uj].is_topmost != topmost) continue;
            prev = uj;
            break;
        }
        const pu = prev orelse break;
        std.mem.swap(Window, &windows[ci], &windows[pu]);
    }
    syncCompositorZOrderForUserWindows();
    syncWin32kFromUser32();
}

pub fn SetWindowPos(hwnd: HWND, insert_after: HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    // Learn：`SWP_FRAMECHANGED`/`SWP_NOCOPYBITS`/`SWP_NOREDRAW`/`SWP_DEFERERASE`/`SWP_ASYNCWINDOWPOS`/`SWP_NOSENDCHANGING`/`SWP_NOOWNERZORDER` 影响 NC 帧与重绘调度；本子集无完整 GDI 重定向队列，上述位无害忽略。
    _ = flags & (SWP_DRAWFRAME | SWP_FRAMECHANGED | SWP_NOCOPYBITS | SWP_NOREDRAW | SWP_DEFERERASE | SWP_ASYNCWINDOWPOS | SWP_NOSENDCHANGING | SWP_NOOWNERZORDER);
    const w0 = wnd.rect.width();
    const h0 = wnd.rect.height();

    if ((flags & SWP_NOMOVE) == 0) {
        wnd.rect.left = x;
        wnd.rect.top = y;
        if ((flags & SWP_NOSIZE) != 0) {
            wnd.rect.right = wnd.rect.left + w0;
            wnd.rect.bottom = wnd.rect.top + h0;
        }
    }
    if ((flags & SWP_NOSIZE) == 0) {
        wnd.rect.right = wnd.rect.left + cx;
        wnd.rect.bottom = wnd.rect.top + cy;
        wnd.client_rect.right = cx;
        wnd.client_rect.bottom = cy;
    }

    if ((flags & SWP_NOZORDER) == 0) {
        if (insert_after == HWND_TOPMOST) {
            wnd.is_topmost = true;
            bringHwndToTop(hwnd);
        } else if (insert_after == HWND_NOTOPMOST) {
            // Ref: Learn — `HWND_NOTOPMOST` 仅在窗口当前为 topmost 时生效：取消 topmost 并置于所有非 topmost 之上；若已非 topmost 则 **不改变** Z 序。
            if (wnd.is_topmost) {
                wnd.is_topmost = false;
                bringHwndToTop(hwnd);
            }
        } else if (insert_after == HWND_TOP) {
            bringHwndToTop(hwnd);
        } else if (insert_after == HWND_BOTTOM) {
            sendHwndToBottom(hwnd);
        } else if (findWindow(insert_after) != null) {
            placeHwndAboveInsertAfter(hwnd, insert_after);
        }
    }

    if ((flags & SWP_NOACTIVATE) == 0 and (flags & SWP_HIDEWINDOW) == 0) {
        _ = SetActiveWindow(hwnd);
    }
    if ((flags & SWP_SHOWWINDOW) != 0) {
        wnd.is_visible = true;
    }
    if ((flags & SWP_HIDEWINDOW) != 0) {
        wnd.is_visible = false;
    }

    _ = wnd.postMessage(WM_MOVE, 0, 0);
    _ = wnd.postMessage(WM_SIZE, 0, 0);
    notifyCompositorWindowGeometry(wnd);
    if ((flags & SWP_NOZORDER) == 0) {
        syncCompositorZOrderForUserWindows();
        syncWin32kFromUser32();
    } else {
        syncWin32kFromUser32();
    }
    return TRUE;
}

pub fn MoveWindow(hwnd: HWND, x: i32, y: i32, width: i32, height: i32, repaint: BOOL) BOOL {
    _ = repaint;
    return SetWindowPos(hwnd, 0, x, y, width, height, 0);
}

pub fn SetWindowTextA(hwnd: HWND, text: []const u8) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const n = @min(text.len, wnd.title.len);
    @memcpy(wnd.title[0..n], text[0..n]);
    wnd.title_len = n;
    return TRUE;
}

pub fn GetWindowTextA(hwnd: HWND, buffer: []u8) i32 {
    const wnd = findWindow(hwnd) orelse return 0;
    const n = @min(wnd.title_len, buffer.len);
    @memcpy(buffer[0..n], wnd.title[0..n]);
    return @intCast(n);
}

pub fn GetWindowTextLengthA(hwnd: HWND) i32 {
    const wnd = findWindow(hwnd) orelse return 0;
    return @intCast(wnd.title_len);
}

// ── Focus/Active Window ──

pub fn SetFocus(hwnd: HWND) HWND {
    const old = focus_hwnd;
    if (findWindow(hwnd)) |wnd| {
        if (old != hwnd) {
            if (findWindow(old)) |old_wnd| {
                _ = old_wnd.postMessage(WM_KILLFOCUS, hwnd, 0);
            }
            _ = wnd.postMessage(WM_SETFOCUS, old, 0);
        }
        focus_hwnd = hwnd;
    }
    return old;
}

pub fn GetFocus() HWND {
    return focus_hwnd;
}

pub fn SetActiveWindow(hwnd: HWND) HWND {
    const old = active_hwnd;
    if (findWindow(hwnd) != null) {
        active_hwnd = hwnd;
    }
    return old;
}

pub fn GetActiveWindow() HWND {
    return active_hwnd;
}

pub fn SetForegroundWindow(hwnd: HWND) BOOL {
    if (findWindow(hwnd) != null) {
        foreground_hwnd = hwnd;
        return TRUE;
    }
    return FALSE;
}

pub fn GetForegroundWindow() HWND {
    return foreground_hwnd;
}

pub fn GetDesktopWindow() HWND {
    return HWND_DESKTOP;
}

/// 切换活动桌面（csrss 窗口站内 `Desktop` 对象）；名称须与 `createDesktop` 一致（如 `Default`）。
pub fn SwitchDesktopByName(name: []const u8) BOOL {
    return if (subsystem.switchToDesktop(name)) TRUE else FALSE;
}

/// Ref: Learn — `SwitchDesktop` / `SwitchDesktopA`（本子集与 `SwitchDesktopByName` 同路径）。
pub fn SwitchDesktopA(name: []const u8) BOOL {
    return SwitchDesktopByName(name);
}

/// 子集：`lpszDevice`/`pDevmode`/`lpsa` 未用；与 `subsystem.createUserDesktop` 一致。
pub fn CreateDesktopA(
    name: []const u8,
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    flags: DWORD,
    _: DWORD,
    _: ?*const anyopaque,
) HDESK {
    _ = flags;
    if (name.len == 0) return 0;
    return subsystem.createUserDesktop(name);
}

/// 子集：按名称打开已存在桌面（`openDesktopByName`）。
pub fn OpenDesktopA(
    name: []const u8,
    _: DWORD,
    _: BOOL,
    _: DWORD,
) HDESK {
    if (name.len == 0) return 0;
    return subsystem.openDesktopByName(name);
}

/// 将 Win32 进程绑定到当前窗口站内的桌面索引。
pub fn SetProcessDesktopByIndex(pid: DWORD, desktop_index: DWORD) BOOL {
    return if (subsystem.setProcessDesktop(pid, desktop_index)) TRUE else FALSE;
}

// ── Message Loop ──
// `NtUserGetMessage`：空队列仍可能 `STATUS_PENDING`（协作式）。`NtUserPeekMessage`：空队列返回 **`STATUS_NO_MORE_ENTRIES`** 且清零 `MSG*`（非 `STATUS_SUCCESS`，便于用户态映射为 Learn 的 `FALSE` 且不与 `WM_NULL` 混淆）— 见矩阵 §5 与 `msg_pm_semantics.zig`。

pub fn GetMessageA(msg: *MSG, hwnd: HWND, min: u32, max: u32) BOOL {
    if (!pm_sem.minMaxRangeWellFormed(min, max)) {
        kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
        msg.* = .{};
        return FALSE;
    }
    const tid = kernel32.GetCurrentThreadId();
    if (tryDequeueThreadPosted(tid, min, max, msg)) {
        total_messages_processed += 1;
        return if (msg.message != WM_QUIT) TRUE else FALSE;
    }
    if (hwnd != 0) {
        const wnd = findWindow(hwnd) orelse return FALSE;
        if (wnd.getMessageFiltered(min, max)) |m| {
            msg.* = m;
            total_messages_processed += 1;
            return if (m.message != WM_QUIT) TRUE else FALSE;
        }
    } else {
        for (windows[0..window_count]) |*wnd| {
            if (!wnd.is_valid) continue;
            if (wnd.thread_id != 0 and wnd.thread_id != tid) continue;
            if (wnd.getMessageFiltered(min, max)) |m| {
                msg.* = m;
                total_messages_processed += 1;
                return if (m.message != WM_QUIT) TRUE else FALSE;
            }
        }
    }
    msg.* = .{};
    return FALSE;
}

/// 与 `GetMessageA` 相同语义；空队列时多线程下可经 `blockThread` + 投递路径 `wakeOneMsgWaiter` 近似 Learn 的阻塞；单线程或仅一调度线程时仍为协作式 `yield`，耗尽后 `NtUserGetMessage` 返回 `STATUS_PENDING`（与 Learn「无限阻塞直至有消息」有差距，见契约矩阵）。
pub fn getMessageAWithYield(msg: *MSG, hwnd: HWND, min: u32, max: u32) BOOL {
    const max_spins: u32 = build_options.get_message_yield_spins;
    var s: u32 = 0;
    const sched_tid: usize = if (sched_mod.isInitialized()) sched_mod.getCurrentThreadId() else 0;
    while (s < max_spins) : (s += 1) {
        if (GetMessageA(msg, hwnd, min, max) == TRUE) {
            if (sched_tid < 32) clearMsgWaitBit(sched_tid);
            return TRUE;
        }
        if (sched_mod.isInitialized()) {
            if (sched_mod.getThreadCount() > 1 and sched_tid < 32) {
                msg_wait_mask |= msgWaitBit(sched_tid);
                sched_mod.blockThread(sched_tid);
            }
            sched_mod.yield();
        } else if (builtin.target.cpu.arch == .x86_64) {
            asm volatile ("pause" ::: .{ .memory = true });
        } else if (builtin.target.cpu.arch == .loongarch64) {
            asm volatile ("idle 0" ::: .{ .memory = true });
        } else if (builtin.target.cpu.arch == .aarch64) {
            asm volatile ("yield" ::: .{ .memory = true });
        }
    }
    if (sched_tid < 32) clearMsgWaitBit(sched_tid);
    msg.* = .{};
    return FALSE;
}

fn userVirtRangeMapped(va: u64, len: u64) bool {
    if (len == 0) return false;
    const proc = process.getCurrentProcess() orelse return false;
    const space = proc.address_space orelse return false;
    const page: u64 = 4096;
    var a = va;
    const end = va +% len;
    if (end < va) return false;
    while (a < end) {
        const pg = a & ~(page - 1);
        if (space.getPhysical(pg) == null) return false;
        a = pg + page;
    }
    return true;
}

/// `NtUserGetMessage` 内核路径：AMD64 约定第 1 参在 `R10`（`MSG *`）。
/// 与 Learn：`GetMessage` 在空队列时应阻塞直至有消息；本实现 **不** 在内核里无限阻塞用户线程：
/// - 多线程：`getMessageAWithYield` 可 `blockThread`，由 `PostMessage`/`wakeOneMsgWaiter` 唤醒；
/// - 单线程：协作式 `yield` 至多 `build_options.get_message_yield_spins` 次后仍无消息则 **`STATUS_PENDING`** 且将用户 `MSG*` 清零（与 Win32 `GetMessage` 不返回直到有消息 **不同**，用户态须轮询或接调度器）。
/// `syscall.zig` 将 `NTSTATUS` 透传为 syscall 结果；勿假设与真 NT `NtUserGetMessage` 阻塞语义逐位一致。
pub fn ntUserGetMessageSyscall(msg_user_va: u64, hwnd: HWND, min_msg: u32, max_msg: u32) ntdll.NTSTATUS {
    const msg_len: u64 = @sizeOf(MSG);
    if ((msg_user_va & 7) != 0) return ntdll.STATUS_INVALID_PARAMETER;
    if (!userVirtRangeMapped(msg_user_va, msg_len)) return ntdll.STATUS_ACCESS_VIOLATION;
    if (!pm_sem.minMaxRangeWellFormed(min_msg, max_msg)) {
        const um: *volatile MSG = @ptrFromInt(msg_user_va);
        um.* = .{};
        kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
        return ntdll.STATUS_INVALID_PARAMETER;
    }
    var km: MSG = undefined;
    if (getMessageAWithYield(&km, hwnd, min_msg, max_msg) == FALSE) {
        const um: *volatile MSG = @ptrFromInt(msg_user_va);
        um.* = .{};
        return ntdll.STATUS_PENDING;
    }
    const um: *volatile MSG = @ptrFromInt(msg_user_va);
    um.* = km;
    return ntdll.STATUS_SUCCESS;
}

/// `NtUserPeekMessage`：第 5 参 `wRemoveMsg`（如 `PM_REMOVE`）在用户栈上。
/// Ref: Learn — `PeekMessage` 无消息时返回 **FALSE**（非错误）。本 syscall **无消息时返回 `STATUS_NO_MORE_ENTRIES`**（`0x8000001A`）并清零 `MSG*`；用户态 `PeekMessage` 包装应将其映射为 FALSE，**勿**与失败 NTSTATUS 混同。有消息时返回 `STATUS_SUCCESS`。
pub fn ntUserPeekMessageSyscall(msg_user_va: u64, hwnd: HWND, min_msg: u32, max_msg: u32, remove_flags: u32) ntdll.NTSTATUS {
    const msg_len: u64 = @sizeOf(MSG);
    if ((msg_user_va & 7) != 0) return ntdll.STATUS_INVALID_PARAMETER;
    if (!userVirtRangeMapped(msg_user_va, msg_len)) return ntdll.STATUS_ACCESS_VIOLATION;
    if (!pm_sem.minMaxRangeWellFormed(min_msg, max_msg)) {
        const um: *volatile MSG = @ptrFromInt(msg_user_va);
        um.* = .{};
        kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
        return ntdll.STATUS_INVALID_PARAMETER;
    }
    var km: MSG = undefined;
    if (PeekMessageA(&km, hwnd, min_msg, max_msg, remove_flags) == FALSE) {
        const um: *volatile MSG = @ptrFromInt(msg_user_va);
        um.* = .{};
        return ntdll.STATUS_NO_MORE_ENTRIES;
    }
    const um: *volatile MSG = @ptrFromInt(msg_user_va);
    um.* = km;
    return ntdll.STATUS_SUCCESS;
}

/// `NtUserPostMessage`：R10=`HWND`，RDX=`Msg`，R8=`wParam`，R9=`lParam`（按位转 `i64`）。
pub fn ntUserPostMessageSyscall(hwnd: u64, msg: u32, wparam: u64, lparam_bits: u64) ntdll.NTSTATUS {
    const lp: i64 = @bitCast(lparam_bits);
    if (PostMessageA(hwnd, msg, wparam, lp) == TRUE) return ntdll.STATUS_SUCCESS;
    return switch (kernel32.GetLastError()) {
        kernel32.ERROR_NOT_ENOUGH_MEMORY => ntdll.STATUS_NO_MEMORY,
        else => ntdll.STATUS_INVALID_PARAMETER,
    };
}

/// `NtUserSendMessage`：寄存器约定同 `NtUserPostMessage`（当前实现等价异步 `PostMessage`）。
pub fn ntUserSendMessageSyscall(hwnd: u64, msg: u32, wparam: u64, lparam_bits: u64) ntdll.NTSTATUS {
    return ntUserPostMessageSyscall(hwnd, msg, wparam, lparam_bits);
}

/// `NtUserDispatchMessage`：`R10`=用户 `MSG*`（syscall 层已 probe）；与 `DispatchMessageA` 同路径（无独立 WndProc 表时即 `DefWindowProcA`）。
pub fn ntUserDispatchMessageSyscall(msg_va: u64) ntdll.NTSTATUS {
    if (msg_va == 0 or (msg_va & 7) != 0) return ntdll.STATUS_INVALID_PARAMETER;
    // SAFETY: `syscall.zig` 已对当前进程用户区 `MSG` 做 `probeUserMemory` 可读探测。
    const msg_user: *const volatile MSG = @ptrFromInt(msg_va);
    const km: MSG = msg_user.*;
    _ = DispatchMessageA(&km);
    return ntdll.STATUS_SUCCESS;
}

/// `NtUserSetWindowPos`：R10=`HWND`，RDX=`hWndInsertAfter`，R8=`X`，R9=`Y`；栈 +0=`cx`，+8=`cy`，+16=`uFlags`。
pub fn ntUserSetWindowPosSyscall(
    hwnd: u64,
    insert_after: u64,
    x: u64,
    y: u64,
    cx: u64,
    cy: u64,
    flags: u32,
) ntdll.NTSTATUS {
    const xi: i32 = @truncate(@as(i64, @bitCast(x)));
    const yi: i32 = @truncate(@as(i64, @bitCast(y)));
    const cxi: i32 = @truncate(@as(i64, @bitCast(cx)));
    const cyi: i32 = @truncate(@as(i64, @bitCast(cy)));
    if (SetWindowPos(hwnd, insert_after, xi, yi, cxi, cyi, flags) == TRUE) return ntdll.STATUS_SUCCESS;
    kernel32.SetLastError(kernel32.ERROR_INVALID_HANDLE);
    return ntdll.STATUS_INVALID_PARAMETER;
}

/// 与 `PeekMessageA` 相同，但用显式 `tid`（CSR 路径下无可靠的用户态 `GetCurrentThreadId`）。
fn peekMessageAForThread(tid: u32, msg: *MSG, hwnd: HWND, min: u32, max: u32, remove: u32) BOOL {
    if (!pm_sem.minMaxRangeWellFormed(min, max)) {
        kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
        return FALSE;
    }
    const do_remove = pm_sem.removeMsgFromQueueOnPeek(remove);
    if (do_remove) {
        if (tryDequeueThreadPosted(tid, min, max, msg)) return TRUE;
    }
    if (hwnd != 0) {
        const wnd = findWindow(hwnd) orelse return FALSE;
        if (do_remove) {
            if (wnd.getMessageFiltered(min, max)) |m| {
                msg.* = m;
                total_messages_processed += 1;
                return TRUE;
            }
        } else {
            if (wnd.peekMessageFiltered(min, max)) |m| {
                msg.* = m;
                return TRUE;
            }
        }
    } else {
        for (windows[0..window_count]) |*wnd| {
            if (!wnd.is_valid) continue;
            if (wnd.thread_id != 0 and wnd.thread_id != tid) continue;
            if (do_remove) {
                if (wnd.getMessageFiltered(min, max)) |m| {
                    msg.* = m;
                    total_messages_processed += 1;
                    return TRUE;
                }
            } else {
                if (wnd.peekMessageFiltered(min, max)) |m| {
                    msg.* = m;
                    return TRUE;
                }
            }
        }
    }
    return FALSE;
}

/// csrss `get_message`：请求缓冲 0–8=`HWND`，8–12=min，12–16=max，16–20=`PM_*`；20–24=线程 id（小端）。
/// **`tid==0` 非法**（与 `CreateWindowEx` 线程队列对齐）；见 `csr_lpc_policy.resolveGetMessageClientTid`、[DesktopManagerSpec.md](../../docs/cn/DesktopManagerSpec.md) §3.4。
/// 成功时 `ipc.csr_reply_payload` 含 44 字节 `MSG`。
pub fn csrFillOneMessageForLpc(client_tid: u32, hwnd: HWND, min_v: u32, max_v: u32, remove_flags: u32) i32 {
    var km: MSG = undefined;
    if (peekMessageAForThread(client_tid, &km, hwnd, min_v, max_v, remove_flags) == FALSE) return -1;
    var buf: [44]u8 = undefined;
    packMsgForLpc(&km, &buf);
    ipc.csrReplyPayloadSet(&buf);
    return 0;
}

pub fn PeekMessageA(msg: *MSG, hwnd: HWND, min: u32, max: u32, remove: u32) BOOL {
    // Ref: Learn — `PM_NOREMOVE` = 未置 `PM_REMOVE`；`PM_NOYIELD` = 不向调度器 yield。本路径 **从不** `blockThread`/`yield`，与 `GetMessage` 区分；标志与 `msg_pm_semantics.allowSchedulerYieldForPeekFlags` 对齐供契约测试引用。
    _ = pm_sem.allowSchedulerYieldForPeekFlags(remove);
    return peekMessageAForThread(kernel32.GetCurrentThreadId(), msg, hwnd, min, max, remove);
}

pub fn TranslateMessage(_: *const MSG) BOOL {
    return TRUE;
}

/// Ref: Learn — `DispatchMessage` 调用窗口 `WndProc`；本仓库以 `class_id`（ATOM）→ `WindowClass.wndproc_id`，命中 `registerKernelWndProc` 表则先调内核例程，否则 `DefWindowProcA`（矩阵 §5）。
/// **D-D1-7**：`WM_DWM*` 的默认应答在 `DefWindowProcA`（返回 0）；内核 `wndproc_id` 若需拦截须自行处理或显式再调 `DefWindowProcA`，勿假定表项自动转发。
pub fn DispatchMessageA(msg: *const MSG) LRESULT {
    total_messages_processed += 1;
    if (msg.hwnd != 0) {
        if (findWindow(msg.hwnd)) |w| {
            if (findClassByAtom(@truncate(w.class_id))) |cls| {
                if (cls.wndproc_id != 0) {
                    if (dispatchKernelWndProcById(cls.wndproc_id, msg.hwnd, msg.message, msg.wparam, msg.lparam)) |lr| return lr;
                }
            }
        }
    }
    return DefWindowProcA(msg.hwnd, msg.message, msg.wparam, msg.lparam);
}

pub fn PostMessageA(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) BOOL {
    const wnd = findWindow(hwnd) orelse {
        kernel32.SetLastError(kernel32.ERROR_INVALID_HANDLE);
        return FALSE;
    };
    if (!wnd.postMessage(msg, wparam, lparam)) {
        kernel32.SetLastError(kernel32.ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }
    return TRUE;
}

/// Ref: Learn — `PostThreadMessage`；与窗口队列分离的每线程投递（先于 `GetMessage` 窗口扫描）。
pub fn PostThreadMessageA(idThread: u32, msg: u32, wparam: WPARAM, lparam: LPARAM) BOOL {
    if (idThread == 0) return FALSE;
    const m = MSG{
        .hwnd = 0,
        .message = msg,
        .wparam = wparam,
        .lparam = lparam,
        .time = kernel32.GetTickCount(),
        .pt = .{},
    };
    return if (tryQueueThreadPosted(idThread, m)) TRUE else FALSE;
}

pub fn SendMessageA(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) LRESULT {
    _ = PostMessageA(hwnd, msg, wparam, lparam);
    return 0;
}

/// Ref: Learn — `PostQuitMessage` 向**调用线程**的消息队列投递 `WM_QUIT`（`hwnd` 为空）；与每条窗口队列分别投递不同。
pub fn PostQuitMessage(exit_code: i32) void {
    const tid = kernel32.GetCurrentThreadId();
    const wp: WPARAM = @intCast(@as(u32, @bitCast(exit_code)));
    _ = PostThreadMessageA(tid, WM_QUIT, wp, 0);
}

// ── Painting ──

pub fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) HDC {
    const wnd = findWindow(hwnd) orelse {
        kernel32.SetLastError(kernel32.ERROR_INVALID_HANDLE);
        return 0;
    };
    ps.* = .{};
    ps.paint_rect = wnd.client_rect;
    ps.hdc = hwnd;
    wnd.needs_paint = false;
    wnd.app_painting = true;
    if (wnd.compositor_surface_id != no_compositor_surface) {
        dwm_comp.markSurfaceDirty(wnd.compositor_surface_id);
    }
    return ps.hdc;
}

pub fn EndPaint(hwnd: HWND, _: *const PAINTSTRUCT) BOOL {
    if (findWindow(hwnd)) |w| {
        w.app_painting = false;
    }
    return TRUE;
}

pub fn InvalidateRect(hwnd: HWND, _: ?*const RECT, _: BOOL) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.needs_paint = true;
    if (wnd.compositor_surface_id != no_compositor_surface) {
        dwm_comp.markSurfaceDirty(wnd.compositor_surface_id);
    }
    return TRUE;
}

/// 供 gdi32 校验：`GetDC(hwnd)` 成功时本子集将 **`HDC == hwnd`**（与 `CreateCompatibleDC` 池内句柄并存）。
/// Ref: Microsoft Learn — `GetDC` / `GetDC` 对 `NULL` 的屏幕 DC 概念（本仓库为 **Partial**：`hwnd==0` 返回 `0` 且成功，见 `GetDC`）。
pub fn hdcIsWindowClientDrawable(hdc: HDC) bool {
    return findWindow(hdc) != null;
}

/// Ref: Microsoft Learn — `GetDC` 成功返回 DC 句柄，失败 `NULL` 与 `SetLastError`；`GetDC(NULL)` 为屏幕 DC（此处 `hwnd==0` 返回 `0` 且 `ERROR_SUCCESS`，**非**完整屏幕位图语义）。
pub fn GetDC(hwnd: HWND) HDC {
    if (hwnd == 0) {
        kernel32.SetLastError(kernel32.ERROR_SUCCESS);
        return 0;
    }
    if (findWindow(hwnd)) |w| {
        if (w.compositor_surface_id != no_compositor_surface) {
            dwm_comp.markSurfaceDirty(w.compositor_surface_id);
        }
        kernel32.SetLastError(kernel32.ERROR_SUCCESS);
        return hwnd;
    }
    kernel32.SetLastError(kernel32.ERROR_INVALID_HANDLE);
    return 0;
}

/// Ref: Microsoft Learn — `ReleaseDC` 须与取得 DC 的方式配对；窗口 DC 子集要求 `hdc == hwnd`。
pub fn ReleaseDC(hwnd: HWND, hdc: HDC) i32 {
    if (hdc == 0) {
        if (hwnd != 0) {
            kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
            return 0;
        }
        kernel32.SetLastError(kernel32.ERROR_SUCCESS);
        return 1;
    }
    if (findWindow(hdc) != null) {
        if (hwnd != hdc) {
            kernel32.SetLastError(kernel32.ERROR_INVALID_PARAMETER);
            return 0;
        }
        kernel32.SetLastError(kernel32.ERROR_SUCCESS);
        return 1;
    }
    kernel32.SetLastError(kernel32.ERROR_SUCCESS);
    return 1;
}

// ── Timer ──

pub fn SetTimer(hwnd: HWND, id: u32, interval: u32, _: u64) u32 {
    const wnd = findWindow(hwnd) orelse return 0;
    wnd.timer_id = id;
    wnd.timer_interval = interval;
    wnd.timer_ticks = 0;
    return id;
}

pub fn KillTimer(hwnd: HWND, _: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.timer_id = 0;
    wnd.timer_interval = 0;
    return TRUE;
}

// ── System Metrics ──

pub fn GetSystemMetrics(index: u32) i32 {
    return switch (index) {
        SM_CXSCREEN, SM_CXFULLSCREEN => screen_width,
        SM_CYSCREEN, SM_CYFULLSCREEN => screen_height,
        else => 0,
    };
}

// ── Message Box ──

pub fn MessageBoxA(_: HWND, text: []const u8, caption: []const u8, mb_type: u32) u32 {
    klog.info("MessageBox: [%s] %s (type=0x%x)", .{ caption, text, mb_type });

    if ((mb_type & 0x0F) == MB_OK) return IDOK;
    if ((mb_type & 0x0F) == MB_OKCANCEL) return IDOK;
    if ((mb_type & 0x0F) == MB_YESNO) return IDYES;
    if ((mb_type & 0x0F) == MB_YESNOCANCEL) return IDYES;
    return IDOK;
}

// ── Mouse Capture ──

pub fn SetCapture(hwnd: HWND) HWND {
    const old = capture_hwnd;
    if (findWindow(hwnd) != null) capture_hwnd = hwnd;
    return old;
}

pub fn ReleaseCapture() BOOL {
    capture_hwnd = 0;
    return TRUE;
}

pub fn GetCapture() HWND {
    return capture_hwnd;
}

// ── Misc ──

pub fn GetParent(hwnd: HWND) HWND {
    const wnd = findWindow(hwnd) orelse return 0;
    return wnd.parent;
}

pub fn SetWindowLongA(hwnd: HWND, index: i32, value: u64) u64 {
    const wnd = findWindow(hwnd) orelse return 0;
    const GWL_USERDATA: i32 = -21;
    const GWL_STYLE: i32 = -16;
    const GWL_EXSTYLE: i32 = -20;

    return switch (index) {
        GWL_USERDATA => blk: {
            const old = wnd.user_data;
            wnd.user_data = value;
            break :blk old;
        },
        GWL_STYLE => blk: {
            const old = wnd.style;
            wnd.style = @intCast(value & 0xFFFFFFFF);
            break :blk old;
        },
        GWL_EXSTYLE => blk: {
            const old = wnd.ex_style;
            wnd.ex_style = @intCast(value & 0xFFFFFFFF);
            break :blk old;
        },
        else => 0,
    };
}

pub fn GetWindowLongA(hwnd: HWND, index: i32) u64 {
    const wnd = findWindow(hwnd) orelse return 0;
    const GWL_USERDATA: i32 = -21;
    const GWL_STYLE: i32 = -16;
    const GWL_EXSTYLE: i32 = -20;

    return switch (index) {
        GWL_USERDATA => wnd.user_data,
        GWL_STYLE => wnd.style,
        GWL_EXSTYLE => wnd.ex_style,
        else => 0,
    };
}

fn pointFromLParam(lp: LPARAM) POINT {
    const u: u32 = @truncate(@as(u64, @bitCast(lp)));
    const lx: u16 = @truncate(u & 0xFFFF);
    const ly: u16 = @truncate(u >> 16);
    return .{
        .x = @as(i16, @bitCast(lx)),
        .y = @as(i16, @bitCast(ly)),
    };
}

/// 与 MSDN `DwmDefWindowProc` 对齐的占位：**TRUE** 表示消息已由 DWM 消费且调用方应使用合成器提供的 `lResult`（本仓库合成在 `dwm_compositor`，此处恒 **FALSE**，`DefWindowProcA` 继续走 `defNcHitTestForWindow` 等内核默认 NC）。
pub fn DwmDefWindowProcA(_: HWND, _: u32, _: WPARAM, _: LPARAM) BOOL {
    return FALSE;
}

fn runModalMoveLoop(hwnd: HWND) LRESULT {
    const wnd = findWindow(hwnd) orelse return 0;
    const saved = wnd.rect;
    _ = PostMessageA(hwnd, WM_ENTERSIZEMOVE, 0, 0);
    const prev_cap = SetCapture(hwnd);
    defer {
        _ = ReleaseCapture();
        if (prev_cap != 0) _ = SetCapture(prev_cap);
        _ = PostMessageA(hwnd, WM_EXITSIZEMOVE, 0, 0);
    }
    var have_last = false;
    var last_pt: POINT = undefined;
    while (true) {
        var msg: MSG = undefined;
        if (GetMessageA(&msg, hwnd, 0, 0) == FALSE) break;
        switch (msg.message) {
            WM_MOUSEMOVE => {
                const pt = pointFromLParam(msg.lparam);
                if (!have_last) {
                    last_pt = pt;
                    have_last = true;
                    continue;
                }
                const dx = pt.x - last_pt.x;
                const dy = pt.y - last_pt.y;
                last_pt = pt;
                wnd.rect.left += dx;
                wnd.rect.right += dx;
                wnd.rect.top += dy;
                wnd.rect.bottom += dy;
                notifyCompositorWindowGeometry(wnd);
                _ = PostMessageA(hwnd, WM_MOVING, 0, 0);
            },
            WM_LBUTTONUP => break,
            WM_KEYDOWN => {
                if (msg.wparam == VK_ESCAPE) {
                    wnd.rect = saved;
                    notifyCompositorWindowGeometry(wnd);
                    break;
                }
            },
            else => {
                _ = TranslateMessage(&msg);
                _ = DispatchMessageA(&msg);
            },
        }
    }
    return 0;
}

fn defNcHitTestForWindow(wnd: *const Window, screen_x: i32, screen_y: i32) LRESULT {
    const r = wnd.rect;
    if (screen_x < r.left or screen_y < r.top or screen_x >= r.right or screen_y >= r.bottom)
        return HTNOWHERE;

    const st = wnd.style;
    const thick = (st & WS_THICKFRAME) != 0;
    const frame: i32 = if (thick) 6 else 0;
    const cap_h: i32 = if ((st & WS_CAPTION) != 0) 32 else 0;

    const left = r.left;
    const right = r.right;
    const top = r.top;
    const bottom = r.bottom;

    if (thick) {
        if (screen_y < top + frame) {
            if (screen_x < left + frame) return HTTOPLEFT;
            if (screen_x >= right - frame) return HTTOPRIGHT;
            return HTTOP;
        }
        if (screen_y >= bottom - frame) {
            if (screen_x < left + frame) return HTBOTTOMLEFT;
            if (screen_x >= right - frame) return HTBOTTOMRIGHT;
            return HTBOTTOM;
        }
        if (screen_x < left + frame) return HTLEFT;
        if (screen_x >= right - frame) return HTRIGHT;
    }

    if (cap_h > 0 and screen_y < top + cap_h) {
        const inner_right = right - frame;
        const btn: i32 = 42;
        const x_from_right = inner_right - screen_x;
        const has_chrome = (st & WS_MINIMIZEBOX) != 0 or (st & WS_MAXIMIZEBOX) != 0 or (st & WS_SYSMENU) != 0;
        if (has_chrome) {
            if (x_from_right > 0 and x_from_right <= btn) return HTCLOSE;
            if ((st & WS_MAXIMIZEBOX) != 0 and x_from_right > btn and x_from_right <= 2 * btn) return HTMAXBUTTON;
            if ((st & WS_MINIMIZEBOX) != 0 and x_from_right > 2 * btn and x_from_right <= 3 * btn) return HTMINBUTTON;
        }
        if ((st & WS_SYSMENU) != 0 and screen_x < left + frame + 28) return HTSYSMENU;
        return HTCAPTION;
    }
    return HTCLIENT;
}

pub fn DefWindowProcA(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) LRESULT {
    switch (msg) {
        WM_NCHITTEST => {
            if (DwmDefWindowProcA(hwnd, msg, wparam, lparam) != FALSE) {
                return 0;
            }
            const wnd = findWindow(hwnd) orelse return HTNOWHERE;
            const pt = pointFromLParam(lparam);
            return defNcHitTestForWindow(wnd, pt.x, pt.y);
        },
        WM_NCLBUTTONDOWN => {
            if (wparam == @as(WPARAM, @intCast(HTCAPTION))) {
                _ = PostMessageA(hwnd, WM_SYSCOMMAND, SC_MOVE, lparam);
            }
            return 0;
        },
        WM_SYSCOMMAND => {
            const cmd = wparam & ~@as(WPARAM, 0x0F);
            if (cmd == SC_MOVE) {
                return runModalMoveLoop(hwnd);
            }
            return 0;
        },
        WM_NCMOUSEMOVE => return 0,
        WM_NCCALCSIZE => return 0,
        WM_NCPAINT => return 0,
        WM_ERASEBKGND => return 1,
        // DWM 通知：应用通常自行处理以刷新主题/缩略图；未处理时 `DefWindowProc` 返回 0 即可（与 Learn「须处理」不冲突——无默认绘制）。
        WM_DWMCOMPOSITIONCHANGED, WM_DWMNCRENDERINGCHANGED, WM_DWMCOLORIZATIONCOLORCHANGED, WM_DWMWINDOWMAXIMIZEDCHANGE, WM_DWMSENDICONICTHUMBNAIL, WM_DWMSENDICONICLIVEPREVIEWBITMAP => return 0,
        WM_CLOSE => return 0,
        WM_DESTROY => return 0,
        WM_PAINT => return 0,
        else => return 0,
    }
}

pub fn LoadCursorA(_: HINSTANCE, _: u32) HCURSOR {
    return 1;
}

pub fn LoadIconA(_: HINSTANCE, _: u32) HICON {
    return 1;
}

// ── Helpers ──

fn findWindow(hwnd: HWND) ?*Window {
    for (windows[0..window_count]) |*wnd| {
        if (wnd.hwnd == hwnd and wnd.is_valid) return wnd;
    }
    return null;
}

/// `dwmapi` / 合成路径：有效 HWND 且已绑定 `dwm_compositor` 表面时返回表面 id。
pub fn tryGetCompositorSurfaceId(hwnd: HWND) ?u16 {
    const w = findWindow(hwnd) orelse return null;
    if (w.compositor_surface_id == no_compositor_surface) return null;
    return w.compositor_surface_id;
}

fn findWindowIndex(hw: HWND) ?usize {
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (windows[i].hwnd == hw and windows[i].is_valid) return i;
    }
    return null;
}

/// `hWndInsertAfter` 为**另一有效 HWND** 时：将 `hwnd` 置于该窗口**之上**（`windows` 数组中紧跟其后的槽位，与 `syncCompositorZOrderForUserWindows` 递增 z 一致）。
/// 跨 topmost / 非 topmost **band** 时：先将 `hwnd` 的 `is_topmost` 与 `insert_after` 对齐（与公开 Win32「相对某窗 Z 序」同属一层之概念一致），再在同 band 内冒泡。
fn placeHwndAboveInsertAfter(hwnd: HWND, insert_after: HWND) void {
    if (hwnd == insert_after) return;
    const wa = findWindow(hwnd) orelse return;
    const wb = findWindow(insert_after) orelse return;
    if (wa.is_topmost != wb.is_topmost) {
        wa.is_topmost = wb.is_topmost;
    }
    while (true) {
        const ia = findWindowIndex(insert_after) orelse return;
        const ib = findWindowIndex(hwnd) orelse return;
        if (ia + 1 >= window_count) {
            bringHwndToTop(hwnd);
            return;
        }
        const t = ia + 1;
        if (ib == t) break;
        if (ib < t) {
            std.mem.swap(Window, &windows[ib], &windows[ib + 1]);
        } else {
            std.mem.swap(Window, &windows[ib], &windows[ib - 1]);
        }
    }
    syncCompositorZOrderForUserWindows();
    syncWin32kFromUser32();
}

/// csrss `register_window`：刷新该 HWND 的合成脏区与 win32k 表（LPC 负载见 `subsystem.zig` 注释）。
pub fn onCsrssRegisterGuiWindow(pid: u32, hwnd: HWND) void {
    _ = pid;
    if (findWindow(hwnd)) |w| {
        refreshGuiWindowCompositorAndTables(w);
    }
}

fn strEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const ax = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const by = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (ax != by) return false;
    }
    return true;
}

// ── Statistics ──

pub fn getWindowCount() usize {
    var count: usize = 0;
    for (windows[0..window_count]) |*wnd| {
        if (wnd.is_valid) count += 1;
    }
    return count;
}

pub fn getClassCount() usize {
    return class_count;
}

pub fn getTotalMessagesProcessed() u64 {
    return total_messages_processed;
}

pub fn getTotalWindowsCreated() u64 {
    return total_windows_created;
}

// ── Demo ──

pub fn runGuiDemo() void {
    klog.info("user32: --- GUI Subsystem Demo ---", .{});

    var wc: WNDCLASSA = .{};
    const cls_name = "ZirconMainWindow";
    @memcpy(wc.class_name[0..cls_name.len], cls_name);
    wc.class_name_len = cls_name.len;
    wc.background = COLOR_WINDOW + 1;
    wc.cursor = IDC_ARROW;
    const atom = RegisterClassA(&wc);
    klog.info("user32: RegisterClass 'ZirconMainWindow' atom=%u", .{atom});

    const hwnd = CreateWindowExA(
        0,
        cls_name,
        "ZirconOSAero - Main Window",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        0,
        0,
        0,
        0,
    );
    klog.info("user32: CreateWindow hwnd=0x%x", .{hwnd});

    _ = ShowWindow(hwnd, SW_SHOWNORMAL);
    _ = UpdateWindow(hwnd);
    _ = SetFocus(hwnd);

    const notepad_hwnd = CreateWindowExA(
        0,
        cls_name,
        "Untitled - Notepad",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        150,
        150,
        500,
        400,
        0,
        0,
        0,
        0,
    );
    klog.info("user32: Notepad window hwnd=0x%x", .{notepad_hwnd});

    _ = MessageBoxA(hwnd, "ZirconOSAero GUI subsystem initialized!", "ZirconOSAero", MB_OK | MB_ICONINFORMATION);

    var msg: MSG = .{};
    var processed: u32 = 0;
    while (processed < 5) {
        if (GetMessageA(&msg, 0, 0, 0) == TRUE) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageA(&msg);
            processed += 1;
        } else break;
    }

    _ = DestroyWindow(notepad_hwnd);
    _ = DestroyWindow(hwnd);

    klog.info("user32: Demo complete: %u windows, %u messages processed", .{
        getWindowCount(), getTotalMessagesProcessed(),
    });
}

// ── Initialization ──

pub fn init() void {
    win32k.clearWindowTableForSync();
    for (&thread_posted) |*s| s.* = .{};
    msg_wait_mask = 0;
    window_count = 0;
    class_count = 0;
    next_hwnd = 0x10000;
    next_atom = 0xC000;
    focus_hwnd = 0;
    active_hwnd = 0;
    foreground_hwnd = 0;
    capture_hwnd = 0;
    total_messages_processed = 0;
    total_windows_created = 0;
    user32_initialized = true;

    if (build_options.desktop_full) {
        klog.info("user32: desktop-full (-Ddesktop-full) enabled for extended shell/DWM experiments", .{});
    }
    klog.info("user32: Win32 User Interface API initialized", .{});
    klog.info("user32: Window APIs: CreateWindowEx, DestroyWindow, ShowWindow, MoveWindow", .{});
    klog.info("user32: Message APIs: GetMessage, PeekMessage, PostMessage, DispatchMessage", .{});
    klog.info("user32: Paint APIs: BeginPaint, EndPaint, InvalidateRect, GetDC", .{});
    klog.info("user32: Input APIs: SetFocus, SetCapture, SetTimer, MessageBox", .{});
    klog.info("user32: Screen: %ux%u (default; sync after desktop FB init)", .{
        @as(u32, @intCast(screen_width)),
        @as(u32, @intCast(screen_height)),
    });
}

/// 桌面 `initDesktopMode` 之后调用，使 GetSystemMetrics 与真实帧缓冲一致。
pub fn syncScreenFromFramebuffer() void {
    const fb = @import("../../drivers/video/root.zig").framebuffer;
    const drivers = @import("../../drivers/mod.zig");
    if (!fb.isInitialized()) return;
    const w = fb.getWidth();
    const h = fb.getHeight();
    if (w == 0 or h == 0) return;
    screen_width = @intCast(w);
    screen_height = @intCast(h);
    drivers.notifyDisplayGeometryChanged(w, h);
    klog.info("user32: Screen synced to kernel framebuffer: %ux%u", .{ w, h });
}
