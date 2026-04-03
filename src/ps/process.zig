//! Process & Thread Model (NT style)
//! Integrates with Object Manager, Handle Table, and Security Token

const std = @import("std");
const builtin = @import("builtin");
const vm = @import("../mm/vm.zig");

comptime {
    // `AddressSpace` 含大 VAD 表；须明显小于常见内核栈（如 64KiB）以免 `createProcess` 栈帧过深。
    std.debug.assert(@sizeOf(vm.AddressSpace) < 48 * 1024);
}
const kuser_shared = @import("../mm/kuser_shared.zig");
const FrameAllocator = @import("../mm/frame.zig").FrameAllocator;
const klog = @import("../rtl/klog.zig");
const ob = @import("../ob/object.zig");
const token = @import("../se/token.zig");

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
    /// 指向 `g_proc_address_spaces` 中槽位；勿在栈上内联整块 `AddressSpace`（易耗尽 64KiB 内核栈）。
    address_space: ?*vm.AddressSpace = null,
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
/// 每进程地址空间驻留 BSS 槽位，`createProcess` 仅取指针，避免栈上构造 `AddressSpace`。
var g_proc_address_spaces: [MAX_PROCESSES]vm.AddressSpace = undefined;
var g_proc_address_space_busy: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;

var process_count: usize = 0;
var next_pid: u32 = 1;
var next_tid: u32 = 1;
var current_pid: u32 = 0;
var ps_initialized: bool = false;

/// 桌面会话（等价于 csrss/dwm 宿主）：内核桌面循环所在「壳」进程与 UI 线程号。
var desktop_shell_pid: u32 = 0;
var desktop_ui_tid: u32 = 0;

/// K2.1：在释放进程 `AddressSpace` / CR3 之前调用，将仍关联该 `pid` 的调度线程标为终止并切回内核 CR3（若当前在受害线程上）。
/// 由 `ke/scheduler.zig` 在 `init()` 中注册，避免 `process` ↔ `scheduler` 循环依赖。
pub var before_release_process_address_space: ?*const fn (u32) void = null;

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

fn allocProcessAddressSpaceSlot() ?*vm.AddressSpace {
    for (&g_proc_address_spaces, 0..) |*slot, i| {
        if (!g_proc_address_space_busy[i]) {
            g_proc_address_space_busy[i] = true;
            return slot;
        }
    }
    return null;
}

fn freeProcessAddressSpaceSlot(slot: *vm.AddressSpace) void {
    for (&g_proc_address_spaces, 0..) |*s, i| {
        if (@intFromPtr(s) == @intFromPtr(slot)) {
            g_proc_address_space_busy[i] = false;
            return;
        }
    }
}

pub fn init() void {
    process_count = 0;
    next_pid = 1;
    next_tid = 1;
    current_pid = 0;
    @memset(&g_proc_address_space_busy, false);
    for (&processes) |*p| {
        p.* = Process.init(0);
    }
    ps_initialized = true;
}

pub fn allocPid() ?u32 {
    if (next_pid == 0) return null;
    if (next_pid == std.math.maxInt(u32)) return null;
    const pid = next_pid;
    next_pid += 1;
    return pid;
}

pub fn allocTid() ?u32 {
    if (next_tid == std.math.maxInt(u32)) return null;
    const tid = next_tid;
    next_tid += 1;
    return tid;
}

pub fn createProcess(frame_alloc: *FrameAllocator) ?*Process {
    const panic_ctx = @import("../rtl/panic_context.zig");
    if (process_count >= MAX_PROCESSES) return null;
    const pid = allocPid() orelse return null;

    panic_ctx.setPhase(0x0005_0010);
    const space_ptr = allocProcessAddressSpaceSlot() orelse return null;
    if (!vm.initAddressSpaceInPlace(space_ptr, frame_alloc)) {
        freeProcessAddressSpaceSlot(space_ptr);
        return null;
    }
    panic_ctx.setPhase(0x0005_0011);
    if (builtin.cpu.arch == .x86_64) {
        panic_ctx.setPhase(0x0005_0012);
        if (!kuser_shared.installInProcessAddressSpace(space_ptr)) {
            vm.releaseProcessAddressSpace(space_ptr);
            freeProcessAddressSpaceSlot(space_ptr);
            panic_ctx.setPhase(0);
            return null;
        }
    }
    panic_ctx.setPhase(0x0005_0013);

    var p = &processes[process_count];
    p.* = Process.init(pid);
    p.address_space = space_ptr;
    p.state = .active;
    panic_ctx.setPhase(0x0005_0015);
    p.security_token = token.createSystemToken();
    panic_ctx.setPhase(0x0005_0016);
    p.handle_table = ob.HandleTable.init(pid);
    panic_ctx.setPhase(0x0005_0017);
    process_count += 1;

    panic_ctx.setPhase(0x0005_0014);
    ob.createObject(.process, @intFromPtr(&p.header));
    // 勿在此处 setPhase(0)：`createSystemProcess` 尚有 memcpy/klog；清零会掩盖后续 panic 的 phase。
    panic_ctx.setPhase(0x0005_0018);
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
    // K2.1：须先终止/切离仍关联该 EPROCESS 的线程，避免 `releaseProcessAddressSpace` 时其他核仍 CR3=受害进程。
    if (before_release_process_address_space) |hook| {
        hook(pid);
    }
    if (p.address_space) |asp| {
        // `releaseProcessAddressSpace` 清空 VAD / 用户半区页表；须先经 `before_release_process_address_space` 使无线程再以该 CR3 运行（K2.1）。
        vm.releaseProcessAddressSpace(asp);
        freeProcessAddressSpaceSlot(asp);
        p.address_space = null;
    }
    p.handle_table.closeAllOpenHandles();
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
