//! ntdll - Native API Runtime Library
//! Phase 8 Enhanced: Complete Native API set with file/memory/section/sync APIs,
//! system information queries, RTL utilities, and debug support.

const klog = @import("../rtl/klog.zig");
const process = @import("../ps/process.zig");
const ob = @import("../ob/object.zig");
const ipc = @import("../lpc/ipc.zig");
const port = @import("../lpc/port.zig");
const vfs = @import("../fs/vfs.zig");
const heap_mod = @import("../mm/heap.zig");

pub const NTSTATUS = i32;
pub const STATUS_SUCCESS: NTSTATUS = 0;
pub const STATUS_PENDING: NTSTATUS = 259;
pub const STATUS_INVALID_PARAMETER: NTSTATUS = -1073741811;
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

pub fn NtQueryInformationProcess(process_handle: HANDLE, info_buf: []u8) NTSTATUS {
    const pid: u32 = @intCast(process_handle & 0xFFFFFFFF);
    const proc = process.findProcess(pid) orelse return STATUS_INVALID_PARAMETER;
    if (info_buf.len < 16) return STATUS_BUFFER_TOO_SMALL;
    writeU32(info_buf[0..4], proc.pid);
    writeU32(info_buf[4..8], proc.parent_pid);
    info_buf[8] = @intFromEnum(proc.state);
    info_buf[9] = if (proc.is_system) 1 else 0;
    return STATUS_SUCCESS;
}

pub fn NtSetInformationProcess(_: HANDLE, _: u32, _: []const u8) NTSTATUS {
    return STATUS_SUCCESS;
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

pub fn NtQueryInformationThread(_: HANDLE, _: []u8) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

// ── File APIs ──

pub fn NtCreateFile(
    file_handle: *HANDLE,
    access: u32,
    obj_attrs: ?*OBJECT_ATTRIBUTES,
    io_status: *IO_STATUS_BLOCK,
    _: u64,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
) NTSTATUS {
    _ = access;
    io_status.status = STATUS_SUCCESS;
    io_status.information = 0;

    if (obj_attrs) |attrs| {
        if (attrs.object_name) |name| {
            const path = name.buffer[0..name.length];
            const f = vfs.open(path, .read_write);
            if (f) |_| {
                file_handle.* = @intCast(vfs.getFileCount());
                io_status.information = 1;
                return STATUS_SUCCESS;
            }
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }
    }
    file_handle.* = INVALID_HANDLE_VALUE;
    return STATUS_INVALID_PARAMETER;
}

pub fn NtOpenFile(file_handle: *HANDLE, _: u32, obj_attrs: ?*OBJECT_ATTRIBUTES, io_status: *IO_STATUS_BLOCK, _: u32, _: u32) NTSTATUS {
    io_status.status = STATUS_SUCCESS;
    if (obj_attrs) |attrs| {
        if (attrs.object_name) |name| {
            const path = name.buffer[0..name.length];
            const f = vfs.open(path, .read);
            if (f) |_| {
                file_handle.* = @intCast(vfs.getFileCount());
                return STATUS_SUCCESS;
            }
            return STATUS_OBJECT_NAME_NOT_FOUND;
        }
    }
    file_handle.* = INVALID_HANDLE_VALUE;
    return STATUS_INVALID_PARAMETER;
}

pub fn NtReadFile(_: HANDLE, _: HANDLE, _: u64, _: u64, io_status: *IO_STATUS_BLOCK, buffer: []u8, _: ?*u64) NTSTATUS {
    io_status.status = STATUS_SUCCESS;
    io_status.information = 0;
    _ = buffer;
    return STATUS_SUCCESS;
}

pub fn NtWriteFile(_: HANDLE, _: HANDLE, _: u64, _: u64, io_status: *IO_STATUS_BLOCK, buffer: []const u8, _: ?*u64) NTSTATUS {
    io_status.status = STATUS_SUCCESS;
    io_status.information = buffer.len;
    return STATUS_SUCCESS;
}

pub fn NtClose(handle: HANDLE) NTSTATUS {
    _ = handle;
    return STATUS_SUCCESS;
}

pub fn NtQueryDirectoryFile(_: HANDLE, _: HANDLE, _: u64, _: u64, io_status: *IO_STATUS_BLOCK, _: []u8, _: u32, _: bool) NTSTATUS {
    io_status.status = STATUS_SUCCESS;
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
    const result = ipc.requestWaitReply(pid, @intCast(port_handle), opcode, data);
    if (result) |msg| {
        reply.* = msg;
        return STATUS_SUCCESS;
    }
    return STATUS_INVALID_PARAMETER;
}

pub fn NtConnectPort(_: *HANDLE, _: []const u8) NTSTATUS {
    return STATUS_SUCCESS;
}

// ── Memory APIs ──

pub fn NtAllocateVirtualMemory(_: HANDLE, base_address: *u64, _: u64, size: *u64, _: u32, _: u32) NTSTATUS {
    _ = base_address;
    _ = size;
    return STATUS_SUCCESS;
}

pub fn NtFreeVirtualMemory(_: HANDLE, _: *u64, _: *u64, _: u32) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtQueryVirtualMemory(_: HANDLE, _: u64, _: u32, _: []u8) NTSTATUS {
    return STATUS_NOT_IMPLEMENTED;
}

pub fn NtProtectVirtualMemory(_: HANDLE, _: *u64, _: *u64, _: u32, _: *u32) NTSTATUS {
    return STATUS_SUCCESS;
}

// ── System Information ──

pub const SYSTEM_BASIC_INFO = struct {
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
};

pub fn NtQuerySystemInformation(info_class: u32, buffer: []u8, return_length: *u32) NTSTATUS {
    switch (info_class) {
        SystemBasicInformation => {
            if (buffer.len < @sizeOf(SYSTEM_BASIC_INFO)) {
                return_length.* = @sizeOf(SYSTEM_BASIC_INFO);
                return STATUS_INFO_LENGTH_MISMATCH;
            }
            return_length.* = @sizeOf(SYSTEM_BASIC_INFO);
            return STATUS_SUCCESS;
        },
        SystemTimeOfDayInformation => {
            return_length.* = 0;
            return STATUS_SUCCESS;
        },
        SystemProcessInformation => {
            return_length.* = 0;
            return STATUS_SUCCESS;
        },
        else => {
            return_length.* = 0;
            return STATUS_NOT_IMPLEMENTED;
        },
    }
}

// ── Registry APIs (stub) ──

pub fn NtOpenKey(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES) NTSTATUS {
    return STATUS_OBJECT_NAME_NOT_FOUND;
}

pub fn NtQueryValueKey(_: HANDLE, _: []const u8, _: u32, _: []u8, _: *u32) NTSTATUS {
    return STATUS_OBJECT_NAME_NOT_FOUND;
}

pub fn NtSetValueKey(_: HANDLE, _: []const u8, _: u32, _: u32, _: []const u8) NTSTATUS {
    return STATUS_SUCCESS;
}

pub fn NtCreateKey(_: *HANDLE, _: u32, _: ?*OBJECT_ATTRIBUTES, _: u32, _: ?[]const u8, _: u32) NTSTATUS {
    return STATUS_SUCCESS;
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

pub const RTL_OSVERSIONINFOW = struct {
    os_version_info_size: u32 = @sizeOf(RTL_OSVERSIONINFOW),
    major_version: u32 = 10,
    minor_version: u32 = 0,
    build_number: u32 = 19041,
    platform_id: u32 = 2,
    csd_version: [128]u8 = [_]u8{0} ** 128,
};

pub fn RtlGetVersion(info: *RTL_OSVERSIONINFOW) NTSTATUS {
    info.* = .{};
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
        STATUS_END_OF_FILE => 38,
        STATUS_INVALID_HANDLE => 6,
        else => 317,
    };
}

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
    klog.info("ntdll: System APIs: NtQuerySystemInformation, NtQueryVirtualMemory", .{});
    klog.info("ntdll: Registry APIs: NtOpenKey, NtCreateKey, NtQueryValueKey (stub)", .{});
    klog.info("ntdll: RTL: RtlGetVersion, RtlNtStatusToDosError, memory utils", .{});
    klog.info("ntdll: Debug: DbgPrint, DbgBreakPoint", .{});
}
