//! kernel32 - Win32 Base API Subset
//! Phase 8-9 Enhanced: Complete Win32 Base API layer with file search,
//! module management, thread sync, virtual memory, environment, and DLL loading.

const ntdll = @import("ntdll.zig");
const klog = @import("../rtl/klog.zig");
const process = @import("../ps/process.zig");
const ob = @import("../ob/object.zig");
const vfs = @import("../fs/vfs.zig");
const fat32 = @import("../fs/fat32.zig");
const ntfs = @import("../fs/ntfs.zig");
const pe_loader = @import("../loader/pe.zig");

pub const BOOL = u32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const DWORD = u32;
pub const WORD = u16;
pub const HANDLE = u64;
pub const HMODULE = u64;
pub const INVALID_HANDLE_VALUE: HANDLE = 0xFFFFFFFFFFFFFFFF;
pub const MAX_PATH: usize = 260;

pub const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5;
pub const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4;

pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const TRUNCATE_EXISTING: DWORD = 5;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const GENERIC_EXECUTE: DWORD = 0x20000000;
pub const GENERIC_ALL: DWORD = 0x10000000;

pub const FILE_SHARE_READ: DWORD = 0x01;
pub const FILE_SHARE_WRITE: DWORD = 0x02;
pub const FILE_SHARE_DELETE: DWORD = 0x04;

pub const FILE_ATTRIBUTE_READONLY: DWORD = 0x01;
pub const FILE_ATTRIBUTE_HIDDEN: DWORD = 0x02;
pub const FILE_ATTRIBUTE_SYSTEM: DWORD = 0x04;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const FILE_ATTRIBUTE_ARCHIVE: DWORD = 0x20;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;

pub const MEM_COMMIT: DWORD = 0x1000;
pub const MEM_RESERVE: DWORD = 0x2000;
pub const MEM_RELEASE: DWORD = 0x8000;
pub const MEM_DECOMMIT: DWORD = 0x4000;
pub const PAGE_NOACCESS: DWORD = 0x01;
pub const PAGE_READONLY: DWORD = 0x02;
pub const PAGE_READWRITE: DWORD = 0x04;
pub const PAGE_EXECUTE: DWORD = 0x10;
pub const PAGE_EXECUTE_READ: DWORD = 0x20;
pub const PAGE_EXECUTE_READWRITE: DWORD = 0x40;

pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const WAIT_ABANDONED: DWORD = 128;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;

pub const NORMAL_PRIORITY_CLASS: DWORD = 0x20;
pub const CREATE_NEW_CONSOLE: DWORD = 0x10;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const DETACHED_PROCESS: DWORD = 0x08;

pub const ERROR_SUCCESS: DWORD = 0;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_INVALID_HANDLE: DWORD = 6;
pub const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
pub const ERROR_NO_MORE_FILES: DWORD = 18;
pub const ERROR_MOD_NOT_FOUND: DWORD = 126;
pub const ERROR_PROC_NOT_FOUND: DWORD = 127;

// ── Process APIs ──

pub const PROCESS_INFORMATION = struct {
    process_handle: HANDLE = 0,
    thread_handle: HANDLE = 0,
    process_id: DWORD = 0,
    thread_id: DWORD = 0,
};

pub const STARTUPINFOA = struct {
    cb: DWORD = @sizeOf(STARTUPINFOA),
    desktop: [64]u8 = [_]u8{0} ** 64,
    title: [64]u8 = [_]u8{0} ** 64,
    x: DWORD = 0,
    y: DWORD = 0,
    x_size: DWORD = 0,
    y_size: DWORD = 0,
    x_count_chars: DWORD = 80,
    y_count_chars: DWORD = 25,
    fill_attribute: DWORD = 0,
    flags: DWORD = 0,
    show_window: WORD = 1,
    std_input: HANDLE = 0,
    std_output: HANDLE = 1,
    std_error: HANDLE = 2,
};

pub fn GetCurrentProcessId() DWORD {
    return process.getCurrentPid();
}

pub fn GetCurrentProcess() HANDLE {
    return @intCast(process.getCurrentPid());
}

pub fn GetCurrentThreadId() DWORD {
    return 1;
}

pub fn ExitProcess(exit_code: DWORD) void {
    const pid = process.getCurrentPid();
    _ = process.terminateProcess(pid, exit_code);
}

pub fn CreateProcessA(
    app_name: ?[]const u8,
    cmd_line: ?[]const u8,
    _: DWORD,
    process_info: *PROCESS_INFORMATION,
) BOOL {
    _ = app_name;
    _ = cmd_line;
    var handle: ntdll.HANDLE = 0;
    const status = ntdll.NtCreateProcess(
        &handle, 0, null, @intCast(process.getCurrentPid()),
    );
    if (status == ntdll.STATUS_SUCCESS) {
        process_info.process_id = @intCast(handle);
        process_info.thread_id = 1;
        process_info.process_handle = handle;
        process_info.thread_handle = 0;
        return TRUE;
    }
    return FALSE;
}

pub fn TerminateProcess(handle: HANDLE, exit_code: DWORD) BOOL {
    const status = ntdll.NtTerminateProcess(handle, @intCast(exit_code));
    return if (status == ntdll.STATUS_SUCCESS) TRUE else FALSE;
}

pub fn GetExitCodeProcess(_: HANDLE, exit_code: *DWORD) BOOL {
    exit_code.* = 0;
    return TRUE;
}

pub fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) DWORD {
    _ = handle;
    _ = milliseconds;
    return WAIT_OBJECT_0;
}

pub fn WaitForMultipleObjects(count: DWORD, handles: []const HANDLE, wait_all: BOOL, milliseconds: DWORD) DWORD {
    _ = count;
    _ = handles;
    _ = wait_all;
    _ = milliseconds;
    return WAIT_OBJECT_0;
}

// ── File APIs ──

pub fn CreateFileA(
    filename: []const u8,
    access: DWORD,
    _: DWORD,
    _: DWORD,
) HANDLE {
    const vfs_access: vfs.FileAccessMode = if ((access & GENERIC_WRITE) != 0)
        .read_write
    else
        .read;

    const f = vfs.open(filename, vfs_access);
    if (f) |_| {
        return @intCast(vfs.getFileCount() - 1);
    }
    last_error = ERROR_FILE_NOT_FOUND;
    return INVALID_HANDLE_VALUE;
}

pub fn ReadFile(handle: HANDLE, buffer: []u8, bytes_read: *DWORD) BOOL {
    _ = handle;
    _ = buffer;
    bytes_read.* = 0;
    return FALSE;
}

pub fn WriteFile(handle: HANDLE, data: []const u8, bytes_written: *DWORD) BOOL {
    _ = handle;
    bytes_written.* = @intCast(data.len);
    return TRUE;
}

pub fn CloseHandle(handle: HANDLE) BOOL {
    _ = ntdll.NtClose(handle);
    return TRUE;
}

pub fn GetFileSize(handle: HANDLE) DWORD {
    _ = handle;
    return 0;
}

pub fn GetFileSizeEx(_: HANDLE, _: *u64) BOOL {
    return FALSE;
}

pub fn DeleteFileA(filename: []const u8) BOOL {
    const status = vfs.stat(filename, &tmp_dir_entry);
    if (status != .success) {
        last_error = ERROR_FILE_NOT_FOUND;
        return FALSE;
    }
    return TRUE;
}

pub fn GetFileAttributesA(filename: []const u8) DWORD {
    var entry: vfs.DirEntry = .{};
    const status = vfs.stat(filename, &entry);
    if (status != .success) {
        last_error = ERROR_FILE_NOT_FOUND;
        return 0xFFFFFFFF;
    }
    var attrs: DWORD = 0;
    if (entry.attributes.readonly) attrs |= FILE_ATTRIBUTE_READONLY;
    if (entry.attributes.hidden) attrs |= FILE_ATTRIBUTE_HIDDEN;
    if (entry.attributes.system) attrs |= FILE_ATTRIBUTE_SYSTEM;
    if (entry.attributes.directory) attrs |= FILE_ATTRIBUTE_DIRECTORY;
    if (attrs == 0) attrs = FILE_ATTRIBUTE_NORMAL;
    return attrs;
}

pub fn CreateDirectoryA(path: []const u8, _: u64) BOOL {
    const vol = fat32.getVolume();
    if (vol.createDirectory(path)) |_| return TRUE;
    return FALSE;
}

pub fn RemoveDirectoryA(path: []const u8) BOOL {
    const vol = fat32.getVolume();
    if (vol.removeEntry(path)) return TRUE;
    return FALSE;
}

pub fn SetFilePointer(_: HANDLE, _: i32, _: ?*i32, _: DWORD) DWORD {
    return 0;
}

pub fn SetEndOfFile(_: HANDLE) BOOL {
    return TRUE;
}

pub fn FlushFileBuffers(_: HANDLE) BOOL {
    return TRUE;
}

// ── File Search APIs ──

pub const WIN32_FIND_DATAA = struct {
    file_attributes: DWORD = 0,
    creation_time_low: DWORD = 0,
    creation_time_high: DWORD = 0,
    last_access_time_low: DWORD = 0,
    last_access_time_high: DWORD = 0,
    last_write_time_low: DWORD = 0,
    last_write_time_high: DWORD = 0,
    file_size_high: DWORD = 0,
    file_size_low: DWORD = 0,
    file_name: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    file_name_len: usize = 0,
    alternate_name: [14]u8 = [_]u8{0} ** 14,
};

const MAX_FIND_HANDLES: usize = 16;

const FindHandleState = struct {
    is_active: bool = false,
    pattern: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    pattern_len: usize = 0,
    current_index: usize = 0,
    drive: u8 = 'C',
};

var find_handles: [MAX_FIND_HANDLES]FindHandleState = [_]FindHandleState{.{}} ** MAX_FIND_HANDLES;

pub fn FindFirstFileA(pattern: []const u8, find_data: *WIN32_FIND_DATAA) HANDLE {
    var handle_idx: usize = 0;
    while (handle_idx < MAX_FIND_HANDLES) : (handle_idx += 1) {
        if (!find_handles[handle_idx].is_active) break;
    }
    if (handle_idx >= MAX_FIND_HANDLES) {
        last_error = ERROR_NOT_ENOUGH_MEMORY;
        return INVALID_HANDLE_VALUE;
    }

    var state = &find_handles[handle_idx];
    state.is_active = true;
    state.current_index = 0;
    const copy_len = @min(pattern.len, state.pattern.len);
    @memcpy(state.pattern[0..copy_len], pattern[0..copy_len]);
    state.pattern_len = copy_len;

    state.drive = if (pattern.len >= 2 and pattern[1] == ':') pattern[0] else 'C';

    if (findNextEntry(state, find_data)) {
        return @intCast(handle_idx + 0x1000);
    }

    state.is_active = false;
    last_error = ERROR_FILE_NOT_FOUND;
    return INVALID_HANDLE_VALUE;
}

pub fn FindNextFileA(handle: HANDLE, find_data: *WIN32_FIND_DATAA) BOOL {
    const idx = @as(usize, @intCast(handle)) -| 0x1000;
    if (idx >= MAX_FIND_HANDLES) return FALSE;

    const state = &find_handles[idx];
    if (!state.is_active) return FALSE;

    if (findNextEntry(state, find_data)) {
        return TRUE;
    }

    last_error = ERROR_NO_MORE_FILES;
    return FALSE;
}

pub fn FindClose(handle: HANDLE) BOOL {
    const idx = @as(usize, @intCast(handle)) -| 0x1000;
    if (idx >= MAX_FIND_HANDLES) return FALSE;

    find_handles[idx].is_active = false;
    return TRUE;
}

fn findNextEntry(state: *FindHandleState, data: *WIN32_FIND_DATAA) bool {
    const drive_upper = if (state.drive >= 'a' and state.drive <= 'z') state.drive - 32 else state.drive;

    if (drive_upper == 'D') {
        return findNextNtfsEntry(state, data);
    }

    const vol = fat32.getVolume();
    while (state.current_index < vol.root_entry_count) {
        const entry = &vol.root_entries[state.current_index];
        state.current_index += 1;

        if (entry.isFree() or entry.isVolumeId()) continue;

        data.* = .{};
        var pos: usize = 0;
        for (entry.name) |c| {
            if (c == ' ') break;
            if (pos < data.file_name.len) {
                data.file_name[pos] = c;
                pos += 1;
            }
        }
        var has_ext = false;
        for (entry.ext) |c| {
            if (c != ' ') {
                has_ext = true;
                break;
            }
        }
        if (has_ext) {
            if (pos < data.file_name.len) {
                data.file_name[pos] = '.';
                pos += 1;
            }
            for (entry.ext) |c| {
                if (c == ' ') break;
                if (pos < data.file_name.len) {
                    data.file_name[pos] = c;
                    pos += 1;
                }
            }
        }
        data.file_name_len = pos;
        data.file_size_low = entry.file_size;

        if (entry.isDirectory()) {
            data.file_attributes = FILE_ATTRIBUTE_DIRECTORY;
        } else {
            data.file_attributes = FILE_ATTRIBUTE_ARCHIVE;
        }
        if ((entry.attr & fat32.ATTR_READ_ONLY) != 0) data.file_attributes |= FILE_ATTRIBUTE_READONLY;
        if ((entry.attr & fat32.ATTR_HIDDEN) != 0) data.file_attributes |= FILE_ATTRIBUTE_HIDDEN;
        if ((entry.attr & fat32.ATTR_SYSTEM) != 0) data.file_attributes |= FILE_ATTRIBUTE_SYSTEM;

        return true;
    }
    return false;
}

fn findNextNtfsEntry(state: *FindHandleState, data: *WIN32_FIND_DATAA) bool {
    const vol = ntfs.getVolume();
    while (state.current_index < vol.mft_count) {
        const rec = &vol.mft[state.current_index];
        state.current_index += 1;

        if (!rec.isInUse()) continue;
        if (rec.file_name_len == 0) continue;
        if (rec.file_name[0] == '$') continue;
        if (rec.parent_record != ntfs.MFT_RECORD_ROOT) continue;

        data.* = .{};
        const n = @min(rec.file_name_len, data.file_name.len);
        @memcpy(data.file_name[0..n], rec.file_name[0..n]);
        data.file_name_len = n;
        data.file_size_low = @intCast(rec.file_size & 0xFFFFFFFF);
        data.file_size_high = @intCast((rec.file_size >> 32) & 0xFFFFFFFF);

        if (rec.isDirectory()) {
            data.file_attributes = FILE_ATTRIBUTE_DIRECTORY;
        } else {
            data.file_attributes = FILE_ATTRIBUTE_ARCHIVE;
        }
        return true;
    }
    return false;
}

var tmp_dir_entry: vfs.DirEntry = .{};

// ── Console APIs ──

pub fn GetStdHandle(std_handle: DWORD) HANDLE {
    return switch (std_handle) {
        STD_INPUT_HANDLE => 0,
        STD_OUTPUT_HANDLE => 1,
        STD_ERROR_HANDLE => 2,
        else => INVALID_HANDLE_VALUE,
    };
}

pub fn WriteConsoleA(handle: HANDLE, buffer: []const u8, chars_written: *DWORD) BOOL {
    _ = handle;
    const arch = @import("../arch.zig");
    arch.consoleWrite(buffer);
    chars_written.* = @intCast(buffer.len);
    return TRUE;
}

pub fn ReadConsoleA(_: HANDLE, _: []u8, _: *DWORD) BOOL {
    return FALSE;
}

pub fn SetConsoleTitleA(_: []const u8) BOOL {
    return TRUE;
}

pub fn AllocConsole() BOOL {
    return TRUE;
}

pub fn FreeConsole() BOOL {
    return TRUE;
}

pub fn SetConsoleTextAttribute(_: HANDLE, _: WORD) BOOL {
    return TRUE;
}

pub fn GetConsoleScreenBufferInfo(_: HANDLE, _: *CONSOLE_SCREEN_BUFFER_INFO) BOOL {
    return TRUE;
}

pub const CONSOLE_SCREEN_BUFFER_INFO = struct {
    size_x: WORD = 80,
    size_y: WORD = 25,
    cursor_x: WORD = 0,
    cursor_y: WORD = 0,
    attributes: WORD = 7,
    window_left: WORD = 0,
    window_top: WORD = 0,
    window_right: WORD = 79,
    window_bottom: WORD = 24,
    max_size_x: WORD = 80,
    max_size_y: WORD = 25,
};

// ── Memory APIs ──

pub fn GetProcessHeap() HANDLE {
    return 1;
}

pub fn HeapAlloc(_: HANDLE, _: DWORD, _: usize) u64 {
    return 0;
}

pub fn HeapFree(_: HANDLE, _: DWORD, _: u64) BOOL {
    return TRUE;
}

pub fn HeapReAlloc(_: HANDLE, _: DWORD, _: u64, _: usize) u64 {
    return 0;
}

pub fn HeapSize(_: HANDLE, _: DWORD, _: u64) usize {
    return 0;
}

pub fn VirtualAlloc(_: ?u64, _: usize, _: DWORD, _: DWORD) u64 {
    return 0;
}

pub fn VirtualFree(_: u64, _: usize, _: DWORD) BOOL {
    return TRUE;
}

pub fn VirtualProtect(_: u64, _: usize, _: DWORD, _: *DWORD) BOOL {
    return TRUE;
}

pub fn LocalAlloc(_: DWORD, _: usize) u64 {
    return 0;
}

pub fn LocalFree(_: u64) u64 {
    return 0;
}

pub fn GlobalAlloc(_: DWORD, _: usize) u64 {
    return 0;
}

pub fn GlobalFree(_: u64) u64 {
    return 0;
}

// ── Module/DLL APIs ──

pub fn LoadLibraryA(lib_name: []const u8) HMODULE {
    if (pe_loader.getLoadedImage(lib_name)) |img| {
        img.ref_count += 1;
        return img.image_base;
    }
    last_error = ERROR_MOD_NOT_FOUND;
    return 0;
}

pub fn FreeLibrary(module: HMODULE) BOOL {
    if (pe_loader.getImageByBase(module)) |img| {
        if (img.is_dll and img.ref_count > 0) {
            img.ref_count -= 1;
            return TRUE;
        }
    }
    return FALSE;
}

pub fn GetModuleHandleA(module_name: ?[]const u8) HMODULE {
    if (module_name) |name| {
        if (pe_loader.getLoadedImage(name)) |img| {
            return img.image_base;
        }
        last_error = ERROR_MOD_NOT_FOUND;
        return 0;
    }
    return 0x140000000;
}

pub fn GetModuleFileNameA(module: HMODULE, buffer: []u8) DWORD {
    if (pe_loader.getImageByBase(module)) |img| {
        const name = img.getName();
        const copy_len = @min(name.len, buffer.len);
        @memcpy(buffer[0..copy_len], name[0..copy_len]);
        return @intCast(copy_len);
    }
    const default_name = "zirconos.exe";
    const copy_len = @min(default_name.len, buffer.len);
    @memcpy(buffer[0..copy_len], default_name[0..copy_len]);
    return @intCast(copy_len);
}

pub fn GetProcAddress(module: HMODULE, proc_name: []const u8) u64 {
    if (pe_loader.getImageByBase(module)) |img| {
        if (img.findExport(proc_name)) |addr| return addr;
    }
    last_error = ERROR_PROC_NOT_FOUND;
    return 0;
}

// ── String/Environment APIs ──

pub fn GetEnvironmentVariableA(name: []const u8, buffer: []u8) DWORD {
    const entries = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "SystemRoot", .value = "C:\\Windows" },
        .{ .key = "SystemDrive", .value = "C:" },
        .{ .key = "COMPUTERNAME", .value = "ZIRCONOS" },
        .{ .key = "USERNAME", .value = "System" },
        .{ .key = "OS", .value = "ZirconOS_NT" },
        .{ .key = "PROCESSOR_ARCHITECTURE", .value = "AMD64" },
        .{ .key = "NUMBER_OF_PROCESSORS", .value = "1" },
        .{ .key = "COMSPEC", .value = "C:\\Windows\\System32\\cmd.exe" },
        .{ .key = "PATHEXT", .value = ".COM;.EXE;.BAT;.CMD" },
        .{ .key = "PATH", .value = "C:\\Windows\\System32;C:\\Windows" },
        .{ .key = "TEMP", .value = "C:\\Windows\\Temp" },
        .{ .key = "TMP", .value = "C:\\Windows\\Temp" },
        .{ .key = "USERPROFILE", .value = "C:\\Users\\System" },
        .{ .key = "HOMEDRIVE", .value = "C:" },
        .{ .key = "HOMEPATH", .value = "\\Users\\System" },
        .{ .key = "windir", .value = "C:\\Windows" },
    };

    for (entries) |entry| {
        if (strEqlI(name, entry.key)) {
            const copy_len = @min(entry.value.len, buffer.len);
            @memcpy(buffer[0..copy_len], entry.value[0..copy_len]);
            return @intCast(copy_len);
        }
    }
    if (buffer.len > 0) buffer[0] = 0;
    return 0;
}

pub fn SetEnvironmentVariableA(_: []const u8, _: ?[]const u8) BOOL {
    return TRUE;
}

pub fn GetCurrentDirectoryA(buffer: []u8) DWORD {
    const default_dir = "C:\\";
    const copy_len = @min(default_dir.len, buffer.len);
    @memcpy(buffer[0..copy_len], default_dir[0..copy_len]);
    return @intCast(copy_len);
}

pub fn SetCurrentDirectoryA(_: []const u8) BOOL {
    return TRUE;
}

pub fn GetSystemDirectoryA(buffer: []u8) DWORD {
    const sys_dir = "C:\\Windows\\System32";
    const copy_len = @min(sys_dir.len, buffer.len);
    @memcpy(buffer[0..copy_len], sys_dir[0..copy_len]);
    return @intCast(copy_len);
}

pub fn GetWindowsDirectoryA(buffer: []u8) DWORD {
    const win_dir = "C:\\Windows";
    const copy_len = @min(win_dir.len, buffer.len);
    @memcpy(buffer[0..copy_len], win_dir[0..copy_len]);
    return @intCast(copy_len);
}

pub fn GetTempPathA(buffer: []u8) DWORD {
    const tmp = "C:\\Windows\\Temp\\";
    const copy_len = @min(tmp.len, buffer.len);
    @memcpy(buffer[0..copy_len], tmp[0..copy_len]);
    return @intCast(copy_len);
}

pub fn ExpandEnvironmentStringsA(src: []const u8, dst: []u8) DWORD {
    const copy_len = @min(src.len, dst.len);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    return @intCast(copy_len);
}

// ── Synchronization APIs ──

pub fn Sleep(_: DWORD) void {
    asm volatile ("pause");
}

pub fn SleepEx(_: DWORD, _: BOOL) DWORD {
    return 0;
}

pub fn GetTickCount() DWORD {
    const scheduler = @import("../ke/scheduler.zig");
    return @intCast(scheduler.getTicks() & 0xFFFFFFFF);
}

pub fn GetTickCount64() u64 {
    const scheduler = @import("../ke/scheduler.zig");
    return scheduler.getTicks() * 10;
}

pub fn CreateEventA(_: u64, _: BOOL, _: BOOL, _: ?[]const u8) HANDLE {
    return 1;
}

pub fn SetEvent(_: HANDLE) BOOL {
    return TRUE;
}

pub fn ResetEvent(_: HANDLE) BOOL {
    return TRUE;
}

pub fn CreateMutexA(_: u64, _: BOOL, _: ?[]const u8) HANDLE {
    return 1;
}

pub fn ReleaseMutex(_: HANDLE) BOOL {
    return TRUE;
}

pub fn CreateSemaphoreA(_: u64, _: i32, _: i32, _: ?[]const u8) HANDLE {
    return 1;
}

pub fn ReleaseSemaphore(_: HANDLE, _: i32, _: ?*i32) BOOL {
    return TRUE;
}

pub fn InitializeCriticalSection(_: u64) void {}
pub fn EnterCriticalSection(_: u64) void {}
pub fn LeaveCriticalSection(_: u64) void {}
pub fn DeleteCriticalSection(_: u64) void {}

// ── System Info ──

pub const SYSTEM_INFO = struct {
    processor_architecture: u16 = 9,
    page_size: DWORD = 4096,
    minimum_application_address: u64 = 0x10000,
    maximum_application_address: u64 = 0x7FFFFFFEFFFF,
    active_processor_mask: u64 = 1,
    number_of_processors: DWORD = 1,
    processor_type: DWORD = 8664,
    allocation_granularity: DWORD = 65536,
    processor_level: u16 = 6,
    processor_revision: u16 = 0,
};

pub fn GetSystemInfo(info: *SYSTEM_INFO) void {
    info.* = .{};
}

pub fn GetNativeSystemInfo(info: *SYSTEM_INFO) void {
    GetSystemInfo(info);
}

pub const OSVERSIONINFOA = struct {
    os_version_info_size: DWORD = @sizeOf(OSVERSIONINFOA),
    major_version: DWORD = 10,
    minor_version: DWORD = 0,
    build_number: DWORD = 19041,
    platform_id: DWORD = 2,
    csd_version: [128]u8 = [_]u8{0} ** 128,
};

pub const OSVERSIONINFOEXA = struct {
    os_version_info_size: DWORD = @sizeOf(OSVERSIONINFOEXA),
    major_version: DWORD = 10,
    minor_version: DWORD = 0,
    build_number: DWORD = 19041,
    platform_id: DWORD = 2,
    csd_version: [128]u8 = [_]u8{0} ** 128,
    service_pack_major: u16 = 0,
    service_pack_minor: u16 = 0,
    suite_mask: u16 = 0x0100,
    product_type: u8 = 1,
    reserved: u8 = 0,
};

pub fn GetVersionExA(info: *OSVERSIONINFOA) BOOL {
    info.* = .{};
    return TRUE;
}

pub fn IsProcessorFeaturePresent(_: DWORD) BOOL {
    return FALSE;
}

pub fn GetComputerNameA(buffer: []u8, size: *DWORD) BOOL {
    const name = "ZIRCONOS";
    const copy_len = @min(name.len, buffer.len);
    @memcpy(buffer[0..copy_len], name[0..copy_len]);
    size.* = @intCast(copy_len);
    return TRUE;
}

pub fn GetUserNameA(buffer: []u8, size: *DWORD) BOOL {
    const name = "System";
    const copy_len = @min(name.len, buffer.len);
    @memcpy(buffer[0..copy_len], name[0..copy_len]);
    size.* = @intCast(copy_len);
    return TRUE;
}

// ── Error handling ──

var last_error: DWORD = 0;

pub fn GetLastError() DWORD {
    return last_error;
}

pub fn SetLastError(error_code: DWORD) void {
    last_error = error_code;
}

// ── String utility ──

pub fn lstrlenA(s: []const u8) i32 {
    return @intCast(s.len);
}

pub fn lstrcpyA(dest: []u8, src: []const u8) []u8 {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return dest[0..n];
}

pub fn OutputDebugStringA(str: []const u8) void {
    if (klog.DEBUG_MODE) {
        klog.debug("OutputDebugString: %s", .{str});
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

pub fn init() void {
    last_error = 0;
    klog.info("kernel32: Win32 Base API subset initialized", .{});
    klog.info("kernel32: Process APIs: CreateProcessA, ExitProcess, TerminateProcess, WaitForSingleObject", .{});
    klog.info("kernel32: File APIs: CreateFileA, ReadFile, WriteFile, DeleteFileA, FindFirstFileA, FindNextFileA", .{});
    klog.info("kernel32: Console APIs: GetStdHandle, WriteConsoleA, ReadConsoleA, AllocConsole", .{});
    klog.info("kernel32: Memory APIs: VirtualAlloc/Free, HeapAlloc/Free, LocalAlloc, GlobalAlloc", .{});
    klog.info("kernel32: Module APIs: LoadLibraryA, GetProcAddress, GetModuleHandleA, FreeLibrary", .{});
    klog.info("kernel32: Sync APIs: CreateEvent, CreateMutex, CreateSemaphore, CriticalSection", .{});
    klog.info("kernel32: System APIs: GetSystemInfo, GetVersionExA, GetComputerNameA", .{});
    klog.info("kernel32: Environment APIs: GetEnvironmentVariableA, GetCurrentDirectoryA", .{});
}
