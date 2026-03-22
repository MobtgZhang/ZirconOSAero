//! Process & Thread Model (NT style)
//! Integrates with Object Manager, Handle Table, and Security Token

const vm = @import("../mm/vm.zig");
const FrameAllocator = @import("../mm/frame.zig").FrameAllocator;
const ob = @import("../ob/object.zig");
const token = @import("../se/token.zig");
const klog = @import("../rtl/klog.zig");

pub const MAX_PROCESSES: usize = 32;
pub const MAX_THREADS_PER_PROCESS: usize = 8;

pub const ProcessState = enum {
    creating,
    active,
    suspended,
    terminated,
};

pub const Process = struct {
    header: ob.ObjectHeader = .{ .obj_type = .process },
    pid: u32 = 0,
    parent_pid: u32 = 0,
    state: ProcessState = .creating,
    address_space: ?vm.AddressSpace = null,
    handle_table: ob.HandleTable = .{},
    security_token: token.Token = .{},
    thread_count: usize = 0,
    is_system: bool = false,
    exit_code: u32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,

    pub fn init(pid: u32) Process {
        return .{
            .header = .{ .obj_type = .process },
            .pid = pid,
            .state = .creating,
            .handle_table = ob.HandleTable.init(pid),
        };
    }
};

pub const ThreadState = enum {
    ready,
    running,
    blocked,
    terminated,
};

pub const ThreadContext = struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rip: u64 = 0,
    rsp: u64 = 0,
    rflags: u64 = 0x202,
};

pub const Thread = struct {
    header: ob.ObjectHeader = .{ .obj_type = .thread },
    tid: u32 = 0,
    process_id: u32 = 0,
    state: ThreadState = .ready,
    context: ThreadContext = .{},
    kernel_stack_top: u64 = 0,
    user_stack_top: u64 = 0,
    priority: u8 = 0,
};

var processes: [MAX_PROCESSES]Process = undefined;
var process_count: usize = 0;
var next_pid: u32 = 1;
var next_tid: u32 = 1;
var current_pid: u32 = 0;
var ps_initialized: bool = false;

/// 桌面会话（等价于 csrss/dwm 宿主）：内核桌面循环所在「壳」进程与 UI 线程号。
var desktop_shell_pid: u32 = 0;
var desktop_ui_tid: u32 = 0;

pub fn registerDesktopSession(shell_pid: u32, ui_tid: u32) void {
    desktop_shell_pid = shell_pid;
    desktop_ui_tid = ui_tid;
}

pub fn getDesktopShellPid() u32 {
    return desktop_shell_pid;
}

pub fn getDesktopUiThreadId() u32 {
    return desktop_ui_tid;
}

pub fn init() void {
    process_count = 0;
    next_pid = 1;
    next_tid = 1;
    current_pid = 0;
    for (&processes) |*p| {
        p.* = Process.init(0);
    }
    ps_initialized = true;
}

pub fn allocPid() ?u32 {
    if (next_pid == 0) return null;
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

pub fn allocTid() ?u32 {
    const tid = next_tid;
    next_tid += 1;
    return tid;
}

pub fn createProcess(frame_alloc: *FrameAllocator) ?*Process {
    if (process_count >= MAX_PROCESSES) return null;
    const pid = allocPid() orelse return null;

    const space = vm.createAddressSpace(frame_alloc) orelse return null;

    var p = &processes[process_count];
    p.* = Process.init(pid);
    p.address_space = space;
    p.state = .active;
    p.security_token = token.createSystemToken();
    p.handle_table = ob.HandleTable.init(pid);
    process_count += 1;

    ob.createObject(.process, @intFromPtr(&p.header));

    return p;
}

pub fn createSystemProcess(frame_alloc: *FrameAllocator, name: []const u8) ?*Process {
    const p = createProcess(frame_alloc) orelse return null;
    p.is_system = true;
    const copy_len = @min(name.len, p.name.len);
    @memcpy(p.name[0..copy_len], name[0..copy_len]);
    p.name_len = copy_len;

    klog.info("Process: '%s' created (PID=%u, system=true)", .{ name, p.pid });
    return p;
}

pub fn terminateProcess(pid: u32, exit_code: u32) bool {
    const p = findProcess(pid) orelse return false;
    p.state = .terminated;
    p.exit_code = exit_code;
    klog.debug("Process: PID=%u terminated (exit_code=%u)", .{ pid, exit_code });
    return true;
}

pub fn findProcess(pid: u32) ?*Process {
    for (processes[0..process_count]) |*p| {
        if (p.pid == pid) return p;
    }
    return null;
}

pub fn setCurrentProcess(pid: u32) void {
    current_pid = pid;
}

pub fn getCurrentPid() u32 {
    return current_pid;
}

pub fn getCurrentProcess() ?*Process {
    return findProcess(current_pid);
}

pub fn getProcessCount() usize {
    return process_count;
}

pub fn getProcessList() []Process {
    return processes[0..process_count];
}
