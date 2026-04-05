//! ntdll - Native API Runtime Library
//! Phase 8 Enhanced: Complete Native API set with file/memory/section/sync APIs,
//! system information queries, RTL utilities, and debug support.
//!
//! ## NT 6.1 x86_64 系统调用约定（里程碑）
//! - **独立用户进程 / PE 镜像**：须链接 [`sdk/ntdll_syscall_win64.zig`](../sdk/ntdll_syscall_win64.zig)（`syscall` 指令 + `Ssdt` 索引），**勿**依赖 `int 0x80` 作主路径。
//! - 本文件为 **内核内联** Native API：直接调用子系统实现，不经 `syscall`；服务号与 `ssdt_nt61` 对齐供文档与 WOW64 对照。
//! - 用户态经 `syscall` 进入内核时，入口由 `LSTAR` 指向分派；`STAR`/`SFMASK` 见 Intel SDM 与 `syscall_msr.zig`。
//! - 完整 PE 进程上下文需与 `Process.peb_address` / `image_base_address` 及 `sdk/pe64_nt61.zig` 映射闭环衔接（后续里程碑）。
//! Reference: https://learn.microsoft.com/en-us/cpp/build/overview-of-x64-calling-conventions

const std = @import("std");
const builtin = @import("builtin");
const klog = @import("../rtl/klog.zig");
const process = @import("../ps/process.zig");
const ob = @import("../ob/object.zig");
const ipc = @import("../lpc/ipc.zig");
const port = @import("../lpc/port.zig");
const vfs = @import("../fs/vfs.zig");
const vm = @import("../mm/vm.zig");
const io = @import("../io/io.zig");
const registry = @import("../registry/registry.zig");
const token = @import("../se/token.zig");
const section_mm = @import("../mm/section.zig");
const probe = @import("../mm/probe.zig");
const scheduler = @import("../ke/scheduler.zig");
const wait_mod = @import("../ke/wait.zig");
const wow64_redirect = @import("../subsystems/win32/wow64/redirect.zig");

pub const NTSTATUS = i32;
pub const STATUS_SUCCESS: NTSTATUS = 0;
pub const STATUS_PENDING: NTSTATUS = 259;
pub const STATUS_INVALID_PARAMETER: NTSTATUS = -1073741811;
pub const STATUS_ACCESS_VIOLATION: NTSTATUS = -1073741819;
pub const STATUS_ACCESS_DENIED: NTSTATUS = -1073741790;
pub const STATUS_NO_MEMORY: NTSTATUS = -1073741801;
pub const STATUS_OBJECT_NAME_NOT_FOUND: NTSTATUS = -1073741772;
pub const STATUS_NOT_IMPLEMENTED: NTSTATUS = -1073741822;
pub const STATUS_BUFFER_TOO_SMALL: NTSTATUS = -1073741789;
pub const STATUS_END_OF_FILE: NTSTATUS = -1073741807;
pub const STATUS_INVALID_HANDLE: NTSTATUS = -1073741816;
pub const STATUS_OBJECT_NAME_COLLISION: NTSTATUS = -1073741771;
pub const STATUS_OBJECT_PATH_NOT_FOUND: NTSTATUS = -1073741767;
pub const STATUS_INSUFFICIENT_RESOURCES: NTSTATUS = -1073741823;
pub const STATUS_TIMEOUT: NTSTATUS = 258;
pub const STATUS_WAIT_0: NTSTATUS = 0;
pub const STATUS_ABANDONED_WAIT_0: NTSTATUS = 128;
pub const STATUS_ALERTED: NTSTATUS = 257;
/// `STATUS_USER_APC`（0xC0000012）— 可告警等待见挂起用户 APC。
pub const STATUS_USER_APC: NTSTATUS = @bitCast(@as(u32, 0xC0000012));
pub const STATUS_INFO_LENGTH_MISMATCH: NTSTATUS = -1073741820;
/// 0xC0000003 — invalid `SYSTEM_INFORMATION_CLASS` / info class.
pub const STATUS_INVALID_INFO_CLASS: NTSTATUS = -1073741821;
/// `STATUS_INVALID_DEVICE_REQUEST`（0xC0000010）— IOCTL 路由未命中时返回。
pub const STATUS_INVALID_DEVICE_REQUEST: NTSTATUS = @bitCast(@as(u32, 0xC0000010));
/// `STATUS_NOT_EQUAL` — `RtlVerifyVersionInfo` 版本条件不满足（公开 NTSTATUS）。
pub const STATUS_NOT_EQUAL: NTSTATUS = @bitCast(@as(u32, 0xC0000159));
/// `NtEnumerateKey` / `NtEnumerateValueKey` 末项之后；与公开 NTSTATUS 表一致（warning 位）。
pub const STATUS_NO_MORE_ENTRIES: NTSTATUS = @bitCast(@as(u32, 0x8000001A));

pub const HANDLE = u64;
pub const INVALID_HANDLE_VALUE: HANDLE = 0xFFFFFFFFFFFFFFFF;
pub const NULL_HANDLE: HANDLE = 0;

pub const UNICODE_STRING = struct {
    length: u16 = 0,
    maximum_length: u16 = 0,
    buffer: [260]u8 = [_]u8{0} ** 260,
};

pub const OBJECT_ATTRIBUTES = struct {
    length: u32 = @sizeOf(OBJECT_ATTRIBUTES),
    root_directory: HANDLE = 0,
    object_name: ?*UNICODE_STRING = null,
    attributes: u32 = 0,
    security_descriptor: u64 = 0,
    security_quality_of_service: u64 = 0,
};

pub const IO_STATUS_BLOCK = struct {
    status: NTSTATUS = STATUS_SUCCESS,
    information: u64 = 0,
};

pub const OBJ_INHERIT: u32 = 0x00000002;
pub const OBJ_PERMANENT: u32 = 0x00000010;
pub const OBJ_EXCLUSIVE: u32 = 0x00000020;
pub const OBJ_CASE_INSENSITIVE: u32 = 0x00000040;
pub const OBJ_OPENIF: u32 = 0x00000080;
pub const OBJ_KERNEL_HANDLE: u32 = 0x00000200;

pub const FILE_DIRECTORY_FILE: u32 = 0x00000001;
pub const FILE_NON_DIRECTORY_FILE: u32 = 0x00000040;
pub const FILE_SYNCHRONOUS_IO_NONALERT: u32 = 0x00000020;

pub const FILE_SHARE_READ: u32 = 0x00000001;
pub const FILE_SHARE_WRITE: u32 = 0x00000002;
pub const FILE_SHARE_DELETE: u32 = 0x00000004;

pub const FILE_SUPERSEDE: u32 = 0;
pub const FILE_OPEN: u32 = 1;
pub const FILE_CREATE: u32 = 2;
pub const FILE_OPEN_IF: u32 = 3;
pub const FILE_OVERWRITE: u32 = 4;
pub const FILE_OVERWRITE_IF: u32 = 5;

/// `FILE_INFORMATION_CLASS` 子集 — Ref: learn.microsoft.com `NtQueryDirectoryFile`.
pub const FileNamesInformation: u32 = 12;

/// 目录枚举结束（warning NTSTATUS，公开头文件值）。
pub const STATUS_NO_MORE_FILES: NTSTATUS = @bitCast(@as(u32, 0x80000006));
pub const STATUS_NOT_A_DIRECTORY: NTSTATUS = @bitCast(@as(u32, 0xC0000103));
pub const STATUS_FILE_IS_A_DIRECTORY: NTSTATUS = @bitCast(@as(u32, 0xC00000BA));

pub const SystemBasicInformation: u32 = 0;
pub const SystemProcessorInformation: u32 = 1;
pub const SystemPerformanceInformation: u32 = 2;
pub const SystemTimeOfDayInformation: u32 = 3;
pub const SystemProcessInformation: u32 = 5;
pub const SystemModuleInformation: u32 = 11;
/// 池标签统计（WDK 概念）；本兼容层未实现池遍历。
pub const SystemPoolTagInformation: u32 = 22;
/// `RTL_OSVERSIONINFOEXW` / `VER_PLATFORM_*` — values aligned with public SDK headers (clean-room).
pub const SystemVersionInformation: u32 = 57;
/// WDK `SYSTEM_INFORMATION_CLASS` 子集 — 句柄表枚举为路线图。
pub const SystemHandleInformation: u32 = 16;
/// 中断统计桩（前缀零填充）。
pub const SystemInterruptInformation: u32 = 23;
/// 异常分发计数桩（前缀零填充）。
pub const SystemExceptionInformation: u32 = 33;

pub const ProcessBasicInformation: u32 = 0;
/// Ref: learn.microsoft.com — `PROCESSINFOCLASS` / `ProcessSessionInformation`.
pub const ProcessSessionInformation: u32 = 24;
/// Ref: learn.microsoft.com `PROCESSINFOCLASS` — WOW64 进程返回 32 位 PEB 指针；本机 64 位进程为 0。
pub const ProcessWow64Information: u32 = 26;
/// `ProcessImageFileName` — 缓冲区布局为 `UNICODE_STRING` + UTF-16LE 串（本实现写于用户缓冲）。
pub const ProcessImageFileName: u32 = 27;
/// 较新构建可见；NT 6.1 全语义未声称，返回 `STATUS_NOT_IMPLEMENTED`。
pub const ProcessCommandLineInformation: u32 = 60;
pub const ThreadBasicInformation: u32 = 0;
pub const ThreadTimes: u32 = 1;

/// `THREAD_BASIC_INFORMATION` x64 布局（公开头文件描述；clean-room 字段顺序）。
const THREAD_BASIC_INFORMATION = extern struct {
    exit_status: NTSTATUS,
    _pad0: u32,
    teb_base_address: u64,
    client_id_unique_process: u64,
    client_id_unique_thread: u64,
    affinity_mask: u64,
    priority: i32,
    base_priority: i32,
};
comptime {
    std.debug.assert(@sizeOf(THREAD_BASIC_INFORMATION) == 48);
}

/// 内核静态事件对象池（`NtCreateEvent` / `NtWaitForSingleObject`）；非分页、无堆分配。
const MAX_KERNEL_EVENTS: usize = 32;
var g_event_objs: [MAX_KERNEL_EVENTS]ob.ObjectHeader = undefined;
var g_event_used: [MAX_KERNEL_EVENTS]bool = [_]bool{false} ** MAX_KERNEL_EVENTS;

fn allocEventObject(initial_state: bool, event_type: u32) ?u64 {
    var i: usize = 0;
    while (i < MAX_KERNEL_EVENTS) : (i += 1) {
        if (!g_event_used[i]) {
            g_event_used[i] = true;
            var flags: u32 = 0;
            if (event_type == SYNCHRONIZATION_EVENT) flags |= ob.OBJ_FLAG_EVENT_AUTO_RESET;
            g_event_objs[i] = .{
                .obj_type = .event,
                .ref_count = 0,
                .handle_count = 0,
                .flags = flags,
                .signal_state = initial_state,
            };
            return @intFromPtr(&g_event_objs[i]);
        }
    }
    return null;
}

fn recycleEventObject(object_ptr: u64) void {
    if (object_ptr == 0) return;
    var i: usize = 0;
    while (i < MAX_KERNEL_EVENTS) : (i += 1) {
        if (g_event_used[i] and @intFromPtr(&g_event_objs[i]) == object_ptr) {
            const hdr = &g_event_objs[i];
            if (hdr.refCount() == 0 and hdr.handleCount() == 0) {
                hdr.* = .{};
                g_event_used[i] = false;
            }
            return;
        }
    }
}

/// 内核静态互斥体池（与 `ObjectHeader` + `ke/wait.zig` 同一等待队列）。
const MAX_KERNEL_MUTEXES: usize = 32;
var g_mutex_objs: [MAX_KERNEL_MUTEXES]ob.ObjectHeader = undefined;
var g_mutex_used: [MAX_KERNEL_MUTEXES]bool = [_]bool{false} ** MAX_KERNEL_MUTEXES;

const MAX_KERNEL_SEMAPHORES: usize = 32;
var g_sem_objs: [MAX_KERNEL_SEMAPHORES]ob.ObjectHeader = undefined;
var g_sem_used: [MAX_KERNEL_SEMAPHORES]bool = [_]bool{false} ** MAX_KERNEL_SEMAPHORES;

fn allocMutexObject(initial_owner: bool) ?u64 {
    var i: usize = 0;
    while (i < MAX_KERNEL_MUTEXES) : (i += 1) {
        if (!g_mutex_used[i]) {
            g_mutex_used[i] = true;
            g_mutex_objs[i] = .{
                .obj_type = .mutex,
                .signal_state = !initial_owner,
                .creation_time = 0,
            };
            return @intFromPtr(&g_mutex_objs[i]);
        }
    }
    return null;
}

fn recycleMutexObject(object_ptr: u64) void {
    if (object_ptr == 0) return;
    var i: usize = 0;
    while (i < MAX_KERNEL_MUTEXES) : (i += 1) {
        if (g_mutex_used[i] and @intFromPtr(&g_mutex_objs[i]) == object_ptr) {
            const hdr = &g_mutex_objs[i];
            if (hdr.refCount() == 0 and hdr.handleCount() == 0) {
                hdr.* = .{ .obj_type = .mutex };
                g_mutex_used[i] = false;
            }
            return;
        }
    }
}

fn allocSemaphoreObject(init_count: i32, max_count: i32) ?u64 {
    if (max_count < 1 or init_count < 0 or init_count > max_count) return null;
    var i: usize = 0;
    while (i < MAX_KERNEL_SEMAPHORES) : (i += 1) {
        if (!g_sem_used[i]) {
            g_sem_used[i] = true;
            var hdr: ob.ObjectHeader = .{ .obj_type = .semaphore };
            hdr.creation_time = @as(u64, @as(u32, @bitCast(init_count))) |
                (@as(u64, @as(u32, @bitCast(max_count))) << 32);
            hdr.signal_state = init_count > 0;
            g_sem_objs[i] = hdr;
            return @intFromPtr(&g_sem_objs[i]);
        }
    }
    return null;
}

fn recycleSemaphoreObject(object_ptr: u64) void {
    if (object_ptr == 0) return;
    var i: usize = 0;
    while (i < MAX_KERNEL_SEMAPHORES) : (i += 1) {
        if (g_sem_used[i] and @intFromPtr(&g_sem_objs[i]) == object_ptr) {
            const hdr = &g_sem_objs[i];
            if (hdr.refCount() == 0 and hdr.handleCount() == 0) {
                hdr.* = .{ .obj_type = .semaphore };
                g_sem_used[i] = false;
            }
            return;
        }
    }
}

fn semaphoreCountOf(hdr: *const ob.ObjectHeader) i32 {
    return @bitCast(@as(u32, @truncate(hdr.creation_time)));
}

fn semaphoreMaxOf(hdr: *const ob.ObjectHeader) i32 {
    return @bitCast(@as(u32, @truncate(hdr.creation_time >> 32)));
}

fn semaphoreStore(hdr: *ob.ObjectHeader, cur: i32, maxv: i32) void {
    const low = @as(u64, @as(u32, @bitCast(cur)));
    const high = @as(u64, @as(u32, @bitCast(maxv))) << 32;
    hdr.creation_time = low | high;
    hdr.signal_state = cur > 0;
}

pub const KeyBasicInformation: u32 = 0;
pub const KeyValueFullInformation: u32 = 1;
pub const KeyValuePartialInformation: u32 = 2;

/// `REG_SZ` / `REG_DWORD_LITTLE_ENDIAN` — WinNT 公开常量值。
pub const REG_NONE: u32 = 0;
pub const REG_SZ: u32 = 1;
pub const REG_DWORD: u32 = 4;

/// x64 `PROCESS_BASIC_INFORMATION` (MSDN). Size must be 48.
const PROCESS_BASIC_INFORMATION = extern struct {
    exit_status: NTSTATUS,
    _pad0: u32,
    peb_base_address: u64,
    affinity_mask: u64,
    base_priority: i32,
    _pad1: u32,
    unique_process_id: u64,
    inherited_from_unique_process_id: u64,
};
comptime {
    std.debug.assert(@sizeOf(PROCESS_BASIC_INFORMATION) == 48);
}

/// Ref: learn.microsoft.com `CLIENT_ID` — 本结构仅用于 `NtOpenProcess` 子集。
pub const CLIENT_ID = extern struct {
    unique_process: usize,
    unique_thread: usize,
};

/// x64 `UNICODE_STRING`（Learn）：`Buffer` 为目标进程用户 VA。
const UNICODE_STRING_NATIVE = extern struct {
    length: u16,
    maximum_length: u16,
    _reserved: u32 = 0,
    buffer: u64,
};
comptime {
    std.debug.assert(@sizeOf(UNICODE_STRING_NATIVE) == 16);
}

const KERNEL_USER_TIMES = extern struct {
    create_time: i64,
    exit_time: i64,
    kernel_time: i64,
    user_time: i64,
};
comptime {
    std.debug.assert(@sizeOf(KERNEL_USER_TIMES) == 32);
}

fn resolveTargetProcess(process_handle: HANDLE) ?*process.Process {
    const cur = process.getCurrentProcess() orelse return null;
    const slot: ob.Handle = @truncate(process_handle);
    if (cur.handle_table.lookupHandle(slot)) |e| {
        if (e.obj_type == .process) {
            const hdr = @as(*ob.ObjectHeader, @ptrFromInt(e.object_ptr));
            return @fieldParentPtr("header", hdr);
        }
        return null;
    }
    const pid: u32 = @truncate(process_handle);
    return process.findProcess(pid);
}

fn desiredAccessToObMask(access: u32) ob.ACCESS_MASK {
    var m: ob.ACCESS_MASK = 0;
    if ((access & 0x80000000) != 0) m |= ob.GENERIC_READ;
    if ((access & 0x40000000) != 0) m |= ob.GENERIC_WRITE;
    if ((access & 0x20000000) != 0) m |= ob.GENERIC_EXECUTE;
    if ((access & 0x10000000) != 0) m |= ob.GENERIC_ALL;
    if (m == 0) m = ob.GENERIC_READ | ob.GENERIC_WRITE;
    return m;
}

fn desiredAccessToFileAccess(access: u32) vfs.FileAccessMode {
    const r = (access & 0x80000000) != 0;
    const w = (access & 0x40000000) != 0;
    if (r and w) return .read_write;
    if (w) return .write;
    return .read;
}

/// `Irp.status` 已为 `NTSTATUS`（与 `io.NTSTATUS` 同值）；保留此别名供审计与旧注释引用。
fn ioStatusFromIrpNtStatus(s: io.NTSTATUS) NTSTATUS {
    return s;
}

// ── Process APIs ──

pub fn NtCreateProcess(
    process_handle: *HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    parent_process: HANDLE,
) NTSTATUS {
    _ = parent_process;
    const alloc = @import("../mm/frame.zig");
    const p = process.createProcess(alloc.kernelFrameAllocatorPtr());
    if (p) |proc| {
        process_handle.* = proc.pid;
        klog.debug("ntdll: NtCreateProcess -> PID=%u", .{proc.pid});
        return STATUS_SUCCESS;
    }
    return STATUS_NO_MEMORY;
}

/// 与 Learn 中 `NtCreateUserProcess` / `NtCreateProcessEx` 区分：本桩仅分配 `EPROCESS` 槽位与 PID，**无** 映像/线程（见 [docs/cn/PHASE_F_PROCESS_CREATE.md](../../docs/cn/PHASE_F_PROCESS_CREATE.md)）。
pub fn NtCreateProcessEx(
    process_handle: ?*HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    parent_process: HANDLE,
    _: u32,
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
) NTSTATUS {
    var local: HANDLE = 0;
    const ph = process_handle orelse &local;
    return NtCreateProcess(ph, 0, null, parent_process);
}

/// PE 映像入口/导入未满足时返回（0xC0000139）。
pub const STATUS_ENTRYPOINT_NOT_FOUND: NTSTATUS = @bitCast(@as(u32, 0xC0000139));

fn basenamePathUtf8(path: []const u8) []const u8 {
    var last: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '\\' or c == '/') last = i + 1;
    }
    return path[last..];
}

/// 阶段 F 子集：由 `dispatchNtCreateUserProcess` 传入已探测的父进程、帧分配器与 **窄字节** 映像路径（UTF-16 由 syscall 层转换）。
/// 与全局 `pe_loader.LoadedImage` 表及 **子进程 `AddressSpace` 未映射映像字节** 的差距见 `PHASE_F_PROCESS_CREATE.md`。
pub fn NtCreateUserProcessFromPath(
    parent: *process.Process,
    frame_alloc: *@import("../mm/frame.zig").FrameAllocator,
    image_path_utf8: []const u8,
    process_handle_out: *HANDLE,
    thread_handle_out: ?*HANDLE,
) NTSTATUS {
    if (image_path_utf8.len == 0) return STATUS_INVALID_PARAMETER;

    const child = process.createProcess(frame_alloc) orelse return STATUS_NO_MEMORY;
    var keep_child: bool = false;
    defer {
        if (!keep_child) _ = process.terminateProcess(child.pid, 1);
    }

    child.parent_pid = parent.pid;
    child.security_token = parent.security_token;

    const exe_name = basenamePathUtf8(image_path_utf8);
    if (exe_name.len == 0) return STATUS_INVALID_PARAMETER;
    const copy_n = @min(exe_name.len, child.name.len);
    @memcpy(child.name[0..copy_n], exe_name[0..copy_n]);
    child.name_len = copy_n;

    const base: u64 = 0x140000000 +% @as(u64, child.pid) *% 0x10000;
    const entry = base + 0x1000;

    const pe_loader = @import("../loader/pe.zig");
    const img = pe_loader.createProcessImage(exe_name, base, entry, child.pid) orelse
        return STATUS_NO_MEMORY;

    if (pe_loader.resolveImports(img) != .success)
        return STATUS_ENTRYPOINT_NOT_FOUND;

    child.image_base_address = base;
    child.peb_address = 0;

    const sched_tid = scheduler.createThread(img.entry_point, child.pid) orelse
        return STATUS_NO_MEMORY;

    const h_proc = parent.handle_table.allocHandle(@intFromPtr(&child.header), ob.GENERIC_ALL, .process) orelse
        return STATUS_INSUFFICIENT_RESOURCES;
    var keep_proc_handle: bool = false;
    defer {
        if (!keep_proc_handle) _ = parent.handle_table.closeHandle(h_proc);
    }

    if (thread_handle_out) |pth| {
        const tobj = process.allocPsThreadObject(sched_tid, child.pid) orelse
            return STATUS_INSUFFICIENT_RESOURCES;
        var keep_tobj: bool = false;
        defer {
            if (!keep_tobj) process.releasePsThreadObject(tobj);
        }

        const h_th = parent.handle_table.allocHandle(@intFromPtr(&tobj.header), ob.GENERIC_ALL, .thread) orelse
            return STATUS_INSUFFICIENT_RESOURCES;
        var keep_th_handle: bool = false;
        defer {
            if (!keep_th_handle) _ = parent.handle_table.closeHandle(h_th);
        }
        pth.* = h_th;
        keep_th_handle = true;
        keep_tobj = true;
    }

    child.thread_count = 1;
    process_handle_out.* = h_proc;
    keep_proc_handle = true;
    keep_child = true;
    return STATUS_SUCCESS;
}

pub fn NtTerminateProcess(process_handle: HANDLE, exit_status: NTSTATUS) NTSTATUS {
    const pid: u32 = @intCast(process_handle & 0xFFFFFFFF);
    if (process.terminateProcess(pid, @bitCast(exit_status))) {
        return STATUS_SUCCESS;
    }
    return STATUS_INVALID_PARAMETER;
}

/// Ref: learn.microsoft.com `NtQueryInformationProcess` — `ProcessInformationClass`, lengths, optional `ReturnLength`.
pub fn NtQueryInformationProcess(
    process_handle: HANDLE,
    process_information_class: u32,
    process_information: ?*anyopaque,
    process_information_length: u32,
    return_length: ?*u32,
) NTSTATUS {
    const proc = resolveTargetProcess(process_handle) orelse return STATUS_INVALID_PARAMETER;

    switch (process_information_class) {
        ProcessBasicInformation => {
            const need: u32 = @intCast(@sizeOf(PROCESS_BASIC_INFORMATION));
            if (return_length) |rl| rl.* = need;
            if (process_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = process_information orelse return STATUS_INVALID_PARAMETER;
            const out: *PROCESS_BASIC_INFORMATION = @ptrCast(@alignCast(buf));
            out.exit_status = 0;
            out._pad0 = 0;
            out.peb_base_address = proc.peb_address;
            out.affinity_mask = 1;
            out.base_priority = 0;
            out._pad1 = 0;
            out.unique_process_id = proc.pid;
            out.inherited_from_unique_process_id = proc.parent_pid;
            return STATUS_SUCCESS;
        },
        ProcessSessionInformation => {
            if (return_length) |rl| rl.* = 4;
            if (process_information_length < 4) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = process_information orelse return STATUS_INVALID_PARAMETER;
            const sess: *align(1) u32 = @ptrCast(buf);
            sess.* = proc.security_token.session_id;
            return STATUS_SUCCESS;
        },
        ProcessWow64Information => {
            const need: u32 = @sizeOf(usize);
            if (return_length) |rl| rl.* = need;
            if (process_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = process_information orelse return STATUS_INVALID_PARAMETER;
            const out: *align(1) usize = @ptrCast(buf);
            out.* = if (proc.is_wow64) @as(usize, @truncate(proc.peb32_user_va)) else 0;
            return STATUS_SUCCESS;
        },
        ProcessImageFileName => {
            const base: usize = @intFromPtr(process_information orelse return STATUS_INVALID_PARAMETER);
            const prefix = "\\??\\C:\\";
            const name_len: u32 = @intCast(proc.name_len);
            const str_u16_bytes: u32 = @intCast(prefix.len * 2 + name_len * 2 + 2);
            const need: u32 = 16 + str_u16_bytes;
            if (return_length) |rl| rl.* = need;
            if (process_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const us_out: *align(1) UNICODE_STRING_NATIVE = @ptrFromInt(base);
            const str_start: u64 = @intCast(base + 16);
            us_out._reserved = 0;
            us_out.buffer = str_start;
            us_out.length = @truncate(prefix.len * 2 + name_len * 2);
            us_out.maximum_length = us_out.length + 2;
            const str_sl: [*]u8 = @ptrFromInt(base + 16);
            var woff: usize = 0;
            for (prefix) |ch| {
                std.mem.writeInt(u16, str_sl[woff..][0..2], ch, .little);
                woff += 2;
            }
            for (proc.name[0..proc.name_len]) |ch| {
                std.mem.writeInt(u16, str_sl[woff..][0..2], ch, .little);
                woff += 2;
            }
            std.mem.writeInt(u16, str_sl[woff..][0..2], 0, .little);
            return STATUS_SUCCESS;
        },
        ProcessCommandLineInformation => {
            // Win7 x64：`PROCESS_COMMAND_LINE_INFORMATION` 为 **UNICODE_STRING + 内联 UTF-16**（Learn / Winternl）。
            // 本内核无独立 PEB 命令行块：用映像短名 **近似** 可执行路径（与 `ProcessImageFileName` 不同，无 `\??\` 前缀）。
            const base: usize = @intFromPtr(process_information orelse return STATUS_INVALID_PARAMETER);
            const name_len: u32 = @intCast(proc.name_len);
            const str_u16_bytes: u32 = @intCast(name_len * 2 + 2);
            const need: u32 = 16 + str_u16_bytes;
            if (return_length) |rl| rl.* = need;
            if (process_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const us_out: *align(1) UNICODE_STRING_NATIVE = @ptrFromInt(base);
            const str_start: u64 = @intCast(base + 16);
            us_out._reserved = 0;
            us_out.buffer = str_start;
            us_out.length = @truncate(name_len * 2);
            us_out.maximum_length = us_out.length + 2;
            const str_sl: [*]u8 = @ptrFromInt(base + 16);
            var woff: usize = 0;
            for (proc.name[0..proc.name_len]) |ch| {
                std.mem.writeInt(u16, str_sl[woff..][0..2], ch, .little);
                woff += 2;
            }
            std.mem.writeInt(u16, str_sl[woff..][0..2], 0, .little);
            return STATUS_SUCCESS;
        },
        else => {
            if (return_length) |rl| rl.* = 0;
            return STATUS_INVALID_INFO_CLASS;
        },
    }
}

pub fn NtSetInformationProcess(_: HANDLE, process_information_class: u32, _: ?*const anyopaque, _: u32) NTSTATUS {
    if (process_information_class == 0) return STATUS_SUCCESS;
    return STATUS_INVALID_INFO_CLASS;
}

pub fn NtSetInformationThread(_: HANDLE, thread_information_class: u32, _: ?*const anyopaque, _: u32) NTSTATUS {
    _ = thread_information_class;
    return STATUS_INVALID_INFO_CLASS;
}

// ── Thread APIs ──

pub fn NtCreateThread(thread_handle: *HANDLE, _: u32) NTSTATUS {
    const tid = process.allocTid() orelse return STATUS_NO_MEMORY;
    thread_handle.* = tid;
    return STATUS_SUCCESS;
}

pub fn NtTerminateThread(_: HANDLE, _: NTSTATUS) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtResumeThread(thread_handle: HANDLE, previous_suspend_count: ?*u32) NTSTATUS {
    _ = thread_handle;
    if (previous_suspend_count) |p| p.* = 0;
    return STATUS_SUCCESS;
}

pub fn NtSuspendThread(thread_handle: HANDLE, previous_suspend_count: ?*u32) NTSTATUS {
    _ = thread_handle;
    if (previous_suspend_count) |p| p.* = 0;
    return STATUS_SUCCESS;
}

pub fn NtAlertThread(thread_handle: HANDLE) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const slot: ob.Handle = @truncate(thread_handle);
    if (proc.handle_table.lookupHandle(slot)) |ent| {
        if (ent.obj_type == .thread) {
            const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
            const pto: *process.PsThreadObject = @fieldParentPtr("header", hdr);
            if (scheduler.getThreadByIndex(pto.scheduler_tid)) |t| {
                t.alert_pending = true;
                return STATUS_SUCCESS;
            }
        }
    } else {
        if (scheduler.getThreadByIndex(@as(usize, @truncate(thread_handle)))) |t| {
            t.alert_pending = true;
            return STATUS_SUCCESS;
        }
    }
    return STATUS_INVALID_HANDLE;
}

pub fn NtTestAlert() NTSTATUS {
    return STATUS_SUCCESS;
}

fn resolvePsThreadFromHandle(thread_handle: HANDLE) ?*process.PsThreadObject {
    const cur = process.getCurrentProcess() orelse return null;
    const slot: ob.Handle = @truncate(thread_handle);
    if (cur.handle_table.lookupHandle(slot)) |ent| {
        if (ent.obj_type != .thread) return null;
        const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
        return @fieldParentPtr("header", hdr);
    }
    return null;
}

fn threadQuerySchedContext(thread_handle: HANDLE) ?struct { sched_tid: usize, host_pid: u32 } {
    if (resolvePsThreadFromHandle(thread_handle)) |pto| {
        return .{ .sched_tid = pto.scheduler_tid, .host_pid = pto.host_pid };
    }
    const idx: usize = @truncate(thread_handle);
    if (scheduler.getThreadByIndex(idx)) |t| {
        return .{ .sched_tid = idx, .host_pid = t.process_id };
    }
    return null;
}

/// C3：`ThreadBasicInformation` / `ThreadTimes` 子集；其余 `THREADINFOCLASS` 渐进扩展（与契约矩阵 §3 同步）。
pub fn NtQueryInformationThread(
    thread_handle: HANDLE,
    thread_information_class: u32,
    thread_information: ?*anyopaque,
    thread_information_length: u32,
    return_length: ?*u32,
) NTSTATUS {
    const ctx = threadQuerySchedContext(thread_handle) orelse {
        if (return_length) |rl| rl.* = 0;
        return STATUS_INVALID_HANDLE;
    };
    switch (thread_information_class) {
        ThreadBasicInformation => {
            const need: u32 = @intCast(@sizeOf(THREAD_BASIC_INFORMATION));
            if (return_length) |rl| rl.* = need;
            if (thread_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = thread_information orelse return STATUS_INVALID_PARAMETER;
            const out: *THREAD_BASIC_INFORMATION = @ptrCast(@alignCast(buf));
            out.exit_status = STATUS_SUCCESS;
            out._pad0 = 0;
            out.teb_base_address = 0;
            out.client_id_unique_process = ctx.host_pid;
            out.client_id_unique_thread = ctx.sched_tid;
            out.affinity_mask = 1;
            out.priority = 0;
            out.base_priority = 0;
            return STATUS_SUCCESS;
        },
        ThreadTimes => {
            const need: u32 = @intCast(@sizeOf(KERNEL_USER_TIMES));
            if (return_length) |rl| rl.* = need;
            if (thread_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = thread_information orelse return STATUS_INVALID_PARAMETER;
            const out: *KERNEL_USER_TIMES = @ptrCast(@alignCast(buf));
            out.* = std.mem.zeroes(KERNEL_USER_TIMES);
            return STATUS_SUCCESS;
        },
        else => {
            if (return_length) |rl| rl.* = 0;
            return STATUS_INVALID_INFO_CLASS;
        },
    }
}

/// 命名管道（PHASE_E **E3.2**）：未实现；与邮件槽同属延后 I/O 表面。
pub fn NtCreateNamedPipeFile(
    _: ?*HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    _: ?*IO_STATUS_BLOCK,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: ?*anyopaque,
    _: u32,
) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

// ── File APIs ──

pub fn NtCreateFile(
    file_handle: *HANDLE,
    access: u32,
    obj_attrs: ?*OBJECT_ATTRIBUTES,
    io_status: *IO_STATUS_BLOCK,
    allocation_size: u64,
    file_attributes: u32,
    share_access: u32,
    create_disposition: u32,
    create_options: u32,
    ea_buffer: ?*anyopaque,
    ea_length: u32,
) NTSTATUS {
    _ = allocation_size;
    _ = file_attributes;
    _ = ea_buffer;
    _ = ea_length;

    io_status.status = STATUS_SUCCESS;
    io_status.information = 0;
    file_handle.* = INVALID_HANDLE_VALUE;

    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const want = desiredAccessToObMask(access);
    if (!token.canOpenFileForAccess(&proc.security_token, want)) {
        io_status.status = STATUS_ACCESS_DENIED;
        return STATUS_ACCESS_DENIED;
    }

    if (obj_attrs) |attrs| {
        if (attrs.object_name) |name| {
            const path_src = name.buffer[0..name.length];
            var wow_path_buf: [512]u8 = undefined;
            const path = wow64_redirect.applyWow64FilePathUtf16Le(proc.is_wow64, path_src, &wow_path_buf) orelse path_src;
            const resolved = vfs.resolvePath(path);
            const faccess = desiredAccessToFileAccess(access);
            var de: vfs.DirEntry = undefined;
            const stat_st = vfs.stat(resolved, &de);

            if (create_disposition == FILE_CREATE) {
                if (stat_st == .success) {
                    io_status.status = STATUS_OBJECT_NAME_COLLISION;
                    return STATUS_OBJECT_NAME_COLLISION;
                }
                io_status.status = STATUS_NOT_IMPLEMENTED;
                return STATUS_NOT_IMPLEMENTED;
            }
            if (create_disposition == FILE_OPEN_IF) {
                if (stat_st != .success) {
                    io_status.status = STATUS_NOT_IMPLEMENTED;
                    return STATUS_NOT_IMPLEMENTED;
                }
            } else if (create_disposition == FILE_OPEN) {
                if (stat_st != .success) {
                    io_status.status = STATUS_OBJECT_NAME_NOT_FOUND;
                    return STATUS_OBJECT_NAME_NOT_FOUND;
                }
            }

            if ((create_options & FILE_DIRECTORY_FILE) != 0) {
                if (stat_st == .success and de.file_type != .directory) {
                    io_status.status = STATUS_NOT_A_DIRECTORY;
                    return STATUS_NOT_A_DIRECTORY;
                }
            }
            if ((create_options & FILE_NON_DIRECTORY_FILE) != 0) {
                if (stat_st == .success and de.file_type == .directory) {
                    io_status.status = STATUS_FILE_IS_A_DIRECTORY;
                    return STATUS_FILE_IS_A_DIRECTORY;
                }
            }

            const sh = if (share_access == 0)
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
            else
                share_access;

            const f = vfs.openEx(resolved, faccess, sh) orelse {
                io_status.status = STATUS_OBJECT_NAME_NOT_FOUND;
                return STATUS_OBJECT_NAME_NOT_FOUND;
            };
            const h = proc.handle_table.allocHandle(@intFromPtr(f), want, .file) orelse {
                _ = vfs.close(f);
                io_status.status = STATUS_INSUFFICIENT_RESOURCES;
                return STATUS_INSUFFICIENT_RESOURCES;
            };
            file_handle.* = h;
            io_status.information = 1;
            return STATUS_SUCCESS;
        }
    }
    io_status.status = STATUS_INVALID_PARAMETER;
    return STATUS_INVALID_PARAMETER;
}

pub fn NtOpenFile(
    file_handle: *HANDLE,
    access: u32,
    obj_attrs: ?*OBJECT_ATTRIBUTES,
    io_status: *IO_STATUS_BLOCK,
    share_access: u32,
    open_options: u32,
) NTSTATUS {
    _ = open_options;
    io_status.status = STATUS_SUCCESS;
    io_status.information = 0;
    file_handle.* = INVALID_HANDLE_VALUE;

    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const want = desiredAccessToObMask(access);
    if (!token.canOpenFileForAccess(&proc.security_token, want)) {
        io_status.status = STATUS_ACCESS_DENIED;
        return STATUS_ACCESS_DENIED;
    }

    if (obj_attrs) |attrs| {
        if (attrs.object_name) |name| {
            const path_src = name.buffer[0..name.length];
            var wow_path_buf: [512]u8 = undefined;
            const path = wow64_redirect.applyWow64FilePathUtf16Le(proc.is_wow64, path_src, &wow_path_buf) orelse path_src;
            const resolved = vfs.resolvePath(path);
            const sh = if (share_access == 0)
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
            else
                share_access;
            const f = vfs.openEx(resolved, .read, sh) orelse {
                io_status.status = STATUS_OBJECT_NAME_NOT_FOUND;
                return STATUS_OBJECT_NAME_NOT_FOUND;
            };
            const h = proc.handle_table.allocHandle(@intFromPtr(f), want, .file) orelse {
                _ = vfs.close(f);
                io_status.status = STATUS_INSUFFICIENT_RESOURCES;
                return STATUS_INSUFFICIENT_RESOURCES;
            };
            file_handle.* = h;
            io_status.information = 1;
            return STATUS_SUCCESS;
        }
    }
    io_status.status = STATUS_INVALID_PARAMETER;
    return STATUS_INVALID_PARAMETER;
}

pub fn NtReadFile(
    file_handle: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    io_status: *IO_STATUS_BLOCK,
    buffer: ?[*]u8,
    length: u32,
    file_offset: ?*const u64,
    _: ?*u32,
) NTSTATUS {
    _ = file_offset;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(file_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse {
        io_status.* = .{ .status = STATUS_INVALID_HANDLE, .information = 0 };
        return STATUS_INVALID_HANDLE;
    };
    if (!token.checkHandleAccess(&proc.handle_table, h, ob.GENERIC_READ)) {
        io_status.* = .{ .status = STATUS_ACCESS_DENIED, .information = 0 };
        return STATUS_ACCESS_DENIED;
    }
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
    const buf = buffer orelse return STATUS_INVALID_PARAMETER;
    var irp = io.Irp{
        .major_function = .read,
        .buffer_ptr = @intFromPtr(buf),
        .buffer_size = length,
    };
    _ = vfs.dispatchFileObjectIrp(f, &irp);
    io_status.status = ioStatusFromIrpNtStatus(irp.status);
    io_status.information = irp.bytes_transferred;
    return io_status.status;
}

pub fn NtWriteFile(
    file_handle: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    io_status: *IO_STATUS_BLOCK,
    buffer: ?[*]const u8,
    length: u32,
    file_offset: ?*const u64,
    _: ?*u32,
) NTSTATUS {
    _ = file_offset;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(file_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse {
        io_status.* = .{ .status = STATUS_INVALID_HANDLE, .information = 0 };
        return STATUS_INVALID_HANDLE;
    };
    if (!token.checkHandleAccess(&proc.handle_table, h, ob.GENERIC_WRITE)) {
        io_status.* = .{ .status = STATUS_ACCESS_DENIED, .information = 0 };
        return STATUS_ACCESS_DENIED;
    }
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
    const buf = buffer orelse return STATUS_INVALID_PARAMETER;
    var irp = io.Irp{
        .major_function = .write,
        .buffer_ptr = @intFromPtr(buf),
        .buffer_size = length,
    };
    _ = vfs.dispatchFileObjectIrp(f, &irp);
    io_status.status = ioStatusFromIrpNtStatus(irp.status);
    io_status.information = irp.bytes_transferred;
    return io_status.status;
}

pub fn NtClose(handle: HANDLE) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(handle);
    const ent = proc.handle_table.lookupMut(h) orelse return STATUS_INVALID_HANDLE;
    const obj_type = ent.obj_type;
    const optr = ent.object_ptr;
    if (obj_type == .file) {
        const f: *vfs.FileObject = @ptrFromInt(optr);
        var irp = io.Irp{ .major_function = .close };
        _ = vfs.dispatchFileObjectIrp(f, &irp);
    }
    if (!proc.handle_table.closeHandle(h)) return STATUS_INVALID_HANDLE;
    if (obj_type == .event) recycleEventObject(optr);
    if (obj_type == .mutex) recycleMutexObject(optr);
    if (obj_type == .semaphore) recycleSemaphoreObject(optr);
    if (obj_type == .token) recycleTokenShadow(optr);
    return STATUS_SUCCESS;
}

/// Ref: learn.microsoft.com `NtQueryDirectoryFile` — `FILE_NAMES_INFORMATION` 最小单条目。
pub fn NtQueryDirectoryFile(
    file_handle: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    io_status: *IO_STATUS_BLOCK,
    file_information: ?*anyopaque,
    length: u32,
    file_information_class: u32,
    _: ?*u32,
    restart_scan: bool,
) NTSTATUS {
    io_status.information = 0;
    if (file_information_class != FileNamesInformation) {
        io_status.status = STATUS_INVALID_INFO_CLASS;
        return STATUS_INVALID_INFO_CLASS;
    }
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(file_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse {
        io_status.* = .{ .status = STATUS_INVALID_HANDLE, .information = 0 };
        return STATUS_INVALID_HANDLE;
    };
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
    if (f.file_type != .directory) {
        io_status.status = STATUS_INVALID_PARAMETER;
        return STATUS_INVALID_PARAMETER;
    }
    if (restart_scan) f.dir_enum_next = 0;

    var ents: [64]vfs.DirEntry = undefined;
    const n = vfs.readdir(f, &ents);
    if (f.dir_enum_next >= n) {
        io_status.status = STATUS_NO_MORE_FILES;
        return STATUS_NO_MORE_FILES;
    }
    const e = ents[f.dir_enum_next];
    f.dir_enum_next += 1;

    const buf = file_information orelse return STATUS_INVALID_PARAMETER;
    const base: [*]u8 = @ptrCast(@alignCast(buf));
    const name_utf16_bytes: u32 = @intCast(e.name_len * 2);
    const need: u32 = 12 + name_utf16_bytes;
    if (length < need) {
        io_status.status = STATUS_INFO_LENGTH_MISMATCH;
        return STATUS_INFO_LENGTH_MISMATCH;
    }

    @as(*align(1) u32, @ptrCast(base)).* = 0;
    @as(*align(1) u32, @ptrCast(base + 4)).* = 0;
    @as(*align(1) u32, @ptrCast(base + 8)).* = name_utf16_bytes;

    const name_dst: [*]align(1) u16 = @ptrCast(base + 12);
    var i: usize = 0;
    while (i < e.name_len) : (i += 1) {
        name_dst[i] = @as(u16, e.name[i]);
    }

    io_status.status = STATUS_SUCCESS;
    io_status.information = need;
    return STATUS_SUCCESS;
}

pub fn NtDeleteFile(_: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtFlushBuffersFile(_: HANDLE, _: ?*IO_STATUS_BLOCK) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtFsControlFile(
    _: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    _: *IO_STATUS_BLOCK,
    _: u32,
    _: ?*anyopaque,
    _: u32,
    _: ?*anyopaque,
    _: u32,
) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtCancelIoFile(_: HANDLE, _: *IO_STATUS_BLOCK) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtCancelIoFileEx(_: HANDLE, _: ?*IO_STATUS_BLOCK, _: *IO_STATUS_BLOCK) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

// ── Object APIs ──

pub const NOTIFICATION_EVENT: u32 = 0;
pub const SYNCHRONIZATION_EVENT: u32 = 1;
pub const DUPLICATE_SAME_ACCESS: u32 = 0x00000002;

/// `OBJECT_INFORMATION_CLASS` 子集 — Ref: learn.microsoft.com `NtSetInformationObject`。
pub const ObjectBasicInformation: u32 = 0;

pub fn NtSetInformationObject(
    _: HANDLE,
    object_information_class: u32,
    object_information: ?*const anyopaque,
    object_information_length: u32,
) NTSTATUS {
    if (object_information_length > 0 and object_information == null) return STATUS_INVALID_PARAMETER;
    if (object_information_class != ObjectBasicInformation) return STATUS_INVALID_INFO_CLASS;
    return STATUS_NOT_IMPLEMENTED;
}

const PUBLIC_OBJECT_BASIC_INFORMATION = extern struct {
    Attributes: u32 = 0,
    GrantedAccess: u32 = 0,
    HandleCount: u32 = 0,
    PointerCount: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(PUBLIC_OBJECT_BASIC_INFORMATION) == 16);
}

/// Ref: learn.microsoft.com `NtQueryObject` — `OBJECT_INFORMATION_CLASS` 子集。
pub fn NtQueryObject(handle: HANDLE, info_class: u32, buf: ?*anyopaque, len: u32, ret_len: ?*u32) NTSTATUS {
    if (info_class != ObjectBasicInformation) {
        if (ret_len) |r| r.* = 0;
        return STATUS_INVALID_INFO_CLASS;
    }
    const need: u32 = @intCast(@sizeOf(PUBLIC_OBJECT_BASIC_INFORMATION));
    if (ret_len) |r| r.* = need;
    if (len < need) return STATUS_INFO_LENGTH_MISMATCH;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    const b = buf orelse return STATUS_INVALID_PARAMETER;
    const hdr = @as(*const ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    const out: *PUBLIC_OBJECT_BASIC_INFORMATION = @ptrCast(@alignCast(b));
    out.* = .{};
    out.GrantedAccess = ent.granted_access;
    out.HandleCount = hdr.handleCount();
    out.PointerCount = hdr.refCount();
    return STATUS_SUCCESS;
}

/// 与 `ob.initNamespace` 中 `\ObjectTypes` 等目录名成对；句柄表引用静态头（非堆分配）。
var g_namespace_dir_object_types: ob.ObjectHeader = .{ .obj_type = .directory };

/// Ref: learn.microsoft.com `NtOpenDirectoryObject` — 命名空间登记目录子集。
pub fn NtOpenDirectoryObject(dir_handle: *HANDLE, desired_access: u32, oa: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    const attrs = oa orelse return STATUS_INVALID_PARAMETER;
    const uname = attrs.object_name orelse return STATUS_INVALID_PARAMETER;
    if (uname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    if (!probe.probeUserMemory(asp, @intFromPtr(dir_handle), @sizeOf(HANDLE), true))
        return STATUS_ACCESS_VIOLATION;
    const raw = uname.buffer[0..uname.length];
    const norm = ob.normalizeNtObjectPath(raw);
    const resolved = ob.normalizeNtObjectPathResolveSymlinks(norm);
    if (ob.lookupNamespace(resolved)) |e| {
        if (e.obj_type != .directory) return STATUS_INVALID_PARAMETER;
        const h = proc.handle_table.allocHandle(
            @intFromPtr(&g_namespace_dir_object_types),
            desiredAccessToObMask(desired_access),
            .directory,
        ) orelse return STATUS_INSUFFICIENT_RESOURCES;
        dir_handle.* = h;
        return STATUS_SUCCESS;
    }
    return STATUS_OBJECT_NAME_NOT_FOUND;
}

/// 目录枚举生产路径为路线图；当前返回未实现。
pub fn NtQueryDirectoryObject(
    _: HANDLE,
    _: ?*anyopaque,
    _: u32,
    _: u32,
    _: u32,
    _: ?*u32,
) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtOpenThread(
    thread_handle: *HANDLE,
    desired_access: u32,
    object_attributes: ?*OBJECT_ATTRIBUTES,
    client_id: ?*anyopaque,
) NTSTATUS {
    _ = object_attributes;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    if (client_id == null) return STATUS_INVALID_PARAMETER;
    const cid_ptr: *CLIENT_ID = @ptrCast(@alignCast(client_id.?));
    if (!probe.probeUserMemory(asp, @intFromPtr(cid_ptr), @sizeOf(CLIENT_ID), false))
        return STATUS_ACCESS_VIOLATION;
    const cid = cid_ptr.*;
    const host_pid: u32 = @truncate(cid.unique_process);
    const tobj = process.findPsThreadForOpen(host_pid, cid.unique_thread) orelse return STATUS_INVALID_PARAMETER;
    if (!token.seThreadOpenAllowed(&proc.security_token, desired_access)) {
        @import("../se/audit.zig").logObjectOpenDenied("NtOpenThread");
        return STATUS_ACCESS_DENIED;
    }
    if (!probe.probeUserMemory(asp, @intFromPtr(thread_handle), @sizeOf(HANDLE), true))
        return STATUS_ACCESS_VIOLATION;
    const grant = desiredAccessToObMask(desired_access);
    const h = proc.handle_table.allocHandle(@intFromPtr(&tobj.header), grant, .thread) orelse
        return STATUS_INSUFFICIENT_RESOURCES;
    thread_handle.* = h;
    return STATUS_SUCCESS;
}

pub fn NtCreateEvent(
    event_handle: *HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    event_type: u32,
    initial_state: bool,
) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const ptr = allocEventObject(initial_state, event_type) orelse return STATUS_NO_MEMORY;
    const h = proc.handle_table.allocHandle(ptr, ob.GENERIC_ALL | ob.SYNCHRONIZE, .event) orelse {
        forceFreeEventSlot(ptr);
        return STATUS_INSUFFICIENT_RESOURCES;
    };
    event_handle.* = h;
    return STATUS_SUCCESS;
}

fn forceFreeEventSlot(object_ptr: u64) void {
    var i: usize = 0;
    while (i < MAX_KERNEL_EVENTS) : (i += 1) {
        if (g_event_used[i] and @intFromPtr(&g_event_objs[i]) == object_ptr) {
            g_event_objs[i] = .{};
            g_event_used[i] = false;
            return;
        }
    }
}

pub fn NtSetEvent(ev: HANDLE, prev: ?*u32) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(ev);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .event) return STATUS_INVALID_PARAMETER;
    const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    if (prev) |p| p.* = if (hdr.signal_state) 1 else 0;
    hdr.signal_state = true;
    wait_mod.onEventSet(hdr);
    return STATUS_SUCCESS;
}

pub fn NtResetEvent(ev: HANDLE, prev: ?*u32) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(ev);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .event) return STATUS_INVALID_PARAMETER;
    const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    if (prev) |p| p.* = if (hdr.signal_state) 1 else 0;
    hdr.signal_state = false;
    return STATUS_SUCCESS;
}

pub fn NtCreateMutant(handle: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, initial_owner: bool) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const ptr = allocMutexObject(initial_owner) orelse return STATUS_NO_MEMORY;
    const h = proc.handle_table.allocHandle(ptr, ob.GENERIC_ALL | ob.SYNCHRONIZE, .mutex) orelse {
        recycleMutexObject(ptr);
        return STATUS_INSUFFICIENT_RESOURCES;
    };
    handle.* = h;
    return STATUS_SUCCESS;
}

pub fn NtReleaseMutant(ev: HANDLE, prev: ?*u32) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(ev);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .mutex) return STATUS_INVALID_PARAMETER;
    const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    if (prev) |p| p.* = if (hdr.signal_state) 1 else 0;
    hdr.signal_state = true;
    wait_mod.wakeOneWaiterFromDispatch(hdr);
    return STATUS_SUCCESS;
}

pub fn NtCreateSemaphore(
    handle: *HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    initial_count: i32,
    maximum_count: i32,
) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const ptr = allocSemaphoreObject(initial_count, maximum_count) orelse return STATUS_INVALID_PARAMETER;
    const h = proc.handle_table.allocHandle(ptr, ob.GENERIC_ALL | ob.SYNCHRONIZE, .semaphore) orelse {
        recycleSemaphoreObject(ptr);
        return STATUS_INSUFFICIENT_RESOURCES;
    };
    handle.* = h;
    return STATUS_SUCCESS;
}

pub fn NtOpenMutant(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

/// `MUTANT_INFORMATION_CLASS` 子集 — Ref: learn.microsoft.com `NtQueryMutant`.
pub const MutantBasicInformation: u32 = 0;

const MUTANT_BASIC_INFORMATION = extern struct {
    CurrentCount: i32 = 0,
    OwnedByCaller: u8 = 0,
    AbandonedState: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(MUTANT_BASIC_INFORMATION) == 8);
}

pub fn NtQueryMutant(ev: HANDLE, info_class: u32, buf: ?*anyopaque, buf_len: u32, ret_len: ?*u32) NTSTATUS {
    if (info_class != MutantBasicInformation) {
        if (ret_len) |r| r.* = 0;
        return STATUS_INVALID_INFO_CLASS;
    }
    const need: u32 = @intCast(@sizeOf(MUTANT_BASIC_INFORMATION));
    if (ret_len) |r| r.* = need;
    if (buf_len < need) return STATUS_INFO_LENGTH_MISMATCH;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(ev);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .mutex) return STATUS_INVALID_PARAMETER;
    const b = buf orelse return STATUS_INVALID_PARAMETER;
    const hdr = @as(*const ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    const out: *MUTANT_BASIC_INFORMATION = @ptrCast(@alignCast(b));
    out.CurrentCount = if (hdr.signal_state) 1 else 0;
    out.OwnedByCaller = 0;
    out.AbandonedState = 0;
    out._pad = .{ 0, 0 };
    return STATUS_SUCCESS;
}

pub fn NtOpenEvent(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtOpenSemaphore(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtPulseEvent(_: HANDLE, _: ?*u32) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtClearEvent(ev: HANDLE, prev: ?*u32) NTSTATUS {
    return NtResetEvent(ev, prev);
}

pub fn NtReleaseSemaphore(ev: HANDLE, release_count: i32, prev: ?*i32) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(ev);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .semaphore) return STATUS_INVALID_PARAMETER;
    if (release_count < 1) return STATUS_INVALID_PARAMETER;
    const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
    const cur = semaphoreCountOf(hdr);
    const maxv = semaphoreMaxOf(hdr);
    const add = @as(i64, cur) + @as(i64, release_count);
    if (add > maxv) return STATUS_INVALID_PARAMETER;
    const newc: i32 = @intCast(add);
    if (prev) |p| p.* = cur;
    semaphoreStore(hdr, newc, maxv);
    wait_mod.wakeOneWaiterFromDispatch(hdr);
    return STATUS_SUCCESS;
}

/// 将 `timeout` 100ns 单位粗算为调度 tick 增量（简化：非精确 wall-clock，与 `scheduler.getTicks` 对齐）。
fn timeout100nsToExtraTicks(v_100ns: u64) u64 {
    // 约每 1ms ≈ 10_000 × 100ns；每 tick 视作 ~1ms 量级（取决于 HPET/定时器配置）。
    const per_tick = 10_000 * 1000;
    return @max(1, v_100ns / per_tick);
}

pub fn NtWaitForSingleObject(handle: HANDLE, alertable: bool, timeout: ?*const i64) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_HANDLE;

    var timeout_val: ?i64 = null;
    if (timeout) |tp| {
        const tva = @intFromPtr(tp);
        if (!probe.probeUserMemory(asp, tva, @sizeOf(i64), false)) return STATUS_ACCESS_VIOLATION;
        timeout_val = @as(*const volatile i64, @ptrFromInt(tva)).*;
    }

    const h: ob.Handle = @truncate(handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;

    switch (ent.obj_type) {
        .event, .mutex, .semaphore => {
            const hdr = @as(*ob.ObjectHeader, @ptrFromInt(ent.object_ptr));
            const now0 = scheduler.getTicks();
            const deadline: ?u64 = blk: {
                const tv = timeout_val orelse break :blk null; // NULL 指针：无限等待
                if (tv == 0) break :blk now0; // 轮询：立即到期
                if (tv < 0) {
                    const rel = @as(u64, @intCast(-tv));
                    break :blk now0 + timeout100nsToExtraTicks(rel);
                }
                // 正数：绝对到期时间（NT `LARGE_INTEGER`）；本阶段未接单调时钟绝对域，按无限等待处理。
                break :blk null;
            };
            return wait_mod.keWaitForSingleObject(hdr, alertable, deadline);
        },
        else => return STATUS_WAIT_0,
    }
}

/// `wait_type`：`0` = WaitAny；`1` = WaitAll（**抢占调度关** 时协作式子集；开调度见 [docs/cn/PHASE_E_NATIVE_API.md](../../docs/cn/PHASE_E_NATIVE_API.md)）。
pub fn NtWaitForMultipleObjects(count: u32, handles: []const HANDLE, wait_type: u32, alertable: bool, timeout: ?*const i64) NTSTATUS {
    if (wait_type != 0 and wait_type != 1) return STATUS_NOT_IMPLEMENTED;
    if (count == 0 or count > 64) return STATUS_INVALID_PARAMETER;
    if (handles.len < count) return STATUS_INVALID_PARAMETER;

    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_HANDLE;

    var timeout_val: ?i64 = null;
    if (timeout) |tp| {
        const tva = @intFromPtr(tp);
        if (!probe.probeUserMemory(asp, tva, @sizeOf(i64), false)) return STATUS_ACCESS_VIOLATION;
        timeout_val = @as(*const volatile i64, @ptrFromInt(tva)).*;
    }

    var hdr_buf: [64]*ob.ObjectHeader = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const h: ob.Handle = @truncate(handles[i]);
        const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
        switch (ent.obj_type) {
            .event, .mutex, .semaphore => {
                hdr_buf[i] = @ptrFromInt(ent.object_ptr);
            },
            else => return STATUS_INVALID_PARAMETER,
        }
    }

    const now0 = scheduler.getTicks();
    const deadline: ?u64 = blk: {
        const tv = timeout_val orelse break :blk null;
        if (tv == 0) break :blk now0;
        if (tv < 0) {
            const rel = @as(u64, @intCast(-tv));
            break :blk now0 + timeout100nsToExtraTicks(rel);
        }
        break :blk null;
    };
    if (wait_type == 1) {
        return wait_mod.keWaitForMultipleObjectsWaitAll(hdr_buf[0..count], alertable, deadline);
    }
    return wait_mod.keWaitForMultipleObjectsWaitAny(hdr_buf[0..count], alertable, deadline);
}

/// Ref: learn.microsoft.com `NtSignalAndWaitForSingleObject` — 先对信号句柄 `NtSetEvent`（仅事件），再等待第二句柄。
pub fn NtSignalAndWaitForSingleObject(
    signal_handle: HANDLE,
    wait_handle: HANDLE,
    alertable: u8,
    timeout: ?*const i64,
) NTSTATUS {
    const st_sig = NtSetEvent(signal_handle, null);
    if (st_sig != STATUS_SUCCESS) return st_sig;
    return NtWaitForSingleObject(wait_handle, alertable != 0, timeout);
}

// ── Section (Memory-mapped) APIs ──

/// Ref: https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-createfilemappingw — `SEC_*` 与节区属性。
pub const SEC_FILE: u32 = 0x00800000;
pub const SEC_IMAGE: u32 = 0x01000000;

pub fn NtCreateSection(
    section_handle: *HANDLE,
    desired_access: u32,
    object_attributes: ?*OBJECT_ATTRIBUTES,
    maximum_size: ?*u64,
    page_protect: u32,
    allocation_attributes: u32,
    file_handle: HANDLE,
) NTSTATUS {
    _ = desired_access;
    _ = object_attributes;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const max_sz = if (maximum_size) |p| p.* else return STATUS_INVALID_PARAMETER;

    if (file_handle != 0) {
        const is_image = (allocation_attributes & SEC_IMAGE) != 0;
        const fh: ob.Handle = @truncate(file_handle);
        const ent = proc.handle_table.lookupHandle(fh) orelse return STATUS_INVALID_HANDLE;
        if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
        const fo = @as(*vfs.FileObject, @ptrFromInt(ent.object_ptr));
        const sec = section_mm.createFileBackedSection(max_sz, page_protect, fo, is_image) orelse return STATUS_NO_MEMORY;
        const h = proc.handle_table.allocHandle(@intFromPtr(sec), ob.GENERIC_ALL, .section) orelse {
            section_mm.releaseSectionObject(sec);
            return STATUS_NO_MEMORY;
        };
        section_handle.* = h;
        return STATUS_SUCCESS;
    }

    const sec = section_mm.createAnonymousSection(max_sz, page_protect) orelse return STATUS_NO_MEMORY;
    const h = proc.handle_table.allocHandle(@intFromPtr(sec), ob.GENERIC_ALL, .section) orelse {
        section_mm.releaseSectionObject(sec);
        return STATUS_NO_MEMORY;
    };
    section_handle.* = h;
    return STATUS_SUCCESS;
}

pub fn NtMapViewOfSection(
    section_handle: HANDLE,
    process_handle: HANDLE,
    base_address: *u64,
    zero_bits: u64,
    commit_size: u64,
    section_offset: ?*u64,
    view_size: *u64,
    inherit_disposition: u32,
    allocation_type: u32,
    win32_protect: u32,
) NTSTATUS {
    _ = zero_bits;
    _ = commit_size;
    _ = inherit_disposition;
    _ = allocation_type;
    _ = win32_protect;
    const off: u64 = if (section_offset) |p| p.* else 0;
    const cur = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h32: ob.Handle = @truncate(section_handle);
    const ent = cur.handle_table.lookupHandle(h32) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .section) return STATUS_INVALID_PARAMETER;
    const sec: *section_mm.SectionObject = @ptrFromInt(ent.object_ptr);
    const tpid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(tpid) orelse return STATUS_INVALID_HANDLE;
    return section_mm.mapViewIntoProcess(proc, sec, base_address, off, view_size);
}

pub fn NtUnmapViewOfSection(process_handle: HANDLE, base_address: u64) NTSTATUS {
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    return section_mm.unmapViewInProcess(proc, base_address);
}

// ── IPC APIs ──

pub fn NtCreatePort(port_handle: *HANDLE, name: []const u8) NTSTATUS {
    const pid = process.getCurrentPid();
    const p = port.createPort(pid, name);
    if (p) |created| {
        port_handle.* = created.id;
        return STATUS_SUCCESS;
    }
    return STATUS_NO_MEMORY;
}

pub fn NtRequestWaitReplyPort(
    port_handle: HANDLE,
    opcode: u32,
    data: ?*const [ipc.MSG_DATA_SIZE]u8,
    reply: *ipc.Message,
) NTSTATUS {
    const pid = process.getCurrentPid();
    const result = port.requestWaitReplyPort(pid, @intCast(port_handle), opcode, data);
    if (result) |msg| {
        reply.* = msg;
        return STATUS_SUCCESS;
    }
    return STATUS_INVALID_PARAMETER;
}

/// Ref: learn.microsoft.com — `NtReplyWaitReceivePort` 子集；与 [port.zig](../lpc/port.zig) `replyWaitReceivePort` 一致。
pub fn NtReplyWaitReceivePort(
    port_handle: HANDLE,
    reply_message: ?*ipc.Message,
    receive_message: *ipc.Message,
) NTSTATUS {
    const pid = process.getCurrentPid();
    if (!port.replyWaitReceivePort(pid, @intCast(port_handle), reply_message, receive_message))
        return STATUS_INVALID_PARAMETER;
    return STATUS_SUCCESS;
}

pub fn NtConnectPort(port_handle: *HANDLE, name: []const u8) NTSTATUS {
    const pid = process.getCurrentPid();
    const p = port.connectPort(pid, name) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    port_handle.* = p.id;
    return STATUS_SUCCESS;
}

// ── Memory APIs ──

fn processHandleToPid(h: HANDLE) ?u32 {
    if (h == INVALID_HANDLE_VALUE or h == 0) return process.getCurrentPid();
    return @intCast(h & 0xFFFFFFFF);
}

/// Ref: learn.microsoft.com `NtDuplicateObject` — 同进程句柄表复制；跨进程为路线图项。
pub fn NtDuplicateObject(
    source_process_handle: HANDLE,
    source_handle: HANDLE,
    target_process_handle: HANDLE,
    target_handle: *HANDLE,
    desired_access: u32,
    handle_attributes: u32,
    options: u32,
) NTSTATUS {
    _ = handle_attributes;
    const src_pid = processHandleToPid(source_process_handle) orelse return STATUS_INVALID_HANDLE;
    const dst_pid = processHandleToPid(target_process_handle) orelse return STATUS_INVALID_HANDLE;
    if (src_pid != dst_pid) return STATUS_NOT_IMPLEMENTED;

    const proc = process.findProcess(src_pid) orelse return STATUS_INVALID_HANDLE;
    const sh: ob.Handle = @truncate(source_handle);
    const ent = proc.handle_table.lookupHandle(sh) orelse return STATUS_INVALID_HANDLE;

    var grant: ob.ACCESS_MASK = desired_access;
    if ((options & DUPLICATE_SAME_ACCESS) != 0 or grant == 0)
        grant = ent.granted_access;

    if ((grant & ent.granted_access) != grant) {
        if (!proc.security_token.is_elevated and !proc.security_token.owner.eql(token.SYSTEM_SID)) {
            @import("../se/audit.zig").logObjectOpenDenied("NtDuplicateObject_escalate");
            return STATUS_ACCESS_DENIED;
        }
    }

    const nh = proc.handle_table.duplicateHandle(sh, grant) orelse return STATUS_INSUFFICIENT_RESOURCES;
    target_handle.* = nh;
    return STATUS_SUCCESS;
}

pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_DECOMMIT: u32 = 0x4000;
pub const MEM_RELEASE: u32 = 0x8000;
/// 以下标志在 `vm.zig` / VAD 中 **未实现**；`NtAllocateVirtualMemory` / `NtFreeVirtualMemory` 遇之返回 `STATUS_NOT_IMPLEMENTED`（显式 NTSTATUS，见契约矩阵 C3）。
pub const MEM_RESET: u32 = 0x80000;
pub const MEM_TOP_DOWN: u32 = 0x100000;
pub const MEM_PHYSICAL: u32 = 0x400000;
pub const MEM_LARGE_PAGES: u32 = 0x20000000;
/// x64 上 `VirtualAlloc` 保留/释放粒度（Learn — Memory Management）。
pub const MEM_ALLOCATION_GRANULARITY: u64 = 64 * 1024;
pub const PAGE_NOACCESS: u32 = 0x01;
pub const PAGE_READONLY: u32 = 0x02;
pub const PAGE_READWRITE: u32 = 0x04;
pub const PAGE_WRITECOPY: u32 = 0x08;
pub const PAGE_EXECUTE: u32 = 0x10;
pub const PAGE_EXECUTE_READ: u32 = 0x20;
pub const PAGE_EXECUTE_READWRITE: u32 = 0x40;
pub const PAGE_EXECUTE_WRITECOPY: u32 = 0x80;
pub const PAGE_GUARD: u32 = 0x100;

var user_alloc_va_salt: u32 = 0x9E37_79B9;

pub fn NtAllocateVirtualMemory(
    process_handle: HANDLE,
    base_address: *u64,
    zero_bits: u64,
    region_size: *u64,
    allocation_type: u32,
    protect: u32,
) NTSTATUS {
    _ = zero_bits;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    const space = proc.address_space orelse return STATUS_NO_MEMORY;

    const commit = (allocation_type & MEM_COMMIT) != 0;
    const reserve = (allocation_type & MEM_RESERVE) != 0;
    if (!commit and !reserve) return STATUS_INVALID_PARAMETER;
    const alloc_mask = MEM_COMMIT | MEM_RESERVE;
    if ((allocation_type & ~alloc_mask) != 0) return STATUS_NOT_IMPLEMENTED;

    const page_size: u64 = 4096;
    var size = region_size.*;
    if (size == 0) return STATUS_INVALID_PARAMETER;
    size = (size + page_size - 1) & ~(page_size - 1);
    if (reserve) {
        size = (size + MEM_ALLOCATION_GRANULARITY - 1) & ~(MEM_ALLOCATION_GRANULARITY - 1);
    }
    const num_pages = @as(usize, @intCast(size / page_size));

    var base = base_address.*;
    if (base == 0) {
        user_alloc_va_salt = user_alloc_va_salt *% 1664525 +% 1013904223;
        const slide_pages: u64 = @as(u64, user_alloc_va_salt % 512);
        base = 0x0000_0000_4000_0000 + slide_pages * page_size;
        base &= ~(MEM_ALLOCATION_GRANULARITY - 1);
        while (space.getPhysical(base) != null or vm.isVirtInReservedRange(space, base, num_pages)) {
            base += MEM_ALLOCATION_GRANULARITY;
        }
    }
    if (base & (page_size - 1) != 0) return STATUS_INVALID_PARAMETER;
    if (reserve and (base & (MEM_ALLOCATION_GRANULARITY - 1)) != 0) return STATUS_INVALID_PARAMETER;

    const prot: u32 = if (protect != 0) protect else PAGE_READWRITE;
    const flags = vm.mapFlagsFromNtProtect(prot);

    if (reserve and commit) {
        if (!vm.mapRange(space, base, num_pages, flags)) return STATUS_NO_MEMORY;
        vm.recordCommittedVadRange(space, base, @intCast(num_pages), prot);
        base_address.* = base;
        region_size.* = size;
        return STATUS_SUCCESS;
    }

    if (reserve and !commit) {
        if (!space.reserveVirtualRange(base, @intCast(num_pages), prot)) return STATUS_NO_MEMORY;
        base_address.* = base;
        region_size.* = size;
        return STATUS_SUCCESS;
    }

    // MEM_COMMIT only：已映射页跳过；未映射页在 reserved 区内由 `mapPageAlloc` 提交，否则匿名提交。
    var p: usize = 0;
    while (p < num_pages) : (p += 1) {
        const v = base + p * page_size;
        if (space.getPhysical(v) != null) continue;
        if (space.mapPageAlloc(v, flags) == null) return STATUS_NO_MEMORY;
    }
    const end_excl = base + size;
    space.vad.markCommittedRange(base, end_excl);
    if (space.vad.findContaining(base) == null) {
        vm.recordCommittedVadRange(space, base, @intCast(num_pages), prot);
    }
    base_address.* = base;
    region_size.* = size;
    return STATUS_SUCCESS;
}

pub fn NtFreeVirtualMemory(
    process_handle: HANDLE,
    base_address: *u64,
    region_size: *u64,
    free_type: u32,
) NTSTATUS {
    const has_rel = (free_type & MEM_RELEASE) != 0;
    const has_dec = (free_type & MEM_DECOMMIT) != 0;
    if (has_rel and has_dec) return STATUS_INVALID_PARAMETER;
    if (!has_rel and !has_dec) return STATUS_INVALID_PARAMETER;
    const free_mask = MEM_RELEASE | MEM_DECOMMIT;
    if ((free_type & ~free_mask) != 0) return STATUS_NOT_IMPLEMENTED;

    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    const space = proc.address_space orelse return STATUS_NO_MEMORY;

    const page_size: u64 = 4096;
    var size = region_size.*;
    if (size == 0) return STATUS_INVALID_PARAMETER;
    size = (size + page_size - 1) & ~(page_size - 1);
    const num_pages = @as(usize, @intCast(size / page_size));

    if (has_dec) {
        if (!vm.decommitVirtualRange(space, base_address.*, num_pages)) return STATUS_INVALID_PARAMETER;
        return STATUS_SUCCESS;
    }

    vm.unmapRange(space, base_address.*, num_pages);
    return STATUS_SUCCESS;
}

pub fn NtQueryVirtualMemory(
    process_handle: HANDLE,
    base_address: u64,
    memory_information_class: u32,
    memory_information: ?*anyopaque,
    memory_information_length: u32,
    return_length: ?*u32,
) NTSTATUS {
    if (return_length) |rl| rl.* = 0;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_NO_MEMORY;
    if (memory_information_class != 0) return STATUS_INVALID_INFO_CLASS;
    const need = @sizeOf(vm.MemoryBasicInformation);
    if (memory_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
    const buf = memory_information orelse return STATUS_INVALID_PARAMETER;
    if (!probe.probeUserMemory(asp, @intFromPtr(buf), need, true)) return STATUS_ACCESS_VIOLATION;
    // SAFETY: `probeUserMemory` 已确认缓冲区可写；`MEMORY_BASIC_INFORMATION` 要求 8 字节对齐（公开 ABI）。
    const out: *vm.MemoryBasicInformation = @ptrCast(@alignCast(buf));
    vm.fillMemoryBasicInformation(asp, base_address, out);
    if (return_length) |rl| rl.* = need;
    return STATUS_SUCCESS;
}

/// Ref: j00ru — Windows 7 SP1 x64 `NtReadVirtualMemory`。
pub fn NtReadVirtualMemory(
    process_handle: HANDLE,
    base_address: u64,
    buffer: [*]u8,
    buffer_size: u32,
    number_of_bytes_read: ?*usize,
) NTSTATUS {
    const spid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const srcp = process.findProcess(spid) orelse return STATUS_INVALID_HANDLE;
    const src_space = srcp.address_space orelse return STATUS_NO_MEMORY;
    const dstp = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const dst_space = dstp.address_space orelse return STATUS_INVALID_HANDLE;
    if (spid != process.getCurrentPid()) {
        if (!dstp.security_token.is_elevated) return STATUS_ACCESS_DENIED;
    }
    if (buffer_size == 0) {
        if (number_of_bytes_read) |n| n.* = 0;
        return STATUS_SUCCESS;
    }
    if (!probe.probeUserMemory(dst_space, @intFromPtr(buffer), buffer_size, true)) return STATUS_ACCESS_VIOLATION;
    if (number_of_bytes_read) |n| {
        if (!probe.probeUserMemory(dst_space, @intFromPtr(n), @sizeOf(usize), true)) return STATUS_ACCESS_VIOLATION;
    }
    var i: u32 = 0;
    while (i < buffer_size) : (i += 1) {
        const va = base_address + @as(u64, i);
        const pa = src_space.getPhysical(va) orelse break;
        const src_byte: *const volatile u8 = @ptrFromInt(pa);
        buffer[i] = src_byte.*;
    }
    if (number_of_bytes_read) |n| n.* = i;
    if (i != buffer_size) return STATUS_ACCESS_VIOLATION;
    return STATUS_SUCCESS;
}

/// Ref: j00ru — Windows 7 SP1 x64 `NtWriteVirtualMemory`。
pub fn NtWriteVirtualMemory(
    process_handle: HANDLE,
    base_address: u64,
    buffer: [*]const u8,
    buffer_size: u32,
    number_of_bytes_written: ?*usize,
) NTSTATUS {
    const dpid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const dstp = process.findProcess(dpid) orelse return STATUS_INVALID_HANDLE;
    const dst_space = dstp.address_space orelse return STATUS_NO_MEMORY;
    const srcp = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const src_space = srcp.address_space orelse return STATUS_INVALID_HANDLE;
    if (dpid != process.getCurrentPid()) {
        if (!srcp.security_token.is_elevated) return STATUS_ACCESS_DENIED;
    }
    if (buffer_size == 0) {
        if (number_of_bytes_written) |n| n.* = 0;
        return STATUS_SUCCESS;
    }
    if (!probe.probeUserMemory(src_space, @intFromPtr(buffer), buffer_size, false)) return STATUS_ACCESS_VIOLATION;
    if (number_of_bytes_written) |n| {
        if (!probe.probeUserMemory(src_space, @intFromPtr(n), @sizeOf(usize), true)) return STATUS_ACCESS_VIOLATION;
    }
    var i: u32 = 0;
    while (i < buffer_size) : (i += 1) {
        const va = base_address + @as(u64, i);
        const pa = dst_space.getPhysical(va) orelse break;
        if (!pagingIsWritable(dst_space, va)) return STATUS_ACCESS_VIOLATION;
        const dst_byte: *volatile u8 = @ptrFromInt(pa);
        dst_byte.* = buffer[i];
    }
    if (number_of_bytes_written) |n| n.* = i;
    if (i != buffer_size) return STATUS_ACCESS_VIOLATION;
    return STATUS_SUCCESS;
}

fn pagingIsWritable(space: *vm.AddressSpace, va: u64) bool {
    const arch_mod = @import("../arch.zig");
    const paging = arch_mod.impl.paging;
    if (@hasDecl(paging, "isPageWritable")) {
        return paging.isPageWritable(space.pml4_phys, va);
    }
    return true;
}

/// Ref: learn.microsoft.com `NtOpenProcess` — `CLIENT_ID.UniqueProcess` 子集；返回进程对象句柄（槽位索引）。
pub fn NtOpenProcess(
    process_handle: *HANDLE,
    desired_access: u32,
    object_attributes: ?*OBJECT_ATTRIBUTES,
    client_id: ?*CLIENT_ID,
) NTSTATUS {
    _ = object_attributes;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    if (client_id == null) return STATUS_INVALID_PARAMETER;
    const cid_ptr = client_id.?;
    if (!probe.probeUserMemory(asp, @intFromPtr(cid_ptr), @sizeOf(CLIENT_ID), false))
        return STATUS_ACCESS_VIOLATION;
    const cid = cid_ptr.*;
    const pid: u32 = @truncate(cid.unique_process);
    if (pid == 0) return STATUS_INVALID_PARAMETER;
    const target = process.findProcess(pid) orelse return STATUS_INVALID_PARAMETER;
    if (!token.seProcessOpenAllowed(&proc.security_token, desired_access)) {
        @import("../se/audit.zig").logObjectOpenDenied("NtOpenProcess");
        return STATUS_ACCESS_DENIED;
    }
    if (!probe.probeUserMemory(asp, @intFromPtr(process_handle), @sizeOf(HANDLE), true))
        return STATUS_ACCESS_VIOLATION;
    const grant = desiredAccessToObMask(desired_access);
    const h = proc.handle_table.allocHandle(@intFromPtr(&target.header), grant, .process) orelse
        return STATUS_INSUFFICIENT_RESOURCES;
    process_handle.* = h;
    return STATUS_SUCCESS;
}

/// Ref: https://learn.microsoft.com/windows/win32/api/winternl/nf-winl-ntprotectvirtualmemory
pub fn NtProtectVirtualMemory(
    process_handle: HANDLE,
    base_address: *u64,
    region_size: *u64,
    new_protect: u32,
    old_protect: ?*u32,
) NTSTATUS {
    if (old_protect) |op| op.* = PAGE_READWRITE;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    const space = proc.address_space orelse return STATUS_NO_MEMORY;
    const base = base_address.*;
    const sz = region_size.*;
    if (sz == 0) return STATUS_INVALID_PARAMETER;
    if (!space.protectVirtualRange(base, sz, new_protect)) return STATUS_INVALID_PARAMETER;
    const paging = @import("../arch.zig").impl.paging;
    const ps: u64 = @intCast(paging.page_size);
    const mask = ps - 1;
    const r0 = base & ~mask;
    const r1 = (base + sz + mask) & ~mask;
    _ = space.vad.replaceSpanProtect(r0, r1, new_protect);
    return STATUS_SUCCESS;
}

/// 桩：真实锁定需与 Working Set / MDL 路径一致；当前返回成功（见 [NT61_VirtualMemory_ABI_Notes.md](../../docs/cn/NT61_VirtualMemory_ABI_Notes.md) 路线图）。
/// Ref: learn.microsoft.com `NtLockVirtualMemory`
pub fn NtLockVirtualMemory(
    process_handle: HANDLE,
    base_address: *u64,
    region_size: *u64,
    lock_flags: u32,
) NTSTATUS {
    _ = lock_flags;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    _ = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    _ = base_address.*;
    _ = region_size.*;
    return STATUS_SUCCESS;
}

/// 与 `NtLockVirtualMemory` 对称桩。
pub fn NtUnlockVirtualMemory(
    process_handle: HANDLE,
    base_address: *u64,
    region_size: *u64,
    lock_flags: u32,
) NTSTATUS {
    return NtLockVirtualMemory(process_handle, base_address, region_size, lock_flags);
}

/// `METHOD_BUFFERED` 子集：当前路由 `\Device\Rtc0` 打开句柄上的 `IOCTL_RTC_GET_TIME`（见 `drivers/timer/rtc.zig`）。
/// Ref: learn.microsoft.com `NtDeviceIoControlFile`
pub fn NtDeviceIoControlFile(
    file_handle: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    io_status: *IO_STATUS_BLOCK,
    ioctl_code: u32,
    input_buffer: ?*const anyopaque,
    input_length: u32,
    output_buffer: ?*anyopaque,
    output_length: u32,
) NTSTATUS {
    io_status.* = .{ .status = STATUS_INVALID_PARAMETER, .information = 0 };
    _ = input_buffer;
    _ = input_length;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(file_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse {
        io_status.status = STATUS_INVALID_HANDLE;
        return STATUS_INVALID_HANDLE;
    };
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    _ = @as(*vfs.FileObject, @ptrFromInt(ent.object_ptr));

    if (builtin.cpu.arch == .x86_64) {
        const rtc_mod = @import("../drivers/timer/rtc.zig");
        if (ioctl_code == rtc_mod.IOCTL_RTC_GET_TIME) {
            if (output_buffer == null or output_length < @sizeOf(u64)) {
                io_status.status = STATUS_BUFFER_TOO_SMALL;
                return STATUS_BUFFER_TOO_SMALL;
            }
            const asp = proc.address_space orelse return STATUS_INVALID_HANDLE;
            const out_va = @intFromPtr(output_buffer.?);
            if (!probe.probeUserMemory(asp, out_va, @sizeOf(u64), true)) return STATUS_ACCESS_VIOLATION;
            if (!rtc_mod.isInitialized()) {
                io_status.status = STATUS_INVALID_DEVICE_REQUEST;
                return STATUS_INVALID_DEVICE_REQUEST;
            }
            const t = rtc_mod.readTime();
            const rtc_packed: u64 = @as(u64, t.second) |
                (@as(u64, t.minute) << 8) |
                (@as(u64, t.hour) << 16) |
                (@as(u64, t.day) << 24) |
                (@as(u64, t.month) << 32) |
                (@as(u64, t.year) << 40);
            @as(*align(1) u64, @ptrFromInt(out_va)).* = rtc_packed;
            io_status.status = STATUS_SUCCESS;
            io_status.information = @sizeOf(u64);
            return STATUS_SUCCESS;
        }
    }
    io_status.status = STATUS_INVALID_DEVICE_REQUEST;
    return STATUS_INVALID_DEVICE_REQUEST;
}

/// `DelayInterval` 负值为相对 100ns；本内核用 `yield` 近似短延迟（HPET 精确睡眠见 [docs/cn/TimerPrecisionRoadmap.md](../../docs/cn/TimerPrecisionRoadmap.md)）。
/// **正数** 为绝对到期（NT `LARGE_INTEGER`）：当前无单调域换算，成功返回但不睡眠（与 PHASE_E 文档一致）。
/// Ref: https://learn.microsoft.com/windows/win32/api/winternl/nf-winl-ntdelayexecution
pub fn NtDelayExecution(alertable: u8, delay_interval: i64) NTSTATUS {
    _ = alertable;
    if (delay_interval >= 0) return STATUS_SUCCESS;
    const ns100: u64 = @intCast((@as(i128, 0) - @as(i128, delay_interval)));
    var yields: u32 = @truncate(ns100 / 10_000);
    if (yields > 256) yields = 256;
    var i: u32 = 0;
    while (i < yields) : (i += 1) {
        scheduler.yield();
    }
    return STATUS_SUCCESS;
}

// ── System Information ──

pub const SYSTEM_BASIC_INFO = extern struct {
    reserved: u32 = 0,
    timer_resolution: u32 = 100000,
    page_size: u32 = 4096,
    number_of_physical_pages: u32 = 65536,
    lowest_physical_page: u32 = 1,
    highest_physical_page: u32 = 65536,
    allocation_granularity: u32 = 65536,
    minimum_user_address: u64 = 0x10000,
    maximum_user_address: u64 = 0x7FFFFFFEFFFF,
    active_processors: u64 = 1,
    number_of_processors: u8 = 1,
    _pad: [7]u8 = .{0} ** 7,
};
comptime {
    std.debug.assert(@sizeOf(SYSTEM_BASIC_INFO) == 64);
}

/// `SYSTEM_PROCESSOR_INFORMATION` 公开字段子集（架构/级别）；完整 WDK 结构更大，调用方须按 `ReturnLength` 扩展。
pub const SYSTEM_PROCESSOR_INFORMATION_STUB = extern struct {
    processor_architecture: u16 = 0,
    processor_level: u16 = 0,
    processor_revision: u16 = 0,
    reserved: u16 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SYSTEM_PROCESSOR_INFORMATION_STUB) == 8);
}

/// Ref: WDK `SYSTEM_TIMEOFDAY_INFORMATION` 公开字段子集；本阶段填零，供 `ReturnLength` / 缓冲探测。
const SYSTEM_TIMEOFDAY_INFORMATION = extern struct {
    BootTime: i64 = 0,
    CurrentTime: i64 = 0,
    TimeZoneBias: i64 = 0,
    TimeZoneId: u32 = 0,
    Reserved: u32 = 0,
    BootTimeBias: u64 = 0,
    SleepTimeBias: u64 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SYSTEM_TIMEOFDAY_INFORMATION) == 48);
}

/// 单进程桩：与真实 Windows 布局**不完全**一致；`NextEntryOffset == 0` 表示枚举结束。
const SYSTEM_PROCESS_INFORMATION_STUB = extern struct {
    NextEntryOffset: u32 = 0,
    NumberOfThreads: u32 = 1,
    Reserved1: [48]u8 = [_]u8{0} ** 48,
    ImageName_Length: u16 = 0,
    ImageName_MaximumLength: u16 = 0,
    ImageName_Pad: u32 = 0,
    ImageName_Buffer: u64 = 0,
    BasePriority: i32 = 0,
    BasePriorityPad: u32 = 0,
    UniqueProcessId: u64 = 0,
    InheritedFromUniqueProcessId: u64 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SYSTEM_PROCESS_INFORMATION_STUB) == 96);
}

/// `SYSTEM_PERFORMANCE_INFORMATION` 过大；仅返回前 **128** 字节零填充（里程碑桩）。
const SYSTEM_PERFORMANCE_INFORMATION_PREFIX_BYTES: usize = 128;

/// `SystemVersionInformation` / `SystemBasicInformation` 与 [`config/os_version.zig`](../config/os_version.zig)、注册表 `CurrentBuildNumber`（`registry.populateDefaults`）共用 **build** 真源策略。
pub fn NtQuerySystemInformation(info_class: u32, buffer: []u8, return_length: *u32) NTSTATUS {
    const osv = @import("../config/os_version.zig");
    switch (info_class) {
        SystemBasicInformation => {
            const need = @sizeOf(SYSTEM_BASIC_INFO);
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            var sample = SYSTEM_BASIC_INFO{};
            if (builtin.cpu.arch == .x86_64) {
                const madt = @import("../hal/x86_64/madt.zig");
                const n = madt.logical_cpu_count;
                sample.number_of_processors = @truncate(@min(n, 255));
                sample.active_processors = n;
            }
            @memcpy(buffer[0..need], std.mem.asBytes(&sample));
            return STATUS_SUCCESS;
        },
        SystemProcessorInformation => {
            const need = @sizeOf(SYSTEM_PROCESSOR_INFORMATION_STUB);
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            var inf = SYSTEM_PROCESSOR_INFORMATION_STUB{
                .processor_architecture = switch (builtin.cpu.arch) {
                    .x86_64 => 9, // PROCESSOR_ARCHITECTURE_AMD64 (public winnt.h)
                    else => 0,
                },
                .processor_level = 6,
                .processor_revision = 0,
                .reserved = 0,
            };
            @memcpy(buffer[0..need], std.mem.asBytes(&inf));
            return STATUS_SUCCESS;
        },
        SystemTimeOfDayInformation => {
            const need = @sizeOf(SYSTEM_TIMEOFDAY_INFORMATION);
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            const z = SYSTEM_TIMEOFDAY_INFORMATION{};
            @memcpy(buffer[0..need], std.mem.asBytes(&z));
            return STATUS_SUCCESS;
        },
        SystemProcessInformation => {
            const need = @sizeOf(SYSTEM_PROCESS_INFORMATION_STUB);
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            var stub = SYSTEM_PROCESS_INFORMATION_STUB{};
            stub.UniqueProcessId = process.getCurrentPid();
            if (process.getCurrentProcess()) |cp| {
                stub.InheritedFromUniqueProcessId = cp.parent_pid;
            }
            @memcpy(buffer[0..need], std.mem.asBytes(&stub));
            return STATUS_SUCCESS;
        },
        SystemPerformanceInformation => {
            const need = SYSTEM_PERFORMANCE_INFORMATION_PREFIX_BYTES;
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            @memset(buffer[0..need], 0);
            return STATUS_SUCCESS;
        },
        SystemHandleInformation => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemInterruptInformation => {
            const need: u32 = 32;
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            @memset(buffer[0..need], 0);
            return STATUS_SUCCESS;
        },
        SystemExceptionInformation => {
            const need: u32 = 16;
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            @memset(buffer[0..need], 0);
            return STATUS_SUCCESS;
        },
        SystemModuleInformation => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemPoolTagInformation => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemVersionInformation => {
            return_length.* = osv.rtl_osversioninfoexw_bytes;
            if (buffer.len < osv.rtl_osversioninfoexw_bytes) {
                return STATUS_INFO_LENGTH_MISMATCH;
            }
            if (!osv.writeRtlOsVersionInfoExW(buffer)) return STATUS_INVALID_PARAMETER;
            return STATUS_SUCCESS;
        },
        else => {
            return_length.* = 0;
            return STATUS_INVALID_INFO_CLASS;
        },
    }
}

/// Ref: learn.microsoft.com `NtSetSystemInformation` — 本内核未实现可写系统策略；统一 `STATUS_NOT_IMPLEMENTED` 或非法 class。
pub fn NtSetSystemInformation(info_class: u32, _: ?*anyopaque, _: u32) NTSTATUS {
    if (info_class > 0xFFFF) return STATUS_INVALID_INFO_CLASS;
    return STATUS_NOT_IMPLEMENTED;
}

// ── Registry APIs ──

/// 从 `UNICODE_STRING` 抽出注册表 NT 路径字节：若为 UTF-16LE 且各 WCHAR 高字节为 0（ASCII 子集），压成窄路径；否则按窄字节路径原样使用（与历史桩一致）。
fn extractRegistryPathBytes(uname: *const UNICODE_STRING, out: *[512]u8) ?[]const u8 {
    if (uname.length == 0) return null;
    const raw = uname.buffer[0..uname.length];
    if (raw.len >= 2 and raw.len % 2 == 0) {
        var all_ascii_wchar = true;
        var w: usize = 0;
        while (w < raw.len / 2) : (w += 1) {
            if (raw[w * 2 + 1] != 0) {
                all_ascii_wchar = false;
                break;
            }
        }
        if (all_ascii_wchar) {
            const n = raw.len / 2;
            if (n > out.len) return null;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                out[j] = raw[j * 2];
            }
            return out[0..n];
        }
    }
    if (raw.len > out.len) return null;
    @memcpy(out[0..raw.len], raw);
    return out[0..raw.len];
}

pub fn NtOpenKey(key_handle: *HANDLE, desired_access: u32, object_attributes: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    _ = desired_access;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const attrs = object_attributes orelse return STATUS_INVALID_PARAMETER;
    const uname = attrs.object_name orelse return STATUS_INVALID_PARAMETER;
    if (uname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    var narrow_buf: [512]u8 = undefined;
    var redir_buf: [512]u8 = undefined;
    const narrow = extractRegistryPathBytes(uname, &narrow_buf) orelse return STATUS_INVALID_PARAMETER;
    const path_norm = ob.normalizeNtObjectPath(narrow);
    const path_open = wow64_redirect.applyWow64RegistryMachineSoftwarePath(proc.is_wow64, path_norm, &redir_buf) orelse path_norm;
    const idx = registry.openKeyByNtPath(path_open) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const hdr = registry.keyHeaderPtr(idx) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const mask = ob.GENERIC_READ;
    const h = proc.handle_table.allocHandle(@intFromPtr(hdr), mask, .key) orelse return STATUS_INSUFFICIENT_RESOURCES;
    key_handle.* = h;
    return STATUS_SUCCESS;
}

/// `REG_OPTION_*` / 事务句柄为路线图；`options==0` 时等价 `NtOpenKey`。
/// Ref: learn.microsoft.com `NtOpenKeyEx`
pub fn NtOpenKeyEx(key_handle: *HANDLE, desired_access: u32, object_attributes: ?*OBJECT_ATTRIBUTES, options: u32) NTSTATUS {
    if (options != 0) return STATUS_NOT_IMPLEMENTED;
    return NtOpenKey(key_handle, desired_access, object_attributes);
}

/// `TOKEN_INFORMATION_CLASS` 子集 — Ref: learn.microsoft.com `NtQueryInformationToken`。
pub const TokenSessionId: u32 = 12;
pub const TokenElevationType: u32 = 18;
pub const TokenElevation: u32 = 20;

const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: u32,
};
comptime {
    std.debug.assert(@sizeOf(TOKEN_ELEVATION) == 4);
}

var g_token_shadow: [8]token.Token = undefined;
var g_token_shadow_used: [8]bool = [_]bool{false} ** 8;

fn recycleTokenShadow(object_ptr: u64) void {
    var i: usize = 0;
    while (i < g_token_shadow.len) : (i += 1) {
        if (g_token_shadow_used[i] and @intFromPtr(&g_token_shadow[i].header) == object_ptr) {
            g_token_shadow[i] = .{};
            g_token_shadow_used[i] = false;
            return;
        }
    }
}

/// 进程令牌的浅拷贝句柄（静态槽位）；`NtClose` 回收槽位。
pub fn NtOpenProcessToken(process_handle: HANDLE, desired_access: u32, token_handle: *HANDLE) NTSTATUS {
    _ = desired_access;
    const target = resolveTargetProcess(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const asp = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    if (!probe.probeUserMemory(asp, @intFromPtr(token_handle), @sizeOf(HANDLE), true))
        return STATUS_ACCESS_VIOLATION;
    var i: usize = 0;
    while (i < g_token_shadow.len) : (i += 1) {
        if (!g_token_shadow_used[i]) {
            g_token_shadow_used[i] = true;
            g_token_shadow[i] = target.security_token;
            const h = proc.handle_table.allocHandle(
                @intFromPtr(&g_token_shadow[i].header),
                ob.GENERIC_READ | ob.SYNCHRONIZE,
                .token,
            ) orelse {
                g_token_shadow_used[i] = false;
                return STATUS_INSUFFICIENT_RESOURCES;
            };
            token_handle.* = h;
            return STATUS_SUCCESS;
        }
    }
    return STATUS_INSUFFICIENT_RESOURCES;
}

pub fn NtQueryInformationToken(
    token_handle: HANDLE,
    token_information_class: u32,
    token_information: ?*anyopaque,
    token_information_length: u32,
    return_length: ?*u32,
) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(token_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .token) return STATUS_INVALID_PARAMETER;
    const tok: *const token.Token = @ptrFromInt(ent.object_ptr);
    switch (token_information_class) {
        TokenSessionId => {
            if (return_length) |r| r.* = 4;
            if (token_information_length < 4) return STATUS_INFO_LENGTH_MISMATCH;
            const b = token_information orelse return STATUS_INVALID_PARAMETER;
            @as(*align(1) u32, @ptrCast(b)).* = tok.session_id;
            return STATUS_SUCCESS;
        },
        TokenElevationType => {
            if (return_length) |r| r.* = 4;
            if (token_information_length < 4) return STATUS_INFO_LENGTH_MISMATCH;
            const b = token_information orelse return STATUS_INVALID_PARAMETER;
            // TokenElevationTypeFull = 2, Default = 1（公开枚举值子集）
            @as(*align(1) u32, @ptrCast(b)).* = if (tok.is_elevated) 2 else 1;
            return STATUS_SUCCESS;
        },
        TokenElevation => {
            if (return_length) |r| r.* = @sizeOf(TOKEN_ELEVATION);
            if (token_information_length < @sizeOf(TOKEN_ELEVATION)) return STATUS_INFO_LENGTH_MISMATCH;
            const b = token_information orelse return STATUS_INVALID_PARAMETER;
            const out: *TOKEN_ELEVATION = @ptrCast(@alignCast(b));
            out.TokenIsElevated = if (tok.is_elevated) 1 else 0;
            return STATUS_SUCCESS;
        },
        else => {
            if (return_length) |r| r.* = 0;
            return STATUS_INVALID_INFO_CLASS;
        },
    }
}

fn queryValueKeyPartial(
    rk: *const registry.RegKey,
    value_name: ?*const UNICODE_STRING,
    key_value_information: ?*anyopaque,
    length: u32,
    result_length: *u32,
) NTSTATUS {
    const vname = value_name orelse return STATUS_INVALID_PARAMETER;
    if (vname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    const name_ascii = vname.buffer[0..vname.length];
    const val = rk.findValue(name_ascii) orelse return STATUS_OBJECT_NAME_NOT_FOUND;

    const data_len: u32 = val.data_len;
    const need: u32 = 12 + data_len;
    result_length.* = need;
    if (length < need) return STATUS_BUFFER_TOO_SMALL;
    const out: [*]u8 = @ptrCast(key_value_information orelse return STATUS_INVALID_PARAMETER);
    writeU32(out[0..4], 0);
    writeU32(out[4..8], @intFromEnum(val.value_type));
    writeU32(out[8..12], data_len);
    @memcpy(out[12..][0..data_len], val.data[0..data_len]);
    return STATUS_SUCCESS;
}

fn queryValueKeyFull(
    rk: *const registry.RegKey,
    value_name: ?*const UNICODE_STRING,
    key_value_information: ?*anyopaque,
    length: u32,
    result_length: *u32,
) NTSTATUS {
    const vname = value_name orelse return STATUS_INVALID_PARAMETER;
    if (vname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    const name_ascii = vname.buffer[0..vname.length];
    const val = rk.findValue(name_ascii) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const name = val.name[0..val.name_len];
    const name_off: u32 = 20;
    const after_name = name_off + @as(u32, @intCast(name.len));
    const data_off_u32: u32 = (after_name + 3) & ~@as(u32, 3);
    const data_len: u32 = val.data_len;
    const need = data_off_u32 + data_len;
    result_length.* = need;
    if (length < need) return STATUS_BUFFER_TOO_SMALL;
    const out: [*]u8 = @ptrCast(key_value_information orelse return STATUS_INVALID_PARAMETER);
    @memset(out[0..data_off_u32], 0);
    writeU32(out[0..4], 0);
    writeU32(out[4..8], @intFromEnum(val.value_type));
    writeU32(out[8..12], data_off_u32);
    writeU32(out[12..16], data_len);
    writeU32(out[16..20], @intCast(name.len));
    @memcpy(out[name_off..][0..name.len], name);
    if (data_off_u32 > name_off + name.len) {
        @memset(out[name_off + name.len .. data_off_u32], 0);
    }
    @memcpy(out[data_off_u32..][0..data_len], val.data[0..data_len]);
    return STATUS_SUCCESS;
}

/// Ref: `NtQueryValueKey` — `KEY_VALUE_INFORMATION_CLASS`, `ResultLength`.
pub fn NtQueryValueKey(
    key_handle: HANDLE,
    value_name: ?*const UNICODE_STRING,
    key_value_information_class: u32,
    key_value_information: ?*anyopaque,
    length: u32,
    result_length: *u32,
) NTSTATUS {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(key_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .key) return STATUS_INVALID_PARAMETER;
    const hdr: *ob.ObjectHeader = @ptrFromInt(ent.object_ptr);
    const rk = registry.regKeyFromHeader(hdr);
    return switch (key_value_information_class) {
        KeyValueFullInformation => queryValueKeyFull(rk, value_name, key_value_information, length, result_length),
        KeyValuePartialInformation => queryValueKeyPartial(rk, value_name, key_value_information, length, result_length),
        else => blk: {
            result_length.* = 0;
            break :blk STATUS_INVALID_INFO_CLASS;
        },
    };
}

/// `NtSetValueKey` — 窄字符 `UNICODE_STRING` 名（与 `NtOpenKey` 路径约定一致）；`REG_SZ` / `REG_DWORD`。
pub fn NtSetValueKey(
    key_handle: HANDLE,
    value_name: ?*const UNICODE_STRING,
    title_index: u32,
    reg_type: u32,
    data: []const u8,
) NTSTATUS {
    _ = title_index;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(key_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .key) return STATUS_INVALID_PARAMETER;
    const hdr: *ob.ObjectHeader = @ptrFromInt(ent.object_ptr);
    const idx = registry.keyIndexFromObjectHeader(hdr) orelse return STATUS_INVALID_PARAMETER;
    const vname = value_name orelse return STATUS_INVALID_PARAMETER;
    if (vname.length == 0) return STATUS_INVALID_PARAMETER;
    const nm = vname.buffer[0..vname.length];
    if (reg_type == REG_SZ) {
        return if (registry.setValueSz(idx, nm, data)) STATUS_SUCCESS else STATUS_INSUFFICIENT_RESOURCES;
    }
    if (reg_type == REG_DWORD and data.len >= 4) {
        const dv = std.mem.readInt(u32, data[0..4], .little);
        return if (registry.setValueDword(idx, nm, dv)) STATUS_SUCCESS else STATUS_INSUFFICIENT_RESOURCES;
    }
    return STATUS_INVALID_PARAMETER;
}

pub const REG_CREATED_NEW_KEY: u32 = 0x00000001;
pub const REG_OPENED_EXISTING_KEY: u32 = 0x00000002;

pub fn NtCreateKey(
    key_handle: ?*HANDLE,
    desired_access: u32,
    object_attributes: ?*OBJECT_ATTRIBUTES,
    title_index: u32,
    class: ?[]const u8,
    create_options: u32,
    disposition: ?*u32,
) NTSTATUS {
    _ = desired_access;
    _ = title_index;
    _ = class;
    _ = create_options;
    const kh = key_handle orelse return STATUS_INVALID_PARAMETER;
    const attrs = object_attributes orelse return STATUS_INVALID_PARAMETER;
    const uname = attrs.object_name orelse return STATUS_INVALID_PARAMETER;
    if (uname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    const proc_ck = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    var narrow_buf_ck: [512]u8 = undefined;
    var redir_buf_ck: [512]u8 = undefined;
    const narrow_ck = extractRegistryPathBytes(uname, &narrow_buf_ck) orelse return STATUS_INVALID_PARAMETER;
    const path_norm_ck = ob.normalizeNtObjectPath(narrow_ck);
    const path_open_ck = wow64_redirect.applyWow64RegistryMachineSoftwarePath(proc_ck.is_wow64, path_norm_ck, &redir_buf_ck) orelse path_norm_ck;
    const cr = registry.createKeyFromNtPath(path_open_ck) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    if (disposition) |d| d.* = if (cr.created) REG_CREATED_NEW_KEY else REG_OPENED_EXISTING_KEY;
    const hdr = registry.keyHeaderPtr(cr.idx) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const mask = ob.GENERIC_READ | ob.GENERIC_WRITE;
    const h = proc.handle_table.allocHandle(@intFromPtr(hdr), mask, .key) orelse return STATUS_INSUFFICIENT_RESOURCES;
    kh.* = h;
    return STATUS_SUCCESS;
}

pub fn NtEnumerateKey(
    key_handle: HANDLE,
    index: u32,
    key_information_class: u32,
    key_information: ?*anyopaque,
    length: u32,
    result_length: *u32,
) NTSTATUS {
    if (key_information_class != KeyBasicInformation) {
        result_length.* = 0;
        return STATUS_INVALID_INFO_CLASS;
    }
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(key_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .key) return STATUS_INVALID_PARAMETER;
    const hdr: *ob.ObjectHeader = @ptrFromInt(ent.object_ptr);
    const idx = registry.keyIndexFromObjectHeader(hdr) orelse return STATUS_INVALID_PARAMETER;
    const out = key_information orelse return STATUS_INVALID_PARAMETER;
    const buf: [*]u8 = @ptrCast(out);
    const st = registry.enumerateSubkeyBasic(idx, index, buf[0..length], result_length);
    return @intCast(st);
}

pub fn NtEnumerateValueKey(
    key_handle: HANDLE,
    index: u32,
    key_value_information_class: u32,
    key_value_information: ?*anyopaque,
    length: u32,
    result_length: *u32,
) NTSTATUS {
    if (key_value_information_class != KeyValueFullInformation) {
        result_length.* = 0;
        return STATUS_INVALID_INFO_CLASS;
    }
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const h: ob.Handle = @truncate(key_handle);
    const ent = proc.handle_table.lookupHandle(h) orelse return STATUS_INVALID_HANDLE;
    if (ent.obj_type != .key) return STATUS_INVALID_PARAMETER;
    const hdr: *ob.ObjectHeader = @ptrFromInt(ent.object_ptr);
    const idx = registry.keyIndexFromObjectHeader(hdr) orelse return STATUS_INVALID_PARAMETER;
    const out = key_value_information orelse return STATUS_INVALID_PARAMETER;
    const buf: [*]u8 = @ptrCast(out);
    const st = registry.enumerateValueFull(idx, index, buf[0..length], result_length);
    return @intCast(st);
}

// ── RTL Functions ──

pub fn RtlInitUnicodeString(dest: *UNICODE_STRING, src: []const u8) void {
    const copy_len = @min(src.len, dest.buffer.len);
    @memcpy(dest.buffer[0..copy_len], src[0..copy_len]);
    dest.length = @intCast(copy_len);
    dest.maximum_length = @intCast(dest.buffer.len);
}

pub fn RtlCopyMemory(dest: []u8, src: []const u8) void {
    const copy_len = @min(dest.len, src.len);
    @memcpy(dest[0..copy_len], src[0..copy_len]);
}

pub fn RtlZeroMemory(buf: []u8) void {
    @memset(buf, 0);
}

pub fn RtlFillMemory(buf: []u8, fill: u8) void {
    @memset(buf, fill);
}

pub fn RtlCompareMemory(buf1: []const u8, buf2: []const u8) usize {
    const len = @min(buf1.len, buf2.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (buf1[i] != buf2[i]) return i;
    }
    return len;
}

pub fn RtlMoveMemory(dest: []u8, src: []const u8) void {
    RtlCopyMemory(dest, src);
}

/// Matches Windows `RTL_OSVERSIONINFOW` (WCHAR CSD string).
pub const RTL_OSVERSIONINFOW = extern struct {
    os_version_info_size: u32,
    major_version: u32,
    minor_version: u32,
    build_number: u32,
    platform_id: u32,
    csd_version: [128]u16,
};

/// Ref: learn.microsoft.com `OSVERSIONINFOEXW` — 与 `os_version.rtl_osversioninfoexw_bytes`（284）一致。
pub const OSVERSIONINFOEXW = extern struct {
    dwOSVersionInfoSize: u32,
    dwMajorVersion: u32,
    dwMinorVersion: u32,
    dwBuildNumber: u32,
    dwPlatformId: u32,
    szCSDVersion: [128]u16,
    wServicePackMajor: u16,
    wServicePackMinor: u16,
    wSuiteMask: u16,
    wProductType: u8,
    wReserved: u8,
};
comptime {
    std.debug.assert(@sizeOf(OSVERSIONINFOEXW) == 284);
}

pub fn RtlGetVersion(info: *RTL_OSVERSIONINFOW) NTSTATUS {
    const osv = @import("../config/os_version.zig");
    if (info.os_version_info_size < 20) return STATUS_INVALID_PARAMETER;

    if (info.os_version_info_size >= osv.rtl_osversioninfoexw_bytes) {
        const raw: [*]u8 = @ptrCast(info);
        if (!osv.writeRtlOsVersionInfoExW(raw[0..osv.rtl_osversioninfoexw_bytes])) {
            return STATUS_INVALID_PARAMETER;
        }
        return STATUS_SUCCESS;
    }

    if (info.os_version_info_size < @sizeOf(RTL_OSVERSIONINFOW)) return STATUS_INVALID_PARAMETER;

    info.os_version_info_size = @intCast(@sizeOf(RTL_OSVERSIONINFOW));
    info.major_version = osv.major();
    info.minor_version = osv.minor();
    info.build_number = osv.buildNumber();
    info.platform_id = osv.platformId();
    @memset(@as([*]u8, @ptrCast(&info.csd_version))[0 .. 128 * @sizeOf(u16)], 0);
    const csd = osv.csdVersionAscii();
    var i: usize = 0;
    while (i < csd.len and i < 128) : (i += 1) {
        info.csd_version[i] = csd[i];
    }
    return STATUS_SUCCESS;
}

/// Ref: https://learn.microsoft.com/windows/win32/devnotes/rtlverifyversioninfo
pub fn RtlVerifyVersionInfo(
    version_info: *const OSVERSIONINFOEXW,
    type_mask: u32,
    condition_mask: u64,
) NTSTATUS {
    if (version_info.dwOSVersionInfoSize < @sizeOf(OSVERSIONINFOEXW)) return STATUS_INVALID_PARAMETER;
    const osv = @import("../config/os_version.zig");
    return osv.rtlVerifyVersionInfo(
        version_info.dwMajorVersion,
        version_info.dwMinorVersion,
        version_info.dwBuildNumber,
        version_info.dwPlatformId,
        version_info.wServicePackMajor,
        version_info.wProductType,
        type_mask,
        condition_mask,
    );
}

pub fn RtlNtStatusToDosError(status: NTSTATUS) u32 {
    return switch (status) {
        STATUS_SUCCESS => 0,
        STATUS_INVALID_PARAMETER => 87,
        STATUS_ACCESS_DENIED => 5,
        STATUS_NO_MEMORY => 8,
        STATUS_OBJECT_NAME_NOT_FOUND => 2,
        STATUS_NOT_IMPLEMENTED => 120,
        STATUS_BUFFER_TOO_SMALL => 122,
        STATUS_INFO_LENGTH_MISMATCH => 24,
        STATUS_END_OF_FILE => 38,
        STATUS_INVALID_HANDLE => 6,
        STATUS_INVALID_INFO_CLASS => 87,
        STATUS_INSUFFICIENT_RESOURCES => 8,
        STATUS_NOT_EQUAL => 317,
        else => 317,
    };
}

/// Same mapping as `RtlNtStatusToWin32Error` (Win32 name).
pub const RtlNtStatusToWin32Error = RtlNtStatusToDosError;

pub fn RtlGetCurrentPeb() u64 {
    return 0;
}

// ── 加载器 / 线程启动桩（`LdrInitializeThunk` → 用户进程；与 NT 6.1 文档链对齐，行为简化）──
// Ref: https://learn.microsoft.com/windows/win32/api/libloaderapi/

pub fn LdrInitializeThunk() void {
    if (klog.DEBUG_MODE) {
        klog.debug("LdrInitializeThunk: stub", .{});
    }
}

pub fn LdrLoadDll(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn LdrGetProcedureAddress(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

/// 用户线程入口包装（真实系统经 SEH 调线程过程；此处为 Zig 内核内联桩）。
pub fn RtlUserThreadStart(_: u64, _: u64) noreturn {
    while (true) {}
}

// ── Debug APIs ──

pub fn DbgPrint(message: []const u8) NTSTATUS {
    klog.debug("DbgPrint: %s", .{message});
    return STATUS_SUCCESS;
}

pub fn DbgBreakPoint() void {
    if (klog.DEBUG_MODE) {
        klog.debug("DbgBreakPoint: Breakpoint triggered", .{});
    }
}

fn writeU32(buf: []u8, value: u32) void {
    if (buf.len < 4) return;
    buf[0] = @intCast(value & 0xFF);
    buf[1] = @intCast((value >> 8) & 0xFF);
    buf[2] = @intCast((value >> 16) & 0xFF);
    buf[3] = @intCast((value >> 24) & 0xFF);
}

pub fn init() void {
    klog.info("ntdll: Native API runtime initialized", .{});
    klog.info("ntdll: Process APIs: NtCreateProcess, NtTerminateProcess, NtQueryInformationProcess", .{});
    klog.info("ntdll: Thread APIs: NtCreateThread, NtTerminateThread", .{});
    klog.info("ntdll: File APIs: NtCreateFile, NtOpenFile, NtReadFile, NtWriteFile, NtClose", .{});
    klog.info("ntdll: Sync APIs: NtCreateEvent, NtCreateMutant, NtWaitForSingleObject", .{});
    klog.info("ntdll: Memory APIs: NtAllocateVirtualMemory, NtFreeVirtualMemory, NtCreateSection", .{});
    klog.info("ntdll: IPC APIs: NtCreatePort, NtConnectPort, NtRequestWaitReplyPort", .{});
    klog.info("ntdll: System APIs: NtQuerySystemInformation (incl. SystemVersionInformation), NtQueryVirtualMemory", .{});
    klog.info("ntdll: Registry: NtOpenKey/NtCreateKey/NtSetValueKey/NtEnumerate* + NtQueryValueKey (Partial/Full)", .{});
    klog.info("ntdll: RTL: RtlGetVersion, RtlVerifyVersionInfo, RtlNtStatusToDosError / RtlNtStatusToWin32Error, memory utils", .{});
    klog.info("ntdll: Debug: DbgPrint, DbgBreakPoint", .{});
    klog.info("ntdll: Loader stubs: LdrInitializeThunk, LdrLoadDll, RtlUserThreadStart", .{});
}
