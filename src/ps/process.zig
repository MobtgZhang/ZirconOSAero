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
    /// 前台量子加成（`scheduler.quantumTicksForThread`）；桌面会话可置位。
    is_foreground: bool = false,
    /// QT-03: 进程优先级类（0-7），影响线程的默认时间片长度。
    /// 由 `NtSetInformationProcess` 的 `ProcessPriorityClass` 设置。
    /// 默认为 2（NORMAL_PRIORITY_CLASS）。
    priority_class: u8 = 2,
    /// NT 6.1 里程碑：主模块首选基址（PE `OptionalHeader.ImageBase`）；未加载 PE 时为 0。
    image_base_address: u64 = 0,
    /// NT 6.1 里程碑：进程环境块用户 VA；由加载器/Nt 路径填写，供 syscall 与用户异常对齐。
    peb_address: u64 = 0,
    /// WOW64：32 位子系统进程；影响注册表/路径重定向与 `ProcessWow64Information`。
    is_wow64: bool = false,
    /// 32 位 PEB 用户 VA（`NtQueryInformationProcess` / 调试器子集）。
    peb32_user_va: u64 = 0,
    /// 初始线程 TEB32 用户 VA（演示；多线程后为首个线程）。
    teb32_user_va: u64 = 0,

    pub fn init(pid: u32) Process {
        return .{
            .header = .{ .obj_type = .process },
            .pid = pid,
            .state = .creating,
            .handle_table = ob.HandleTable.init(pid),
        };
    }

    /// FG-01: 设置前台状态，窗口激活时调用以获得额外时间片加成。
    pub fn setForeground(self: *Process, foreground: bool) void {
        self.is_foreground = foreground;
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
    /// NT 6.1 里程碑：用户线程入口 VA（与 `CONTEXT.Rip` 启动值对齐）；纯内核线程为 0。
    user_start_address: u64 = 0,
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

/// `attachWow64IfPresent` 之后由调度器同步 `Thread.is_wow64`（避免 `process` 直接依赖 `scheduler` 形成环依赖）。
pub var after_attach_wow64: ?*const fn (u32) void = null;

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
    if (next_pid != 0 and next_pid != std.math.maxInt(u32)) {
        const pid = next_pid;
        next_pid +%= 1;
        return pid;
    }
    // next_pid 达到上限，遍历整个数组回收已终止进程的 PID
    for (&processes) |*p| {
        if (p.state == .terminated) {
            const recycled_pid = p.pid;
            p.pid = 0; // 标记为未分配
            p.state = .creating;
            // 回收成功后，尝试重置 next_pid（从 1 开始找最小的可用值）
            if (next_pid == std.math.maxInt(u32)) {
                next_pid = 1;
            }
            return recycled_pid;
        }
    }
    return null;
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
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .loongarch64 or builtin.cpu.arch == .mips64el) {
        if (!vm.linkKernelHalfMappings(space_ptr)) {
            vm.releaseProcessAddressSpace(space_ptr);
            freeProcessAddressSpaceSlot(space_ptr);
            panic_ctx.setPhase(0);
            return null;
        }
        panic_ctx.setPhase(0x0005_0012);
        if (builtin.cpu.arch == .x86_64) {
            if (!kuser_shared.installInProcessAddressSpace(space_ptr)) {
                vm.releaseProcessAddressSpace(space_ptr);
                freeProcessAddressSpaceSlot(space_ptr);
                panic_ctx.setPhase(0);
                return null;
            }
        }
    }
    // LoongArch64：为用户地址空间分配 ASID
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding) {
        const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
        const asid = tlb_la.allocateProcessAsid();
        if (asid == 0) {
            vm.releaseProcessAddressSpace(space_ptr);
            freeProcessAddressSpaceSlot(space_ptr);
            panic_ctx.setPhase(0);
            return null;
        }
        space_ptr.asid = asid;
        space_ptr.last_asid_version = tlb_la.getAsidVersion();
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

/// 从 PE 数据创建进程并加载映像
/// 返回创建的进程及其主线程
pub fn createProcessFromPe(
    frame_alloc: *FrameAllocator,
    pe_data: []const u8,
    image_base: u64,
    entry_point: u64,
) ?struct { proc: *Process, tid: u32 } {
    _ = entry_point; // TODO: 用于设置线程入口点
    // 1. 创建进程
    const proc = createProcess(frame_alloc) orelse return null;
    proc.image_base_address = image_base;

    // 2. 验证 PE 格式
    const pe = @import("../loader/pe.zig");
    if (pe.validatePeHeader(pe_data) != .success) {
        klog.err("Process: invalid PE format for process PID=%u", .{proc.pid});
        return null;
    }

    // 3. 映射 PE 节到进程地址空间
    const asp = proc.address_space orelse return null;
    if (!mapPeSectionsToAddressSpace(asp, pe_data, image_base)) {
        klog.err("Process: failed to map PE sections for PID=%u", .{proc.pid});
        return null;
    }

    // 4. 设置 PEB
    proc.peb_address = image_base + 0x1000; // 简化：PEB 在固定偏移
    klog.info("Process: PE loaded at 0x{x} for PID=%u", .{ image_base, proc.pid });

    // 5. TODO: 创建初始线程
    // 完整实现需要创建线程并设置 context
    return .{ .proc = proc, .tid = 0 };
}

/// 将 PE 节映射到进程的地址空间
fn mapPeSectionsToAddressSpace(asp: *vm.AddressSpace, pe_data: []const u8, image_base: u64) bool {
    _ = asp; // TODO: 使用 asp 将节数据映射到地址空间
    const pe = @import("../loader/pe.zig");

    // 读取节头
    const dos = @as(*const pe.DosHeader, @ptrFromInt(@intFromPtr(pe_data.ptr)));
    const pe_offset = dos.e_lfanew;
    const fh = @as(*const pe.FileHeader, @ptrFromInt(pe_data.ptr + pe_offset + 4));

    const num_sections = fh.number_of_sections;
    const opt_size = fh.size_of_optional_header;
    const sections_ptr = pe_data.ptr + pe_offset + 4 + @sizeOf(pe.FileHeader) + opt_size;

    // 遍历每个节并映射
    var i: u16 = 0;
    while (i < num_sections) : (i += 1) {
        const sh = @as(*const pe.SectionHeader, @ptrFromInt(sections_ptr + @as(usize, i) * @sizeOf(pe.SectionHeader)));

        if (sh.size_of_raw_data == 0) continue;

        const sec_va = image_base + @as(u64, sh.virtual_address);
        const sec_size = @as(u64, sh.virtual_size);

        // TODO: 使用 vm.mapPage* 将节数据映射到地址空间
        klog.debug("Process: mapping section '%s' to VA=0x{x} size={}", .{
            sh.name[0..8], sec_va, sec_size,
        });
    }

    return true;
}

/// 获取进程的主模块信息
pub fn getProcessMainModule(proc: *const Process) ?struct { base: u64, size: u32 } {
    if (proc.image_base_address == 0) return null;
    return .{ .base = proc.image_base_address, .size = 0 }; // size 待从 PE 获取
}

pub fn terminateProcess(pid: u32, exit_code: u32) bool {
    const p = findProcess(pid) orelse return false;
    // K2.1：须先终止/切离仍关联该 EPROCESS 的线程，避免 `releaseProcessAddressSpace` 时其他核仍 CR3=受害进程。
    if (before_release_process_address_space) |hook| {
        hook(pid);
    }
    const asp = p.address_space;
    if (asp != null) {
        // `releaseProcessAddressSpace` 清空 VAD / 用户半区页表；须先经 `before_release_process_address_space` 使无线程再以该 CR3 运行（K2.1）。
        vm.releaseProcessAddressSpace(asp.?);
        freeProcessAddressSpaceSlot(asp.?);
        p.address_space = null;
    }
    p.handle_table.closeAllOpenHandles();
    p.state = .terminated;
    p.exit_code = exit_code;
    klog.debug("Process: PID=%u terminated (exit_code=%u)", .{ pid, exit_code });
    return true;
}

/// 若存在同 PID 的 `Process` 槽位，标记为 WOW64 并记录 32 位 PEB/TEB 用户 VA（与 `wow64.zig` 演示进程协同）。
pub fn attachWow64IfPresent(pid: u32, peb32_va: u64, teb32_va: u64) void {
    const p = findProcess(pid) orelse return;
    p.is_wow64 = true;
    p.peb32_user_va = peb32_va;
    p.teb32_user_va = teb32_va;
    if (after_attach_wow64) |hook| hook(pid);
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

/// 仅 `Debug`：`createProcess` 子进程后 `duplicateUserMappingsForFork`；失败则终止子进程。
pub fn forkProcessForTest(parent_pid: u32, frame_alloc: *FrameAllocator) ?*Process {
    if (builtin.mode != .Debug) return null;
    const parent = findProcess(parent_pid) orelse return null;
    const parent_asp = parent.address_space orelse return null;
    const child = createProcess(frame_alloc) orelse return null;
    const child_asp = child.address_space orelse return null;
    if (vm.duplicateUserMappingsForFork(child_asp, parent_asp) != 0) {
        _ = terminateProcess(child.pid, 1);
        return null;
    }
    child.parent_pid = parent_pid;
    return child;
}

// ── `NtCreateUserProcess`：内核线程对象句柄（`ObjectType.thread`）与调度器 `tid` 的桥接 ──
// Ref: [docs/cn/PHASE_F_PROCESS_CREATE.md](../../docs/cn/PHASE_F_PROCESS_CREATE.md)（验收子集；非完整 ETHREAD）。

/// 供句柄表引用的最小线程对象；`scheduler_tid` 对应 `ke/scheduler.zig` 线程槽索引。
pub const PsThreadObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .thread },
    scheduler_tid: usize = 0,
    host_pid: u32 = 0,
};

const max_ps_thread_objects: usize = 128;
var g_ps_threads: [max_ps_thread_objects]PsThreadObject = undefined;
var g_ps_thread_busy: [max_ps_thread_objects]bool = [_]bool{false} ** max_ps_thread_objects;

pub fn allocPsThreadObject(scheduler_tid: usize, host_pid: u32) ?*PsThreadObject {
    for (&g_ps_threads, &g_ps_thread_busy) |*obj, *busy| {
        if (!busy.*) {
            busy.* = true;
            obj.* = .{
                .header = .{ .obj_type = .thread },
                .scheduler_tid = scheduler_tid,
                .host_pid = host_pid,
            };
            ob.createObject(.thread, @intFromPtr(&obj.header));
            return obj;
        }
    }
    return null;
}

pub fn releasePsThreadObject(ptr: *PsThreadObject) void {
    _ = ob.dereferenceObject(@intFromPtr(&ptr.header));
    for (&g_ps_threads, &g_ps_thread_busy) |*obj, *busy| {
        if (@intFromPtr(obj) == @intFromPtr(ptr)) {
            busy.* = false;
            obj.* = .{};
            return;
        }
    }
}

/// `CLIENT_ID.UniqueThread` 与 `PsThreadObject.scheduler_tid` 对齐时的查找（`NtOpenThread`）。
pub fn findPsThreadForOpen(host_pid: u32, unique_thread: usize) ?*PsThreadObject {
    var i: usize = 0;
    while (i < max_ps_thread_objects) : (i += 1) {
        if (!g_ps_thread_busy[i]) continue;
        const obj = &g_ps_threads[i];
        if (obj.host_pid != host_pid) continue;
        if (obj.scheduler_tid == unique_thread) return obj;
    }
    return null;
}
