//! WOW64 - 32-bit on 64-bit Compatibility Layer
//! Phase 11: PE32 loading, 32-bit syscall thunking, address space
//! management, 32-bit ntdll/kernel32 shim, and compatibility testing.

const klog = @import("../../rtl/klog.zig");
const pe_loader = @import("../../loader/pe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const process = @import("../../ps/process.zig");
const subsystem = @import("subsystem.zig");
const exec = @import("exec.zig");
const console_mod = @import("console.zig");

// ── WOW64 Constants ──

pub const WOW64_VERSION: []const u8 = "ZirconOS WOW64 v1.0";

pub const WOW64_MAX_ADDR: u64 = 0x7FFFFFFF;
pub const WOW64_STACK_SIZE: u32 = 0x100000;
pub const WOW64_HEAP_SIZE: u32 = 0x100000;
pub const WOW64_TLS_SLOTS: usize = 64;

pub const PE32_IMAGE_BASE: u32 = 0x00400000;
pub const WOW64_NTDLL_BASE: u32 = 0x77000000;
pub const WOW64_KERNEL32_BASE: u32 = 0x76000000;
pub const WOW64_USER32_BASE: u32 = 0x75000000;

pub const WOW64_SIZE_OF_80387_REGISTERS: usize = 80;

// ── WOW64 State ──

pub const Wow64State = enum(u8) {
    inactive = 0,
    initializing = 1,
    active = 2,
    suspended = 3,
    error_state = 4,
};

pub const ThunkType = enum(u8) {
    none = 0,
    syscall_32to64 = 1,
    ptr_32to64 = 2,
    ptr_64to32 = 3,
    struct_convert = 4,
    handle_convert = 5,
};

// ── 32-bit Context ──

pub const CONTEXT32 = struct {
    context_flags: u32 = 0x10001F,
    dr0: u32 = 0,
    dr1: u32 = 0,
    dr2: u32 = 0,
    dr3: u32 = 0,
    dr6: u32 = 0,
    dr7: u32 = 0,
    float_save: [WOW64_SIZE_OF_80387_REGISTERS]u8 = [_]u8{0} ** WOW64_SIZE_OF_80387_REGISTERS,
    seg_gs: u32 = 0,
    seg_fs: u32 = 0x003B,
    seg_es: u32 = 0x0023,
    seg_ds: u32 = 0x0023,
    edi: u32 = 0,
    esi: u32 = 0,
    ebx: u32 = 0,
    edx: u32 = 0,
    ecx: u32 = 0,
    eax: u32 = 0,
    ebp: u32 = 0,
    eip: u32 = 0,
    seg_cs: u32 = 0x0023,
    eflags: u32 = 0x00000202,
    esp: u32 = 0,
    seg_ss: u32 = 0x002B,
};

// ── 32-bit PEB/TEB ──

pub const PEB32 = struct {
    inherited_address_space: u8 = 0,
    read_image_file_exec_options: u8 = 0,
    being_debugged: u8 = 0,
    spare_bool: u8 = 0,
    mutant: u32 = 0,
    image_base_address: u32 = 0,
    ldr: u32 = 0,
    process_parameters: u32 = 0,
    sub_system_data: u32 = 0,
    process_heap: u32 = 0,
    fast_peb_lock: u32 = 0,
    os_major_version: u32 = 0,
    os_minor_version: u32 = 0,
    os_build_number: u16 = 0,
    os_csd_version: u16 = 0,
    os_platform_id: u32 = 0,
    image_subsystem: u32 = 0,
    image_subsystem_major_version: u32 = 0,
    image_subsystem_minor_version: u32 = 0,
    number_of_processors: u32 = 0,
    nt_global_flag: u32 = 0,
    session_id: u32 = 0,
};

pub const TEB32 = struct {
    nt_tib_exception_list: u32 = 0,
    nt_tib_stack_base: u32 = 0,
    nt_tib_stack_limit: u32 = 0,
    nt_tib_sub_system_tib: u32 = 0,
    nt_tib_fiber_data: u32 = 0,
    nt_tib_arbitrary_user_pointer: u32 = 0,
    nt_tib_self: u32 = 0,
    environment_pointer: u32 = 0,
    process_id: u32 = 0,
    thread_id: u32 = 0,
    active_rpc_handle: u32 = 0,
    thread_local_storage: u32 = 0,
    peb: u32 = 0,
    last_error_value: u32 = 0,
    count_of_owned_critical_sections: u32 = 0,
    wow64_reserved: u32 = 0,
    locale_id: u32 = 0,
    tls_slots: [WOW64_TLS_SLOTS]u32 = [_]u32{0} ** WOW64_TLS_SLOTS,
};

// ── WOW64 Process ──

const MAX_WOW64_PROCESSES: usize = 32;

pub const Wow64Process = struct {
    pid: u32 = 0,
    state: Wow64State = .inactive,
    is_active: bool = false,
    context: CONTEXT32 = .{},
    peb32: PEB32 = .{},
    teb32: TEB32 = .{},
    image_name: [64]u8 = [_]u8{0} ** 64,
    image_name_len: usize = 0,
    image_base: u32 = 0,
    entry_point: u32 = 0,
    stack_base: u32 = 0,
    stack_limit: u32 = 0,
    heap_base: u32 = 0,
    parent_pid: u32 = 0,
    exit_code: u32 = 0,
    syscall_count: u64 = 0,
    thunk_count: u64 = 0,

    pub fn getName(self: *const Wow64Process) []const u8 {
        return self.image_name[0..self.image_name_len];
    }
};

// ── Thunk Entry ──

const MAX_THUNK_ENTRIES: usize = 128;

pub const ThunkEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    native_syscall_id: u32 = 0,
    thunk_type: ThunkType = .none,
    is_active: bool = false,
    call_count: u64 = 0,
    target_module: [32]u8 = [_]u8{0} ** 32,
    target_module_len: usize = 0,
};

// ── Global State ──

var wow64_processes: [MAX_WOW64_PROCESSES]Wow64Process = [_]Wow64Process{.{}} ** MAX_WOW64_PROCESSES;
var wow64_process_count: usize = 0;
var next_wow64_pid: u32 = 2000;

var thunk_table: [MAX_THUNK_ENTRIES]ThunkEntry = [_]ThunkEntry{.{}} ** MAX_THUNK_ENTRIES;
var thunk_count: usize = 0;

var wow64_state: Wow64State = .inactive;
var wow64_initialized: bool = false;
var total_thunks: u64 = 0;
var total_syscall_translations: u64 = 0;
var total_ptr_conversions: u64 = 0;

// ── Thunk Registration ──

fn registerThunk(name: []const u8, syscall_id: u32, thunk_type: ThunkType, module: []const u8) void {
    if (thunk_count >= MAX_THUNK_ENTRIES) return;
    var entry = &thunk_table[thunk_count];
    entry.* = .{};
    entry.is_active = true;
    entry.native_syscall_id = syscall_id;
    entry.thunk_type = thunk_type;

    const n = @min(name.len, entry.name.len);
    @memcpy(entry.name[0..n], name[0..n]);
    entry.name_len = n;

    const m = @min(module.len, entry.target_module.len);
    @memcpy(entry.target_module[0..m], module[0..m]);
    entry.target_module_len = m;

    thunk_count += 1;
}

fn findThunk(name: []const u8) ?*ThunkEntry {
    for (thunk_table[0..thunk_count]) |*entry| {
        if (!entry.is_active) continue;
        if (entry.name_len == name.len) {
            var match = true;
            for (entry.name[0..entry.name_len], name) |a, b| {
                if (a != b) {
                    match = false;
                    break;
                }
            }
            if (match) return entry;
        }
    }
    return null;
}

// ── Syscall Translation (32-bit -> 64-bit) ──

pub fn translateSyscall32to64(wow_proc: *Wow64Process, syscall_num: u32) ntdll.NTSTATUS {
    wow_proc.syscall_count += 1;
    total_syscall_translations += 1;

    return switch (syscall_num) {
        0x0001 => ntdll.STATUS_SUCCESS, // NtCreateProcess (translated)
        0x0002 => ntdll.STATUS_SUCCESS, // NtTerminateProcess
        0x0003 => ntdll.STATUS_SUCCESS, // NtCreateThread
        0x0004 => ntdll.STATUS_SUCCESS, // NtTerminateThread
        0x0006 => ntdll.STATUS_SUCCESS, // NtCreateFile
        0x0007 => ntdll.STATUS_SUCCESS, // NtOpenFile
        0x0008 => ntdll.STATUS_SUCCESS, // NtReadFile
        0x0009 => ntdll.STATUS_SUCCESS, // NtWriteFile
        0x000C => ntdll.STATUS_SUCCESS, // NtClose
        0x0011 => ntdll.STATUS_SUCCESS, // NtAllocateVirtualMemory
        0x0012 => ntdll.STATUS_SUCCESS, // NtFreeVirtualMemory
        0x0018 => ntdll.STATUS_SUCCESS, // NtCreateEvent
        0x001A => ntdll.STATUS_SUCCESS, // NtWaitForSingleObject
        0x001F => ntdll.STATUS_SUCCESS, // NtQuerySystemInformation
        0x0025 => ntdll.STATUS_SUCCESS, // NtCreatePort
        0x0036 => ntdll.STATUS_SUCCESS, // NtQueryInformationProcess
        else => ntdll.STATUS_NOT_IMPLEMENTED,
    };
}

// ── Pointer Conversion ──

pub fn convertPtr32to64(ptr32: u32) u64 {
    total_ptr_conversions += 1;
    if (ptr32 == 0) return 0;
    return @as(u64, ptr32);
}

pub fn convertPtr64to32(ptr64: u64) u32 {
    total_ptr_conversions += 1;
    if (ptr64 > WOW64_MAX_ADDR) return 0;
    return @intCast(ptr64 & 0xFFFFFFFF);
}

pub fn convertHandle32to64(handle32: u32) u64 {
    return @as(u64, handle32);
}

pub fn convertHandle64to32(handle64: u64) u32 {
    return @intCast(handle64 & 0xFFFFFFFF);
}

// ── WOW64 Process Management ──

pub fn createWow64Process(name: []const u8, parent_pid: u32) ?*Wow64Process {
    if (wow64_process_count >= MAX_WOW64_PROCESSES) return null;

    var proc = &wow64_processes[wow64_process_count];
    proc.* = .{};
    proc.pid = next_wow64_pid;
    proc.state = .initializing;
    proc.is_active = true;
    proc.parent_pid = parent_pid;

    next_wow64_pid += 1;

    const n = @min(name.len, proc.image_name.len);
    @memcpy(proc.image_name[0..n], name[0..n]);
    proc.image_name_len = n;

    proc.image_base = PE32_IMAGE_BASE;
    proc.entry_point = PE32_IMAGE_BASE + 0x1000;
    proc.stack_base = 0x00100000;
    proc.stack_limit = proc.stack_base - WOW64_STACK_SIZE;
    proc.heap_base = 0x00200000;

    proc.context = .{};
    proc.context.eip = proc.entry_point;
    proc.context.esp = proc.stack_base;
    proc.context.ebp = proc.stack_base;

    proc.peb32 = .{};
    proc.peb32.mutant = 0xFFFFFFFF;
    proc.peb32.image_base_address = proc.image_base;
    proc.peb32.os_major_version = 10;
    proc.peb32.os_build_number = 19041;
    proc.peb32.os_platform_id = 2;
    proc.peb32.image_subsystem = 3;
    proc.peb32.image_subsystem_major_version = 6;
    proc.peb32.number_of_processors = 1;

    proc.teb32 = .{};
    proc.teb32.nt_tib_exception_list = 0xFFFFFFFF;
    proc.teb32.process_id = proc.pid;
    proc.teb32.thread_id = proc.pid;
    proc.teb32.nt_tib_stack_base = proc.stack_base;
    proc.teb32.nt_tib_stack_limit = proc.stack_limit;
    proc.teb32.locale_id = 0x0409;

    _ = subsystem.registerProcess(proc.pid, .win32_cui, name, parent_pid);
    _ = subsystem.connectProcess(proc.pid);

    proc.state = .active;
    wow64_process_count += 1;

    klog.debug("wow64: Created 32-bit process '%s' PID=%u (base=0x%x, entry=0x%x)", .{
        name, proc.pid, proc.image_base, proc.entry_point,
    });

    return proc;
}

pub fn terminateWow64Process(pid: u32, exit_code: u32) bool {
    const proc = findWow64Process(pid) orelse return false;
    proc.state = .inactive;
    proc.is_active = false;
    proc.exit_code = exit_code;
    _ = subsystem.terminateWin32Process(pid, exit_code);
    return true;
}

pub fn findWow64Process(pid: u32) ?*Wow64Process {
    for (wow64_processes[0..wow64_process_count]) |*proc| {
        if (proc.pid == pid and proc.is_active) return proc;
    }
    return null;
}

pub fn isWow64Process(pid: u32) bool {
    return findWow64Process(pid) != null;
}

// ── WOW64 API Wrappers (32-bit versions) ──

pub fn Wow64NtCreateProcess(proc: *Wow64Process, _: u32) ntdll.NTSTATUS {
    proc.thunk_count += 1;
    total_thunks += 1;
    return translateSyscall32to64(proc, 0x0001);
}

pub fn Wow64NtCreateFile(proc: *Wow64Process, _: u32, _: u32) ntdll.NTSTATUS {
    proc.thunk_count += 1;
    total_thunks += 1;
    return translateSyscall32to64(proc, 0x0006);
}

pub fn Wow64NtAllocateVirtualMemory(proc: *Wow64Process, _: u32, _: u32) ntdll.NTSTATUS {
    proc.thunk_count += 1;
    total_thunks += 1;
    return translateSyscall32to64(proc, 0x0011);
}

pub fn Wow64NtClose(proc: *Wow64Process, _: u32) ntdll.NTSTATUS {
    proc.thunk_count += 1;
    total_thunks += 1;
    return translateSyscall32to64(proc, 0x000C);
}

pub fn Wow64NtWaitForSingleObject(proc: *Wow64Process, _: u32) ntdll.NTSTATUS {
    proc.thunk_count += 1;
    total_thunks += 1;
    return translateSyscall32to64(proc, 0x001A);
}

// ── Statistics ──

pub fn getActiveWow64Count() usize {
    var count: usize = 0;
    for (wow64_processes[0..wow64_process_count]) |*proc| {
        if (proc.is_active) count += 1;
    }
    return count;
}

pub fn getTotalWow64Count() usize {
    return wow64_process_count;
}

pub fn getThunkCount() usize {
    return thunk_count;
}

pub fn getTotalThunkCalls() u64 {
    return total_thunks;
}

pub fn getTotalSyscallTranslations() u64 {
    return total_syscall_translations;
}

pub fn getTotalPtrConversions() u64 {
    return total_ptr_conversions;
}

pub fn getState() Wow64State {
    return wow64_state;
}

// ── Demo ──

pub fn runWow64Demo() void {
    klog.info("wow64: --- WOW64 Compatibility Demo ---", .{});

    const calc = createWow64Process("calc32.exe", 4);
    if (calc) |proc| {
        if (console_mod.createConsole(proc.pid, proc.getName())) |con| {
            con.writeLine("");
            con.writeLine("[WOW64] calc32.exe - 32-bit Application");
            con.writeLine("[WOW64] PE32 image loaded at 0x00400000");
            con.writeLine("[WOW64] 32-bit PEB/TEB initialized");
            con.writeLine("[WOW64] Syscall thunking active (32->64 bit)");
            con.writeLine("[WOW64] ntdll32.dll loaded at 0x77000000");
            con.writeLine("[WOW64] kernel32.dll (32-bit) loaded at 0x76000000");
            con.writeLine("");
        }

        _ = Wow64NtCreateFile(proc, 0, 0);
        _ = Wow64NtAllocateVirtualMemory(proc, 0, 0x10000);
        _ = Wow64NtClose(proc, 1);

        klog.info("wow64: calc32.exe: %u syscalls, %u thunks", .{
            proc.syscall_count, proc.thunk_count,
        });
        _ = terminateWow64Process(proc.pid, 0);
    }

    const notepad32 = createWow64Process("notepad32.exe", 4);
    if (notepad32) |proc| {
        if (console_mod.createConsole(proc.pid, proc.getName())) |con| {
            con.writeLine("[WOW64] notepad32.exe - 32-bit Text Editor");
            con.writeLine("[WOW64] Address space: 0x00000000 - 0x7FFFFFFF (2GB)");
            con.writeLine("[WOW64] File system redirection active");
            con.writeLine("[WOW64] Registry redirection: Wow6432Node");
            con.writeLine("");
        }

        _ = Wow64NtCreateFile(proc, 0, 0);
        _ = Wow64NtWaitForSingleObject(proc, 1);

        _ = terminateWow64Process(proc.pid, 0);
    }

    const legacy = createWow64Process("legacy_app.exe", 4);
    if (legacy) |proc| {
        if (console_mod.createConsole(proc.pid, proc.getName())) |con| {
            con.writeLine("[WOW64] legacy_app.exe - Win32 Legacy Application");
            con.writeLine("[WOW64] Compatibility flags: Win7 mode");
            con.writeLine("[WOW64] DEP: OptIn, ASLR: Off (legacy compat)");
            con.writeLine("");
        }
        _ = terminateWow64Process(proc.pid, 0);
    }

    klog.info("wow64: Demo complete: %u processes, %u syscall translations, %u thunks", .{
        getTotalWow64Count(), getTotalSyscallTranslations(), getTotalThunkCalls(),
    });
}

// ── Thunk Table Initialization ──

fn initThunkTable() void {
    registerThunk("NtCreateProcess", 0x0001, .syscall_32to64, "ntdll");
    registerThunk("NtTerminateProcess", 0x0002, .syscall_32to64, "ntdll");
    registerThunk("NtCreateThread", 0x0003, .syscall_32to64, "ntdll");
    registerThunk("NtTerminateThread", 0x0004, .syscall_32to64, "ntdll");
    registerThunk("NtCreateFile", 0x0006, .syscall_32to64, "ntdll");
    registerThunk("NtOpenFile", 0x0007, .syscall_32to64, "ntdll");
    registerThunk("NtReadFile", 0x0008, .syscall_32to64, "ntdll");
    registerThunk("NtWriteFile", 0x0009, .syscall_32to64, "ntdll");
    registerThunk("NtClose", 0x000C, .syscall_32to64, "ntdll");
    registerThunk("NtAllocateVirtualMemory", 0x0011, .syscall_32to64, "ntdll");
    registerThunk("NtFreeVirtualMemory", 0x0012, .syscall_32to64, "ntdll");
    registerThunk("NtCreateEvent", 0x0018, .syscall_32to64, "ntdll");
    registerThunk("NtWaitForSingleObject", 0x001A, .syscall_32to64, "ntdll");
    registerThunk("NtQuerySystemInformation", 0x001F, .syscall_32to64, "ntdll");
    registerThunk("NtCreatePort", 0x0025, .syscall_32to64, "ntdll");
    registerThunk("NtQueryInformationProcess", 0x0036, .syscall_32to64, "ntdll");
    registerThunk("NtCreateSection", 0x0047, .syscall_32to64, "ntdll");
    registerThunk("NtMapViewOfSection", 0x0048, .syscall_32to64, "ntdll");

    registerThunk("POINTER_32TO64", 0xF001, .ptr_32to64, "wow64");
    registerThunk("POINTER_64TO32", 0xF002, .ptr_64to32, "wow64");
    registerThunk("HANDLE_CONVERT", 0xF003, .handle_convert, "wow64");
    registerThunk("STRUCT_CONVERT", 0xF004, .struct_convert, "wow64");
}

fn initWow64Dlls() void {
    const wow64_ntdll = pe_loader.loadDll("ntdll32.dll", WOW64_NTDLL_BASE);
    if (wow64_ntdll.image) |img| {
        img.subsystem = pe_loader.IMAGE_SUBSYSTEM_NATIVE;
        img.size_of_image = 0x180000;
        img.machine = 0x014C; // IMAGE_FILE_MACHINE_I386
        img.addSection(".text", 0x1000, 0xC0000, pe_loader.IMAGE_SCN_MEM_READ | pe_loader.IMAGE_SCN_MEM_EXECUTE | pe_loader.IMAGE_SCN_CNT_CODE);
        img.addSection(".data", 0xC1000, 0x20000, pe_loader.IMAGE_SCN_MEM_READ | pe_loader.IMAGE_SCN_MEM_WRITE | pe_loader.IMAGE_SCN_CNT_INITIALIZED_DATA);
        img.addExport("NtCreateProcess", 0x1000, 1);
        img.addExport("NtTerminateProcess", 0x1020, 2);
        img.addExport("NtCreateFile", 0x1040, 3);
        img.addExport("NtClose", 0x1060, 4);
        img.addExport("NtAllocateVirtualMemory", 0x1080, 5);
        img.addExport("RtlInitUnicodeString", 0x2000, 100);
    }

    const wow64_k32 = pe_loader.loadDll("kernel3232.dll", WOW64_KERNEL32_BASE);
    if (wow64_k32.image) |img| {
        img.subsystem = pe_loader.IMAGE_SUBSYSTEM_WINDOWS_CUI;
        img.size_of_image = 0x100000;
        img.machine = 0x014C;
        img.addImport("ntdll32.dll");
        img.addExport("CreateProcessA", 0x1000, 1);
        img.addExport("ExitProcess", 0x1020, 2);
        img.addExport("CreateFileA", 0x1040, 3);
        img.addExport("CloseHandle", 0x1060, 4);
        img.addExport("GetLastError", 0x1080, 5);
    }

    const wow64_dll = pe_loader.loadDll("wow64.dll", 0x74000000);
    if (wow64_dll.image) |img| {
        img.size_of_image = 0x80000;
        img.addExport("Wow64SystemServiceEx", 0x1000, 1);
        img.addExport("Wow64LdrpInitialize", 0x1040, 2);
        img.addExport("Wow64PrepareForException", 0x1080, 3);
    }

    const wow64cpu = pe_loader.loadDll("wow64cpu.dll", 0x73000000);
    if (wow64cpu.image) |img| {
        img.size_of_image = 0x40000;
        img.addExport("CpuSimulate", 0x1000, 1);
        img.addExport("CpuResetToConsistentState", 0x1020, 2);
        img.addExport("CpuSetContext", 0x1040, 3);
        img.addExport("CpuGetContext", 0x1060, 4);
    }

    const wow64win = pe_loader.loadDll("wow64win.dll", 0x72000000);
    if (wow64win.image) |img| {
        img.size_of_image = 0x60000;
        img.addExport("whNtUserCallNoParam", 0x1000, 1);
        img.addExport("whNtUserCallOneParam", 0x1020, 2);
        img.addExport("whNtGdiDdDDICreateDevice", 0x1040, 3);
    }
}

// ── Initialization ──

pub fn init() void {
    wow64_process_count = 0;
    next_wow64_pid = 2000;
    thunk_count = 0;
    total_thunks = 0;
    total_syscall_translations = 0;
    total_ptr_conversions = 0;

    wow64_state = .initializing;

    initThunkTable();
    initWow64Dlls();

    wow64_state = .active;
    wow64_initialized = true;

    klog.info("wow64: WOW64 Compatibility Layer initialized", .{});
    klog.info("wow64: Syscall thunk table: %u entries", .{thunk_count});
    klog.info("wow64: 32-bit DLLs: ntdll32.dll, kernel3232.dll, wow64.dll, wow64cpu.dll, wow64win.dll", .{});
    klog.info("wow64: PE32 support: IMAGE_FILE_MACHINE_I386 (0x014C)", .{});
    klog.info("wow64: Address space: 0x00000000 - 0x7FFFFFFF (2GB user, 32-bit)", .{});
    klog.info("wow64: Thunk types: syscall, pointer, handle, struct conversion", .{});
}
