//! Win32 Subsystem Server (csrss-like)
//! Phase 9-10: Manages Win32 subsystem registration, console sessions,
//! window stations, desktops, GUI message dispatch, and process lifecycle.

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const ob = @import("../../ob/object.zig");
const process = @import("../../ps/process.zig");
const port = @import("../../lpc/port.zig");
const ipc = @import("../../lpc/ipc.zig");
const console_mod = @import("console.zig");
const pe_loader = @import("../../loader/pe.zig");
const user32 = @import("user32.zig");
const gdi32 = @import("gdi32.zig");

pub const CSRSS_VERSION: []const u8 = "ZirconOSAero CSRSS v1.0";

// **P4-C3**：`CsrApiNumber` 与窗口站/桌面占位结构与契约矩阵 §9.2 对齐；完整 CSRSS 握手见 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md)。

pub const SubsystemType = enum(u8) {
    unknown = 0,
    native = 1,
    win32_gui = 2,
    win32_cui = 3,
    posix = 7,
};

pub const SessionState = enum(u8) {
    inactive = 0,
    initializing = 1,
    active = 2,
    shutdown = 3,
};

pub const ProcessSubsysState = enum(u8) {
    not_registered = 0,
    registered = 1,
    connected = 2,
    terminated = 3,
};

pub const CsrApiNumber = enum(u32) {
    create_process = 0x10000,
    create_thread = 0x10001,
    terminate_process = 0x10002,
    alloc_console = 0x10010,
    free_console = 0x10011,
    set_console_title = 0x10012,
    write_console = 0x10013,
    read_console = 0x10014,
    create_window_station = 0x10020,
    create_desktop = 0x10021,
    register_window = 0x10022,
    destroy_window = 0x10023,
    post_message = 0x10024,
    get_message = 0x10025,
    create_dc = 0x10026,
    register_dwm_listener = 0x10027,
    shutdown_system = 0x10030,
    _,
};

// ── Window Station ──

const MAX_WINDOW_STATIONS: usize = 4;
const MAX_DESKTOPS: usize = 8;

pub const Desktop = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    is_active: bool = false,
    station_id: u32 = 0,
    width: u32 = 80,
    height: u32 = 25,
};

pub const WindowStation = struct {
    header: ob.ObjectHeader = .{ .obj_type = .device },
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    is_active: bool = false,
    session_id: u32 = 0,
    desktops: [MAX_DESKTOPS]Desktop = [_]Desktop{.{}} ** MAX_DESKTOPS,
    desktop_count: usize = 0,

    pub fn createDesktop(self: *WindowStation, name: []const u8) ?*Desktop {
        if (self.desktop_count >= MAX_DESKTOPS) return null;
        var desk = &self.desktops[self.desktop_count];
        desk.* = .{};
        desk.is_active = true;
        desk.station_id = @intCast(self.session_id);
        const n = @min(name.len, desk.name.len);
        @memcpy(desk.name[0..n], name[0..n]);
        desk.name_len = n;
        self.desktop_count += 1;
        return desk;
    }
};

// ── Win32 Process Registration ──

const MAX_WIN32_PROCESSES: usize = 64;

pub const Win32Process = struct {
    pid: u32 = 0,
    subsystem_type: SubsystemType = .unknown,
    state: ProcessSubsysState = .not_registered,
    console_id: u32 = 0,
    window_station_id: u32 = 0,
    desktop_id: u32 = 0,
    parent_pid: u32 = 0,
    image_name: [64]u8 = [_]u8{0} ** 64,
    image_name_len: usize = 0,
    creation_flags: u32 = 0,
    exit_code: u32 = 0,
    is_console_app: bool = true,

    pub fn getName(self: *const Win32Process) []const u8 {
        return self.image_name[0..self.image_name_len];
    }
};

// ── Global State ──

var window_stations: [MAX_WINDOW_STATIONS]WindowStation = [_]WindowStation{.{}} ** MAX_WINDOW_STATIONS;
var station_count: usize = 0;

/// 交互会话默认 `WinSta0`；见 `docs/cn/DesktopManagerSpec.md`
var active_window_station_idx: usize = 0;
var active_desktop_idx: usize = 0;

var win32_processes: [MAX_WIN32_PROCESSES]Win32Process = [_]Win32Process{.{}} ** MAX_WIN32_PROCESSES;
var win32_process_count: usize = 0;

var subsystem_state: SessionState = .inactive;
var csrss_port_id: u32 = 0;
var csrss_initialized: bool = false;
var api_call_count: u64 = 0;

// ── Subsystem Management ──

pub fn registerProcess(pid: u32, subsystem: SubsystemType, image_name: []const u8, parent_pid: u32) ?*Win32Process {
    if (win32_process_count >= MAX_WIN32_PROCESSES) return null;

    var wp = &win32_processes[win32_process_count];
    wp.* = .{};
    wp.pid = pid;
    wp.subsystem_type = subsystem;
    wp.state = .registered;
    wp.parent_pid = parent_pid;
    wp.is_console_app = (subsystem == .win32_cui or subsystem == .native);

    const n = @min(image_name.len, wp.image_name.len);
    @memcpy(wp.image_name[0..n], image_name[0..n]);
    wp.image_name_len = n;

    win32_process_count += 1;
    api_call_count += 1;

    klog.debug("csrss: Registered Win32 process PID=%u '%s' (subsystem=%u)", .{
        pid, image_name, @intFromEnum(subsystem),
    });

    return wp;
}

pub fn connectProcess(pid: u32) bool {
    const wp = findWin32Process(pid) orelse return false;
    wp.state = .connected;

    if (wp.is_console_app and wp.console_id == 0) {
        if (console_mod.createConsole(pid, wp.getName())) |con| {
            wp.console_id = con.id;
        }
    }

    return true;
}

pub fn terminateWin32Process(pid: u32, exit_code: u32) bool {
    const wp = findWin32Process(pid) orelse return false;
    wp.state = .terminated;
    wp.exit_code = exit_code;
    return true;
}

pub fn findWin32Process(pid: u32) ?*Win32Process {
    for (win32_processes[0..win32_process_count]) |*wp| {
        if (wp.pid == pid and wp.state != .terminated) return wp;
    }
    return null;
}

// ── Window Station Management ──

pub fn createWindowStation(name: []const u8, session_id: u32) ?*WindowStation {
    if (station_count >= MAX_WINDOW_STATIONS) return null;

    var ws = &window_stations[station_count];
    ws.* = .{};
    ws.is_active = true;
    ws.session_id = session_id;
    const n = @min(name.len, ws.name.len);
    @memcpy(ws.name[0..n], name[0..n]);
    ws.name_len = n;

    station_count += 1;
    return ws;
}

pub fn getWindowStation(idx: usize) ?*WindowStation {
    if (idx < station_count) return &window_stations[idx];
    return null;
}

pub fn getActiveDesktopIndex() usize {
    return active_desktop_idx;
}

/// 将活动桌面切换为指定名称（如 `Default`、`Winlogon`）；公开 Win32 桌面切换行为的子集实现。
pub fn switchToDesktop(name: []const u8) bool {
    const ws = getWindowStation(active_window_station_idx) orelse return false;
    for (0..ws.desktop_count) |i| {
        const d = &ws.desktops[i];
        if (d.name_len == name.len and std.mem.eql(u8, d.name[0..d.name_len], name)) {
            for (0..ws.desktop_count) |j| {
                ws.desktops[j].is_active = (j == i);
            }
            active_desktop_idx = i;
            klog.info("csrss: SwitchDesktop (len=%u idx=%u)", .{ @as(u32, @intCast(name.len)), @as(u32, @intCast(i)) });
            return true;
        }
    }
    return false;
}

/// 绑定 Win32 进程到窗口站内的桌面索引（0..desktop_count-1）。
pub fn setProcessDesktop(pid: u32, desktop_index: u32) bool {
    const wp = findWin32Process(pid) orelse return false;
    const ws = getWindowStation(active_window_station_idx) orelse return false;
    if (desktop_index >= ws.desktop_count) return false;
    wp.desktop_id = desktop_index;
    return true;
}

// ── API Dispatch ──

/// LPC `register_window`：前 8 字节小端 `HWND`（`u64`）。
/// `post_message`：偏移 0 `HWND`，8 `msg:u32`，12 填充，16 `wparam:u64`，24 `lparam:i64`（小端）。
/// `get_message`：0–8 `HWND`，8–12 min，12–16 max，16–20 `PM_*`；20–24 线程 id（`0` 则用 `pid`）；应答见 `user32.csrFillOneMessageForLpc`。
/// **步骤总表（问题五）**：与 [DesktopManagerSpec.md](../../docs/cn/DesktopManagerSpec.md) §3.4 同步；LPC **不**替代 `CreateWindowEx` 建 HWND。
pub fn handleApiCall(api: CsrApiNumber, pid: u32, data_opt: ?*const [ipc.MSG_DATA_SIZE]u8) i32 {
    api_call_count += 1;

    switch (api) {
        .create_process => {
            _ = registerProcess(pid, .win32_cui, "unknown.exe", 0);
            return 0;
        },
        .terminate_process => {
            _ = terminateWin32Process(pid, 0);
            return 0;
        },
        .alloc_console => {
            const wp = findWin32Process(pid) orelse return -1;
            if (wp.console_id == 0) {
                if (console_mod.createConsole(pid, wp.getName())) |con| {
                    wp.console_id = con.id;
                }
            }
            return 0;
        },
        .free_console => {
            const wp = findWin32Process(pid) orelse return -1;
            wp.console_id = 0;
            return 0;
        },
        .shutdown_system => {
            subsystem_state = .shutdown;
            klog.info("csrss: System shutdown requested by PID=%u", .{pid});
            return 0;
        },
        .create_window_station => {
            _ = createWindowStation("StaUser", 0) orelse return -1;
            return 0;
        },
        .create_desktop => {
            const ws = getWindowStation(active_window_station_idx) orelse return -1;
            var buf: [16]u8 = undefined;
            const suffix = api_call_count % 1000;
            const label = std.fmt.bufPrint(&buf, "Desk{}", .{suffix}) catch return -1;
            _ = ws.createDesktop(label) orelse return -1;
            return 0;
        },
        // DesktopManagerSpec：LPC `register_window` 在用户态创建 HWND 之后调用；`user32.onCsrssRegisterGuiWindow`
        // 为该 HWND 补绑 `dwm_compositor` 重定向表面（与 `CreateWindowEx` 内联分配互为双保险）。
        .register_window => {
            var hwnd: u64 = 0;
            if (data_opt) |d| {
                hwnd = std.mem.readInt(u64, d[0..8], .little);
            }
            return if (registerGuiWindow(pid, hwnd)) 0 else -1;
        },
        .destroy_window => {
            var hwnd: u64 = 0;
            if (data_opt) |d| {
                hwnd = std.mem.readInt(u64, d[0..8], .little);
            }
            if (user32.DestroyWindow(hwnd) == user32.TRUE) {
                _ = unregisterGuiWindow(hwnd);
                return 0;
            }
            return -1;
        },
        .register_dwm_listener => {
            var tid: u32 = 0;
            if (data_opt) |d| {
                if (d.len >= 4) tid = std.mem.readInt(u32, d[0..4], .little);
            }
            if (tid == 0) tid = pid;
            user32.registerDwmNotificationListener(tid);
            return 0;
        },
        .post_message => {
            if (data_opt) |d| {
                if (d.len >= 32) {
                    const hwnd = std.mem.readInt(u64, d[0..8], .little);
                    const msg = std.mem.readInt(u32, d[8..12], .little);
                    const wparam = std.mem.readInt(u64, d[16..24], .little);
                    const lparam = std.mem.readInt(i64, d[24..32], .little);
                    _ = user32.PostMessageA(hwnd, msg, wparam, lparam);
                    return 0;
                }
            }
            return -1;
        },
        .get_message => {
            const d = data_opt orelse return -1;
            const hwnd = std.mem.readInt(u64, d[0..8], .little);
            const min_v = std.mem.readInt(u32, d[8..12], .little);
            const max_v = std.mem.readInt(u32, d[12..16], .little);
            const remove = std.mem.readInt(u32, d[16..20], .little);
            const tid_in = std.mem.readInt(u32, d[20..24], .little);
            const client_tid: u32 = if (tid_in != 0) tid_in else pid;
            return user32.csrFillOneMessageForLpc(client_tid, hwnd, min_v, max_v, remove);
        },
        else => return -1,
    }
}

pub fn handleMessage() void {
    if (!csrss_initialized) return;
    // poll LPC port for csrss requests
}

// ── GUI Subsystem Support (Phase 10) ──

var gui_subsystem_active: bool = false;
var gui_window_count: u32 = 0;
var gui_message_count: u64 = 0;

pub fn initGuiSubsystem() void {
    gui_subsystem_active = true;
    klog.info("csrss: GUI subsystem activated", .{});
    user32.registerDwmNotificationListener(3);
    user32.broadcastDwmCompositionChanged(user32.TRUE);
    user32.broadcastDwmColorizationChanged(0xFF_70_90_D0, user32.TRUE);
    user32.broadcastDwmNcRenderingChanged(user32.TRUE);
}

pub fn registerGuiWindow(pid: u32, hwnd: u64) bool {
    const wp = findWin32Process(pid) orelse return false;
    _ = wp;
    user32.onCsrssRegisterGuiWindow(pid, hwnd);
    gui_window_count += 1;
    return true;
}

pub fn unregisterGuiWindow(_: u64) bool {
    if (gui_window_count > 0) gui_window_count -= 1;
    api_call_count += 1;
    return true;
}

pub fn dispatchGuiMessage(hwnd: u64, msg: u32, wparam: u64, lparam: i64) i64 {
    gui_message_count += 1;
    api_call_count += 1;
    _ = user32.PostMessageA(hwnd, msg, wparam, lparam);
    return 0;
}

pub fn getGuiWindowCount() u32 {
    return gui_window_count;
}

pub fn getGuiMessageCount() u64 {
    return gui_message_count;
}

pub fn isGuiActive() bool {
    return gui_subsystem_active;
}

// ── Statistics ──

pub fn getWin32ProcessCount() usize {
    var count: usize = 0;
    for (win32_processes[0..win32_process_count]) |*wp| {
        if (wp.state != .terminated) count += 1;
    }
    return count;
}

pub fn getActiveConsoleCount() u32 {
    return console_mod.getConsoleCount();
}

pub fn getApiCallCount() u64 {
    return api_call_count;
}

pub fn getStationCount() usize {
    return station_count;
}

pub fn getState() SessionState {
    return subsystem_state;
}

pub fn getTotalDesktopCount() usize {
    var count: usize = 0;
    for (window_stations[0..station_count]) |*ws| {
        count += ws.desktop_count;
    }
    return count;
}

// ── Initialization ──

fn lpcCsrInlineHandler(client_pid: u32, opcode: u32, data: ?*const [ipc.MSG_DATA_SIZE]u8) i32 {
    const api = std.meta.intToEnum(CsrApiNumber, opcode) catch return -1;
    return handleApiCall(api, client_pid, data);
}

pub fn init() void {
    subsystem_state = .initializing;

    const p = port.createPort(1, "\\LPC\\CsrApiPort");
    if (p) |created| {
        csrss_port_id = created.id;
    }

    const ws = createWindowStation("WinSta0", 0);
    if (ws) |station| {
        _ = station.createDesktop("Default");
        _ = station.createDesktop("Winlogon");
        active_window_station_idx = 0;
        active_desktop_idx = 0;
        station.desktops[0].is_active = true;
        if (station.desktop_count > 1) {
            station.desktops[1].is_active = false;
        }
    }

    _ = registerProcess(1, .native, "System", 0);
    _ = registerProcess(2, .native, "smss.exe", 1);
    _ = registerProcess(3, .win32_cui, "csrss.exe", 2);
    _ = connectProcess(3);

    subsystem_state = .active;
    csrss_initialized = true;

    klog.info("csrss: Win32 Subsystem Server initialized (Phase 9-10)", .{});
    klog.info("csrss: LPC port '\\LPC\\CsrApiPort' created", .{});
    klog.info("csrss: Window station '%s' with %u desktops", .{
        "WinSta0", if (ws) |s| s.desktop_count else 0,
    });
    klog.info("csrss: %u Win32 processes registered", .{getWin32ProcessCount()});
    klog.info("csrss: GUI message dispatch ready", .{});

    port.setCsrRequestHandler(lpcCsrInlineHandler);
}
