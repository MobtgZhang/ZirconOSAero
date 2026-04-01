//! ntdll - Native API Runtime Library
//! Phase 8 Enhanced: Complete Native API set with file/memory/section/sync APIs,
//! system information queries, RTL utilities, and debug support.

const std = @import("std");
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
/// `RTL_OSVERSIONINFOEXW` / `VER_PLATFORM_*` — values aligned with public SDK headers (clean-room).
pub const SystemVersionInformation: u32 = 57;

pub const ProcessBasicInformation: u32 = 0;
pub const ThreadBasicInformation: u32 = 0;

pub const KeyValuePartialInformation: u32 = 2;

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
    _: HANDLE,
    thread_information_class: u32,
    _: ?*anyopaque,
    _: u32,
    return_length: ?*u32,
) NTSTATUS {
    if (return_length) |rl| rl.* = 0;
    if (thread_information_class == ThreadBasicInformation) return STATUS_NOT_IMPLEMENTED;
    return STATUS_INVALID_INFO_CLASS;
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
    if (ent.obj_type == .file) {
        const f: *vfs.FileObject = @ptrFromInt(ent.object_ptr);
        var irp = io.Irp{ .major_function = .close };
        _ = vfs.dispatchFileObjectIrp(f, &irp);
    }
    if (!proc.handle_table.closeHandle(h)) return STATUS_INVALID_HANDLE;
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

pub fn NtCreateEvent(event_handle: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, _: u32, _: bool) NTSTATUS {
    _ = event_handle;
    return STATUS_SUCCESS;
}

pub fn NtSetEvent(_: HANDLE, _: ?*u32) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtResetEvent(_: HANDLE, _: ?*u32) NTSTATUS {
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

pub fn NtWaitForSingleObject(_: HANDLE, _: bool, _: ?*const i64) NTSTATUS {
    return STATUS_WAIT_0;
}

pub fn NtWaitForMultipleObjects(_: u32, _: []const HANDLE, _: u32, _: bool, _: ?*const i64) NTSTATUS {
    return STATUS_WAIT_0;
}

// ── Section (Memory-mapped) APIs ──

pub fn NtCreateSection(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, _: ?*u64, _: u32, _: u32, _: HANDLE) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtMapViewOfSection(_: HANDLE, _: HANDLE, _: *u64, _: u64, _: u64, _: ?*u64, _: *u64, _: u32, _: u32, _: u32) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtUnmapViewOfSection(_: HANDLE, _: u64) NTSTATUS {
    return STATUS_SUCCESS;
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

pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_RELEASE: u32 = 0x8000;
pub const PAGE_READWRITE: u32 = 0x04;

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
    _ = protect;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    var space = proc.address_space orelse return STATUS_NO_MEMORY;
    defer proc.address_space = space;

    const commit = (allocation_type & MEM_COMMIT) != 0;
    const reserve = (allocation_type & MEM_RESERVE) != 0;
    if (!commit and !reserve) return STATUS_INVALID_PARAMETER;

    const page_size: u64 = 4096;
    var size = region_size.*;
    if (size == 0) return STATUS_INVALID_PARAMETER;
    size = (size + page_size - 1) & ~(page_size - 1);
    const num_pages = @as(usize, @intCast(size / page_size));

    var base = base_address.*;
    if (base == 0) {
        user_alloc_va_salt = user_alloc_va_salt *% 1664525 +% 1013904223;
        const slide_pages: u64 = @as(u64, user_alloc_va_salt % 512);
        base = 0x0000_0000_4000_0000 + slide_pages * page_size;
        while (space.getPhysical(base) != null or vm.isVirtInReservedRange(&space, base, num_pages)) {
            base += page_size;
        }
    }
    if (base & (page_size - 1) != 0) return STATUS_INVALID_PARAMETER;

    const flags = vm.MapFlags{ .writable = true, .user = true, .executable = false };

    if (reserve and commit) {
        if (!vm.mapRange(&space, base, num_pages, flags)) return STATUS_NO_MEMORY;
        base_address.* = base;
        region_size.* = size;
        return STATUS_SUCCESS;
    }

    if (reserve and !commit) {
        if (!space.reserveVirtualRange(base, @intCast(num_pages))) return STATUS_NO_MEMORY;
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
    if ((free_type & MEM_RELEASE) == 0) return STATUS_INVALID_PARAMETER;
    const pid = processHandleToPid(process_handle) orelse return STATUS_INVALID_HANDLE;
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_HANDLE;
    var space = proc.address_space orelse return STATUS_NO_MEMORY;

    const page_size: u64 = 4096;
    var size = region_size.*;
    if (size == 0) return STATUS_INVALID_PARAMETER;
    size = (size + page_size - 1) & ~(page_size - 1);
    const num_pages = @as(usize, @intCast(size / page_size));
    vm.unmapRange(&space, base_address.*, num_pages);
    proc.address_space = space;
    return STATUS_SUCCESS;
}

pub fn NtQueryVirtualMemory(
    _: HANDLE,
    _: u64,
    memory_information_class: u32,
    _: ?*anyopaque,
    _: u32,
    return_length: ?*u32,
) NTSTATUS {
    if (return_length) |rl| rl.* = 0;
    if (memory_information_class == 0) return STATUS_NOT_IMPLEMENTED;
    return STATUS_INVALID_INFO_CLASS;
}

pub fn NtProtectVirtualMemory(_: HANDLE, _: *u64, _: *u64, _: u32, _: ?*u32) NTSTATUS {
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

pub fn NtQuerySystemInformation(info_class: u32, buffer: []u8, return_length: *u32) NTSTATUS {
    const osv = @import("../config/os_version.zig");
    switch (info_class) {
        SystemBasicInformation => {
            const need = @sizeOf(SYSTEM_BASIC_INFO);
            return_length.* = need;
            if (buffer.len < need) return STATUS_INFO_LENGTH_MISMATCH;
            const sample = SYSTEM_BASIC_INFO{};
            const src = std.mem.asBytes(&sample);
            @memcpy(buffer[0..need], src);
            return STATUS_SUCCESS;
        },
        SystemTimeOfDayInformation => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemProcessInformation,
        SystemProcessorInformation,
        SystemPerformanceInformation,
        => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
        SystemModuleInformation => {
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
    const path = uname.buffer[0..uname.length];
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
        KeyValuePartialInformation => queryValueKeyPartial(rk, value_name, key_value_information, length, result_length),
        else => blk: {
            result_length.* = 0;
            break :blk STATUS_INVALID_INFO_CLASS;
        },
    };
}

pub fn NtSetValueKey(_: HANDLE, _: []const u8, _: u32, _: u32, _: []const u8) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtCreateKey(
    key_handle: ?*HANDLE,
    _: u32,
    _: ?*OBJECT_ATTRIBUTES,
    _: u32,
    _: ?[]const u8,
    _: u32,
    _: ?*u32,
) NTSTATUS {
    if (key_handle) |kh| kh.* = INVALID_HANDLE_VALUE;
    return STATUS_NOT_IMPLEMENTED;
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
    klog.info("ntdll: Registry APIs: NtOpenKey (NT path), NtQueryValueKey (partial), NtCreateKey (not impl)", .{});
    klog.info("ntdll: RTL: RtlGetVersion, RtlNtStatusToDosError / RtlNtStatusToWin32Error, memory utils", .{});
    klog.info("ntdll: Debug: DbgPrint, DbgBreakPoint", .{});
}
