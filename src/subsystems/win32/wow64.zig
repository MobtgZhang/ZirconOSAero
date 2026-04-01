//! WOW64 - 32-bit on 64-bit Compatibility Layer
//! Phase 11: PE32 loading, 32-bit syscall thunking, address space
//! management, 32-bit ntdll/kernel32 shim, and compatibility testing.
//!
//! **与真实 SysWOW64 的差距**：64 位内核侧为 **NT 6.1 SSDT 子集**（`src/arch/x86_64/ssdt_nt61.zig`）；无非 Windows 服务号命名空间。
//! 本层 `translateSyscall32to64` 仍使用 **32 位 PE 常见 syscall 号** 演示 thunk；与 SysWOW64 转 64 位 `syscall` 的真实映射表不对齐，见 `docs/cn/SyscallABI.md`。
//!
//! 模块化：`wow64/types.zig`、`wow64/thunk.zig`、`wow64/redirect.zig`。

const klog = @import("../../rtl/klog.zig");
const pe_loader = @import("../../loader/pe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const subsystem = @import("subsystem.zig");
const console_mod = @import("console.zig");

const types = @import("wow64/types.zig");
const thunk = @import("wow64/thunk.zig");
const redirect = @import("wow64/redirect.zig");

pub const WOW64_VERSION = types.WOW64_VERSION;
pub const WOW64_MAX_ADDR = types.WOW64_MAX_ADDR;
pub const WOW64_STACK_SIZE = types.WOW64_STACK_SIZE;
pub const WOW64_HEAP_SIZE = types.WOW64_HEAP_SIZE;
pub const WOW64_TLS_SLOTS = types.WOW64_TLS_SLOTS;
pub const PE32_IMAGE_BASE = types.PE32_IMAGE_BASE;
pub const WOW64_NTDLL_BASE = types.WOW64_NTDLL_BASE;
pub const WOW64_KERNEL32_BASE = types.WOW64_KERNEL32_BASE;
pub const WOW64_USER32_BASE = types.WOW64_USER32_BASE;
pub const Wow64State = types.Wow64State;
pub const ThunkType = types.ThunkType;
pub const CONTEXT32 = types.CONTEXT32;
pub const PEB32 = types.PEB32;
pub const TEB32 = types.TEB32;
pub const Wow64Process = types.Wow64Process;
pub const ThunkEntry = types.ThunkEntry;

pub const translateSyscall32to64 = thunk.translateSyscall32to64;
pub const convertPtr32to64 = thunk.convertPtr32to64;
pub const convertPtr64to32 = thunk.convertPtr64to32;
pub const convertHandle32to64 = thunk.convertHandle32to64;
pub const convertHandle64to32 = thunk.convertHandle64to32;

pub const shouldRedirectSystem32ToSyswow64 = redirect.shouldRedirectSystem32ToSyswow64;
pub const noteRegistryWow64Node = redirect.noteRegistryWow64Node;

var wow64_processes: [types.MAX_WOW64_PROCESSES]Wow64Process = [_]Wow64Process{.{}} ** types.MAX_WOW64_PROCESSES;
var wow64_process_count: usize = 0;
var next_wow64_pid: u32 = 2000;

var thunk_table: [types.MAX_THUNK_ENTRIES]ThunkEntry = [_]ThunkEntry{.{}} ** types.MAX_THUNK_ENTRIES;
var thunk_count: usize = 0;

var wow64_state: Wow64State = .inactive;
var total_thunks: u64 = 0;

fn registerThunk(name: []const u8, syscall_id: u32, tt: ThunkType, module: []const u8) void {
    if (thunk_count >= types.MAX_THUNK_ENTRIES) return;
    var entry = &thunk_table[thunk_count];
    entry.* = .{};
    entry.is_active = true;
    entry.native_syscall_id = syscall_id;
    entry.thunk_type = tt;

    const n = @min(name.len, entry.name.len);
    @memcpy(entry.name[0..n], name[0..n]);
    entry.name_len = n;

    const m = @min(module.len, entry.target_module.len);
    @memcpy(entry.target_module[0..m], module[0..m]);
    entry.target_module_len = m;

    thunk_count += 1;
}

pub fn createWow64Process(name: []const u8, parent_pid: u32) ?*Wow64Process {
    if (wow64_process_count >= types.MAX_WOW64_PROCESSES) return null;

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
    return thunk.total_syscall_translations;
}

pub fn getTotalPtrConversions() u64 {
    return thunk.total_ptr_conversions;
}

pub fn getState() Wow64State {
    return wow64_state;
}

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
            con.writeLine("[WOW64] Compatibility flags: NT 6.1 profile");
            con.writeLine("[WOW64] DEP: OptIn, ASLR: Off (legacy compat)");
            con.writeLine("");
        }
        _ = terminateWow64Process(proc.pid, 0);
    }

    klog.info("wow64: Demo complete: %u processes, %u syscall translations, %u thunks", .{
        getTotalWow64Count(), getTotalSyscallTranslations(), getTotalThunkCalls(),
    });
}

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
        img.machine = 0x014C;
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

pub fn init() void {
    wow64_process_count = 0;
    next_wow64_pid = 2000;
    thunk_count = 0;
    total_thunks = 0;
    thunk.total_syscall_translations = 0;
    thunk.total_ptr_conversions = 0;

    wow64_state = .initializing;

    initThunkTable();
    initWow64Dlls();

    wow64_state = .active;

    klog.info("wow64: WOW64 Compatibility Layer initialized", .{});
    klog.info("wow64: Syscall thunk table: %u entries", .{thunk_count});
    klog.info("wow64: 32-bit DLLs: ntdll32.dll, kernel3232.dll, wow64.dll, wow64cpu.dll, wow64win.dll", .{});
    klog.info("wow64: PE32 support: IMAGE_FILE_MACHINE_I386 (0x014C)", .{});
    klog.info("wow64: Address space: 0x00000000 - 0x7FFFFFFF (2GB user, 32-bit)", .{});
    klog.info("wow64: Thunk types: syscall, pointer, handle, struct conversion", .{});
}
