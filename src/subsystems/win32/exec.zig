//! Win32 Application Execution Engine
//! Phase 9: Orchestrates PE loading, process creation, DLL binding,
//! import resolution, and application lifecycle for Win32 console apps.

const klog = @import("../../rtl/klog.zig");
const pe_loader = @import("../../loader/pe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const console_mod = @import("console.zig");
const subsystem = @import("subsystem.zig");
const process = @import("../../ps/process.zig");
const vfs = @import("../../fs/vfs.zig");
const fat32 = @import("../../fs/fat32.zig");

const MAX_RUNNING_APPS: usize = 16;

pub const AppState = enum(u8) {
    none = 0,
    loading = 1,
    initializing = 2,
    running = 3,
    suspended = 4,
    terminating = 5,
    terminated = 6,
};

pub const AppType = enum(u8) {
    unknown = 0,
    native_exe = 1,
    win32_cui = 2,
    win32_gui = 3,
    dll = 4,
    batch = 5,
};

pub const Win32App = struct {
    state: AppState = .none,
    app_type: AppType = .unknown,
    pid: u32 = 0,
    parent_pid: u32 = 0,
    exit_code: u32 = 0,
    image: ?*pe_loader.LoadedImage = null,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    command_line: [256]u8 = [_]u8{0} ** 256,
    command_line_len: usize = 0,
    current_dir: [260]u8 = [_]u8{0} ** 260,
    current_dir_len: usize = 0,
    console_id: u32 = 0,
    start_tick: u64 = 0,
    dll_count: usize = 0,
    loaded_dlls: [8][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** 8,
    loaded_dll_lens: [8]usize = [_]usize{0} ** 8,
    creation_flags: u32 = 0,

    pub fn getName(self: *const Win32App) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getCommandLine(self: *const Win32App) []const u8 {
        return self.command_line[0..self.command_line_len];
    }
};

pub const ExecResult = struct {
    status: ExecStatus = .success,
    app: ?*Win32App = null,
    pid: u32 = 0,
    exit_code: u32 = 0,
};

pub const ExecStatus = enum {
    success,
    file_not_found,
    invalid_image,
    out_of_memory,
    dll_not_found,
    init_failed,
    subsystem_error,
    too_many_apps,
};

var running_apps: [MAX_RUNNING_APPS]Win32App = [_]Win32App{.{}} ** MAX_RUNNING_APPS;
var app_count: usize = 0;
var next_app_pid: u32 = 100;
var total_launched: u64 = 0;
var exec_initialized: bool = false;

pub fn createApp(name: []const u8, cmd_line: []const u8, parent_pid: u32) ExecResult {
    if (app_count >= MAX_RUNNING_APPS) return .{ .status = .too_many_apps };

    var app = &running_apps[app_count];
    app.* = .{};
    app.state = .loading;
    app.pid = next_app_pid;
    app.parent_pid = parent_pid;
    next_app_pid += 1;

    const n = @min(name.len, app.name.len);
    @memcpy(app.name[0..n], name[0..n]);
    app.name_len = n;

    const c = @min(cmd_line.len, app.command_line.len);
    @memcpy(app.command_line[0..c], cmd_line[0..c]);
    app.command_line_len = c;

    const dir = "C:\\";
    @memcpy(app.current_dir[0..dir.len], dir);
    app.current_dir_len = dir.len;

    app.app_type = detectAppType(name);

    const image = pe_loader.createProcessImage(name, 0x140000000 + @as(u64, app.pid) * 0x10000, 0x140001000, app.pid);
    if (image) |img| {
        app.image = img;
        img.subsystem = if (app.app_type == .win32_gui) pe_loader.IMAGE_SUBSYSTEM_WINDOWS_GUI else pe_loader.IMAGE_SUBSYSTEM_WINDOWS_CUI;
    } else {
        app.state = .terminated;
        return .{ .status = .out_of_memory };
    }

    app.state = .initializing;

    bindSystemDlls(app);

    const subsys_type: subsystem.SubsystemType = switch (app.app_type) {
        .win32_cui => .win32_cui,
        .win32_gui => .win32_gui,
        .native_exe => .native,
        else => .win32_cui,
    };
    _ = subsystem.registerProcess(app.pid, subsys_type, name, parent_pid);
    _ = subsystem.connectProcess(app.pid);

    if (app.app_type == .win32_cui) {
        if (console_mod.createConsole(app.pid, name)) |con| {
            app.console_id = con.id;
        }
    }

    app.state = .running;
    app_count += 1;
    total_launched += 1;

    klog.info("exec: Launched '%s' (PID=%u, type=%u, DLLs=%u)", .{
        name, app.pid, @intFromEnum(app.app_type), app.dll_count,
    });

    return .{
        .status = .success,
        .app = app,
        .pid = app.pid,
    };
}

fn detectAppType(name: []const u8) AppType {
    if (name.len < 4) return .win32_cui;

    var ext_start: usize = name.len;
    var i: usize = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            ext_start = i;
            break;
        }
    }

    if (ext_start >= name.len) return .win32_cui;
    const ext = name[ext_start..];

    if (strEqlI(ext, ".exe")) return .win32_cui;
    if (strEqlI(ext, ".dll")) return .dll;
    if (strEqlI(ext, ".bat") or strEqlI(ext, ".cmd")) return .batch;
    if (strEqlI(ext, ".com")) return .win32_cui;
    if (strEqlI(ext, ".sys")) return .native_exe;

    return .win32_cui;
}

fn bindSystemDlls(app: *Win32App) void {
    const required_dlls = [_][]const u8{
        "ntdll.dll",
        "kernel32.dll",
        "kernelbase.dll",
    };

    for (required_dlls) |dll_name| {
        if (app.dll_count >= app.loaded_dlls.len) break;

        if (pe_loader.getLoadedImage(dll_name)) |_| {
            const dl = @min(dll_name.len, app.loaded_dlls[app.dll_count].len);
            @memcpy(app.loaded_dlls[app.dll_count][0..dl], dll_name[0..dl]);
            app.loaded_dll_lens[app.dll_count] = dl;
            app.dll_count += 1;
        }
    }
}

pub fn terminateApp(pid: u32, exit_code: u32) bool {
    for (running_apps[0..app_count]) |*app| {
        if (app.pid == pid and app.state == .running) {
            app.state = .terminating;
            app.exit_code = exit_code;

            _ = subsystem.terminateWin32Process(pid, exit_code);

            app.state = .terminated;

            klog.debug("exec: Terminated '%s' (PID=%u, exit=%u)", .{
                app.getName(), pid, exit_code,
            });
            return true;
        }
    }
    return false;
}

pub fn findApp(pid: u32) ?*Win32App {
    for (running_apps[0..app_count]) |*app| {
        if (app.pid == pid and app.state != .terminated) return app;
    }
    return null;
}

pub fn getRunningCount() usize {
    var count: usize = 0;
    for (running_apps[0..app_count]) |*app| {
        if (app.state == .running) count += 1;
    }
    return count;
}

pub fn getTotalLaunched() u64 {
    return total_launched;
}

pub fn getAppCount() usize {
    return app_count;
}

pub fn runDemoApps() void {
    klog.info("exec: --- Win32 Application Demo ---", .{});

    const demo_result = createApp("notepad.exe", "notepad.exe", 4);
    if (demo_result.app) |app| {
        if (console_mod.getConsole(app.console_id)) |con| {
            con.writeLine("");
            con.writeLine("[notepad.exe] Win32 Console Application");
            con.writeLine("[notepad.exe] Loaded DLLs: ntdll.dll, kernel32.dll, kernelbase.dll");
            con.writeLine("[notepad.exe] PEB/TEB initialized, subsystem connected");
            con.writeLine("[notepad.exe] Application ready.");
            con.writeLine("");
        }
        _ = terminateApp(app.pid, 0);
    }

    const calc_result = createApp("calc.exe", "calc.exe", 4);
    if (calc_result.app) |app| {
        if (console_mod.getConsole(app.console_id)) |con| {
            con.writeLine("[calc.exe] Win32 Calculator Application");
            con.writeLine("[calc.exe] Subsystem: CUI (Console mode)");
            con.writeLine("[calc.exe] Application started and terminated.");
            con.writeLine("");
        }
        _ = terminateApp(app.pid, 0);
    }

    const ipconfig_result = createApp("ipconfig.exe", "ipconfig.exe /all", 4);
    if (ipconfig_result.app) |app| {
        if (console_mod.getConsole(app.console_id)) |con| {
            con.writeLine("[ipconfig.exe] ZirconOS IP Configuration");
            con.writeLine("");
            con.writeLine("   Host Name . . . . . . . . : ZIRCONOS");
            con.writeLine("   Primary Dns Suffix  . . . :");
            con.writeLine("   Node Type . . . . . . . . : Hybrid");
            con.writeLine("   IP Routing Enabled. . . . : No");
            con.writeLine("   WINS Proxy Enabled. . . . : No");
            con.writeLine("");
        }
        _ = terminateApp(app.pid, 0);
    }

    klog.info("exec: Demo: %u apps launched, %u running", .{
        getTotalLaunched(), getRunningCount(),
    });
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

pub fn init() void {
    app_count = 0;
    next_app_pid = 100;
    total_launched = 0;
    exec_initialized = true;

    klog.info("exec: Win32 Application Execution Engine initialized", .{});
    klog.info("exec: PE loading, DLL binding, PEB/TEB creation ready", .{});
    klog.info("exec: Supported types: .exe, .dll, .bat, .cmd, .com, .sys", .{});
}
