//! ntdll - Native API Runtime Library
//! Phase 8 Enhanced: Complete Native API set with file/memory/section/sync APIs,
//! system information queries, RTL utilities, and debug support.

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
pub const STATUS_INFO_LENGTH_MISMATCH: NTSTATUS = -1073741820;
/// 0xC0000003 — invalid `SYSTEM_INFORMATION_CLASS` / info class.
pub const STATUS_INVALID_INFO_CLASS: NTSTATUS = -1073741821;
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

pub const ProcessBasicInformation: u32 = 0;
/// Ref: learn.microsoft.com — `PROCESSINFOCLASS` / `ProcessSessionInformation`.
pub const ProcessSessionInformation: u32 = 24;
pub const ThreadBasicInformation: u32 = 0;

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

fn allocEventObject(initial_state: bool) ?u64 {
    var i: usize = 0;
    while (i < MAX_KERNEL_EVENTS) : (i += 1) {
        if (!g_event_used[i]) {
            g_event_used[i] = true;
            g_event_objs[i] = .{
                .obj_type = .event,
                .ref_count = 0,
                .handle_count = 0,
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
            if (hdr.ref_count == 0 and hdr.handle_count == 0) {
                hdr.* = .{};
                g_event_used[i] = false;
            }
            return;
        }
    }
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

fn desiredAccessToObMask(access: u32) ob.ACCESS_MASK {
    var m: ob.ACCESS_MASK = 0;
    if ((access & 0x80000000) != 0) m |= ob.GENERIC_READ;
    if ((access & 0x40000000) != 0) m |= ob.GENERIC_WRITE;
    if ((access & 0x20000000) != 0) m |= ob.GENERIC_EXECUTE;
    if ((access & 0x10000000) != 0) m |= ob.GENERIC_ALL;
    if (m == 0) m = ob.GENERIC_READ | ob.GENERIC_WRITE;
    return m;
}

fn ioStatusFromVfsIo(s: io.IoStatus) NTSTATUS {
    return switch (s) {
        .success => STATUS_SUCCESS,
        .not_found => STATUS_OBJECT_NAME_NOT_FOUND,
        .access_denied => STATUS_ACCESS_DENIED,
        .buffer_overflow => STATUS_BUFFER_TOO_SMALL,
        .end_of_file => STATUS_END_OF_FILE,
        .not_implemented => STATUS_NOT_IMPLEMENTED,
        else => STATUS_INVALID_PARAMETER,
    };
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
    var frame_alloc: alloc.FrameAllocator = undefined;
    const p = process.createProcess(&frame_alloc);
    if (p) |proc| {
        process_handle.* = proc.pid;
        klog.debug("ntdll: NtCreateProcess -> PID=%u", .{proc.pid});
        return STATUS_SUCCESS;
    }
    return STATUS_NO_MEMORY;
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
    const pid: u32 = @intCast(process_handle & 0xFFFFFFFF);
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_PARAMETER;

    switch (process_information_class) {
        ProcessBasicInformation => {
            const need: u32 = @intCast(@sizeOf(PROCESS_BASIC_INFORMATION));
            if (return_length) |rl| rl.* = need;
            if (process_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
            const buf = process_information orelse return STATUS_INVALID_PARAMETER;
            const out: *PROCESS_BASIC_INFORMATION = @ptrCast(@alignCast(buf));
            out.exit_status = 0;
            out._pad0 = 0;
            out.peb_base_address = 0;
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
        else => {
            if (return_length) |rl| rl.* = 0;
            return STATUS_INVALID_INFO_CLASS;
        },
    }
}

pub fn NtSetInformationProcess(_: HANDLE, process_information_class: u32, _: ?*const anyopaque, _: u32) NTSTATUS {
    if (process_information_class == 0) return STATUS_SUCCESS;
    return STATUS_NOT_IMPLEMENTED;
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

pub fn NtQueryInformationThread(
    thread_handle: HANDLE,
    thread_information_class: u32,
    thread_information: ?*anyopaque,
    thread_information_length: u32,
    return_length: ?*u32,
) NTSTATUS {
    if (thread_information_class != ThreadBasicInformation) {
        if (return_length) |rl| rl.* = 0;
        return STATUS_INVALID_INFO_CLASS;
    }
    const need: u32 = @intCast(@sizeOf(THREAD_BASIC_INFORMATION));
    if (return_length) |rl| rl.* = need;
    if (thread_information_length < need) return STATUS_INFO_LENGTH_MISMATCH;
    const buf = thread_information orelse return STATUS_INVALID_PARAMETER;
    const out: *THREAD_BASIC_INFORMATION = @ptrCast(@alignCast(buf));
    out.exit_status = STATUS_SUCCESS;
    out._pad0 = 0;
    out.teb_base_address = 0;
    out.client_id_unique_process = process.getCurrentPid();
    out.client_id_unique_thread = thread_handle;
    out.affinity_mask = 1;
    out.priority = 0;
    out.base_priority = 0;
    return STATUS_SUCCESS;
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
    _ = share_access;
    _ = create_disposition;
    _ = create_options;
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
            const path = name.buffer[0..name.length];
            const f = vfs.open(path, .read_write) orelse {
                io_status.status = STATUS_OBJECT_NAME_NOT_FOUND;
                return STATUS_OBJECT_NAME_NOT_FOUND;
            };
            const h = proc.handle_table.allocHandle(@intFromPtr(f), want, .file) orelse {
                _ = vfs.close(f);
                io_status.status = STATUS_INSUFFICIENT_RESOURCES;
                return STATUS_INSUFFICIENT_RESOURCES;
            };
            file_handle.* = h;
            io_status.information = 1; // FILE_CREATED / FILE_OPENED — simplified
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
    _ = share_access;
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
            const path = name.buffer[0..name.length];
            const f = vfs.open(path, .read) orelse {
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
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
    const buf = buffer orelse return STATUS_INVALID_PARAMETER;
    var irp = io.Irp{
        .major_function = .read,
        .buffer_ptr = @intFromPtr(buf),
        .buffer_size = length,
    };
    _ = vfs.dispatchFileObjectIrp(f, &irp);
    io_status.status = ioStatusFromVfsIo(irp.status);
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
    if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
    const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
    const buf = buffer orelse return STATUS_INVALID_PARAMETER;
    var irp = io.Irp{
        .major_function = .write,
        .buffer_ptr = @intFromPtr(buf),
        .buffer_size = length,
    };
    _ = vfs.dispatchFileObjectIrp(f, &irp);
    io_status.status = ioStatusFromVfsIo(irp.status);
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
    return STATUS_SUCCESS;
}

pub fn NtQueryDirectoryFile(
    _: HANDLE,
    _: HANDLE,
    _: u64,
    _: u64,
    io_status: *IO_STATUS_BLOCK,
    _: ?*anyopaque,
    _: u32,
    _: u32,
    _: ?*u32,
    _: bool,
) NTSTATUS {
    io_status.status = STATUS_NOT_IMPLEMENTED;
    io_status.information = 0;
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtDeleteFile(_: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_SUCCESS;
}

// ── Object APIs ──

pub const NOTIFICATION_EVENT: u32 = 0;
pub const SYNCHRONIZATION_EVENT: u32 = 1;
pub const DUPLICATE_SAME_ACCESS: u32 = 0x00000002;

pub fn NtCreateEvent(
    event_handle: *HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    event_type: u32,
    initial_state: bool,
) NTSTATUS {
    _ = event_type; // 当前仅实现手动复位语义；自动复位在 `NtWaitForSingleObject` 成功返回时可扩展清零。
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const ptr = allocEventObject(initial_state) orelse return STATUS_NO_MEMORY;
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

pub fn NtCreateMutant(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, _: bool) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtReleaseMutant(_: HANDLE, _: ?*u32) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtCreateSemaphore(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, _: i32, _: i32) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtReleaseSemaphore(_: HANDLE, _: i32, _: ?*i32) NTSTATUS {
    return STATUS_SUCCESS;
}

/// 将 `timeout` 100ns 单位粗算为调度 tick 增量（简化：非精确 wall-clock，与 `scheduler.getTicks` 对齐）。
fn timeout100nsToExtraTicks(v_100ns: u64) u64 {
    // 约每 1ms ≈ 10_000 × 100ns；每 tick 视作 ~1ms 量级（取决于 HPET/定时器配置）。
    const per_tick = 10_000 * 1000;
    return @max(1, v_100ns / per_tick);
}

pub fn NtWaitForSingleObject(handle: HANDLE, alertable: bool, timeout: ?*const i64) NTSTATUS {
    _ = alertable;
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
            while (true) {
                if (hdr.signal_state) return STATUS_WAIT_0;
                if (deadline) |d| {
                    if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
                }
                scheduler.yield();
            }
        },
        else => return STATUS_WAIT_0,
    }
}

pub fn NtWaitForMultipleObjects(_: u32, _: []const HANDLE, _: u32, _: bool, _: ?*const i64) NTSTATUS {
    return STATUS_WAIT_0;
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
        if ((allocation_attributes & SEC_IMAGE) != 0) return STATUS_NOT_IMPLEMENTED;
        const plain_write = (page_protect & 0x44) != 0;
        const is_cow = (page_protect & 0x88) != 0;
        if (plain_write and !is_cow) return STATUS_NOT_IMPLEMENTED;
        const fh: ob.Handle = @truncate(file_handle);
        const ent = proc.handle_table.lookupHandle(fh) orelse return STATUS_INVALID_HANDLE;
        if (ent.obj_type != .file) return STATUS_INVALID_PARAMETER;
        const fo = @as(*vfs.FileObject, @ptrFromInt(ent.object_ptr));
        const sec = section_mm.createFileBackedSection(max_sz, page_protect, fo) orelse return STATUS_NO_MEMORY;
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

    const nh = proc.handle_table.duplicateHandle(sh, grant) orelse return STATUS_INSUFFICIENT_RESOURCES;
    target_handle.* = nh;
    return STATUS_SUCCESS;
}

pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_DECOMMIT: u32 = 0x4000;
pub const MEM_RELEASE: u32 = 0x8000;
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

/// 桩：syscall 表对齐 Win7 SP1 x64；完整打开语义见进程管理路线图。
pub fn NtOpenProcess(
    process_handle: *HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    _: ?*const anyopaque,
) NTSTATUS {
    process_handle.* = INVALID_HANDLE_VALUE;
    return STATUS_NOT_IMPLEMENTED;
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

/// `DelayInterval` 负值为相对 100ns；本内核用 `yield` 近似短延迟（HPET 精确睡眠为路线图）。
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
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemProcessInformation,
        SystemPerformanceInformation,
        => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
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

// ── Registry APIs ──

pub fn NtOpenKey(key_handle: *HANDLE, desired_access: u32, object_attributes: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    _ = desired_access;
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_HANDLE;
    const attrs = object_attributes orelse return STATUS_INVALID_PARAMETER;
    const uname = attrs.object_name orelse return STATUS_INVALID_PARAMETER;
    if (uname.length == 0) return STATUS_OBJECT_NAME_NOT_FOUND;
    const raw = uname.buffer[0..uname.length];
    const path = ob.normalizeNtObjectPath(raw);
    const idx = registry.openKeyByNtPath(path) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const hdr = registry.keyHeaderPtr(idx) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
    const mask = ob.GENERIC_READ;
    const h = proc.handle_table.allocHandle(@intFromPtr(hdr), mask, .key) orelse return STATUS_INSUFFICIENT_RESOURCES;
    key_handle.* = h;
    return STATUS_SUCCESS;
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
    const raw = uname.buffer[0..uname.length];
    const path = ob.normalizeNtObjectPath(raw);
    const cr = registry.createKeyFromNtPath(path) orelse return STATUS_OBJECT_NAME_NOT_FOUND;
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
    klog.info("ntdll: RTL: RtlGetVersion, RtlNtStatusToDosError / RtlNtStatusToWin32Error, memory utils", .{});
    klog.info("ntdll: Debug: DbgPrint, DbgBreakPoint", .{});
    klog.info("ntdll: Loader stubs: LdrInitializeThunk, LdrLoadDll, RtlUserThreadStart", .{});
}
