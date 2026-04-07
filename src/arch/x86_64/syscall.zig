//! x86_64 系统调用分发：经 **`syscall`/`sysret`**（`syscall_lstar.s`）进入，本模块使用 **NT 6.1 x64** 寄存器约定。
//! - **服务号**：`ssdt_nt61.zig` 中公开 SSDT 索引（Windows 7 SP1 x64 参考：j00ru/windows-syscalls）。
//! - **约定**：第 1 参在 **R10**（`syscall` 时 RCX 存用户 RIP，故不用 RCX 传参）；第 2–4 参为 **RDX/R8/R9**；其余在用户栈。

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const registry = @import("../../registry/registry.zig");
const ob = @import("../../ob/object.zig");
const klog = @import("../../rtl/klog.zig");
const ntdll = @import("../../libs/ntdll.zig");
const ssdt = @import("ssdt_nt61.zig");
const syscall_abi = @import("syscall_abi.zig");
const syscall_nt_extras = @import("syscall_nt_extras.zig");
const syscall_mm = @import("syscall_dispatch_mm.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;
const user32 = @import("../../subsystems/win32/user32.zig");
const wow64_redirect = @import("../../subsystems/win32/wow64/redirect.zig");

fn ntResult(s: ntdll.NTSTATUS) i64 {
    return syscall_abi.ntStatusAsI64(s);
}

pub const STATUS_SUCCESS: i64 = 0;
pub const STATUS_NO_MESSAGE: i64 = -3;
pub const STATUS_NOT_IMPLEMENTED: i64 = @intCast(ntdll.STATUS_NOT_IMPLEMENTED);

/// 自用户态 `UNICODE_STRING`（Length 为字节数）读取窄字符名到 `out`（UTF-16LE 低字节，非 ASCII 置 `?`）。
fn readUserUnicodePathName(unicode_str_va: u64, out: *[32]u8) ?[]const u8 {
    if (unicode_str_va == 0) return null;
    const proc = process.getCurrentProcess() orelse return null;
    const asp = proc.address_space orelse return null;
    if (!probe.probeUserUnicodeString(asp, unicode_str_va, false)) return null;
    // SAFETY: `probeUserUnicodeString` 已校验 UNICODE_STRING 头与 Buffer 范围。
    const us = @as(*const volatile extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: u64,
    }, @ptrFromInt(unicode_str_va));
    const byte_len = us.Length;
    if (byte_len < 2 or byte_len > 64) return null;
    const wchar_count = @as(usize, @intCast(byte_len)) / 2;
    if (wchar_count == 0) return null;
    if (us.Buffer == 0) return null;
    var j: usize = 0;
    var i: usize = 0;
    while (i < wchar_count and j < out.len) : (i += 1) {
        const ch = @as(*const volatile u16, @ptrFromInt(us.Buffer + i * 2)).*;
        out[j] = if (ch < 128) @truncate(ch) else '?';
        j += 1;
    }
    return out[0..j];
}

/// 长路径（注册表 `\Registry\...`）；`out` 为 ASCII 窄字符（UTF-16LE 低字节）。
fn readUserUnicodePathToBuf(unicode_str_va: u64, out: []u8) ?[]const u8 {
    if (unicode_str_va == 0) return null;
    const proc_u = process.getCurrentProcess() orelse return null;
    const asp_u = proc_u.address_space orelse return null;
    if (!probe.probeUserUnicodeString(asp_u, unicode_str_va, false)) return null;
    const us = @as(*const volatile extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: u64,
    }, @ptrFromInt(unicode_str_va));
    const byte_len = us.Length;
    if (byte_len < 2) return null;
    const wchar_count = @as(usize, @intCast(byte_len)) / 2;
    if (wchar_count == 0 or wchar_count > out.len) return null;
    if (us.Buffer == 0) return null;
    var j: usize = 0;
    var i: usize = 0;
    while (i < wchar_count and j < out.len) : (i += 1) {
        const ch = @as(*const volatile u16, @ptrFromInt(us.Buffer + i * 2)).*;
        out[j] = if (ch < 128) @truncate(ch) else '?';
        j += 1;
    }
    return out[0..j];
}

fn readRegPathFromObjectAttributes(obj_attr_va: u64, out: *[512]u8) ?[]const u8 {
    if (obj_attr_va == 0) return null;
    const proc_r = process.getCurrentProcess() orelse return null;
    const asp_r = proc_r.address_space orelse return null;
    if (!probe.probeUserMemory(asp_r, obj_attr_va, 64, false)) return null;
    const oa = @as(*const volatile extern struct {
        Length: u32,
        _pad0: u32,
        RootDirectory: u64,
        ObjectName: u64,
        Attributes: u32,
        _pad1: u32,
        SecurityDescriptor: u64,
        SecurityQualityOfService: u64,
    }, @ptrFromInt(obj_attr_va));
    if (oa.ObjectName == 0) return null;
    return readUserUnicodePathToBuf(oa.ObjectName, out[0..]);
}

fn readPortNameFromObjectAttributes(obj_attr_va: u64, out: *[32]u8) ?[]const u8 {
    if (obj_attr_va == 0) return null;
    const oa = @as(*const volatile extern struct {
        Length: u32,
        _pad0: u32,
        RootDirectory: u64,
        ObjectName: u64,
        Attributes: u32,
        _pad1: u32,
        SecurityDescriptor: u64,
        SecurityQualityOfService: u64,
    }, @ptrFromInt(obj_attr_va));
    if (oa.ObjectName == 0) return null;
    return readUserUnicodePathName(oa.ObjectName, out);
}

/// `NtDisplayString`：将用户 `UNICODE_STRING` 以可打印 ASCII 子集写到控制台。
fn readUserUnicodeForDisplay(unicode_str_va: u64, out: *[256]u8) ?[]const u8 {
    if (unicode_str_va == 0) return null;
    const proc = process.getCurrentProcess() orelse return null;
    const asp = proc.address_space orelse return null;
    if (!probe.probeUserUnicodeString(asp, unicode_str_va, false)) return null;
    const us = @as(*const volatile extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: u64,
    }, @ptrFromInt(unicode_str_va));
    const byte_len = us.Length;
    if (byte_len == 0 or byte_len > 510) return null;
    if (us.Buffer == 0) return null;
    const wchar_count = @as(usize, @intCast(byte_len)) / 2;
    var j: usize = 0;
    var i: usize = 0;
    while (i < wchar_count and j < out.len - 2) : (i += 1) {
        const ch = @as(*const volatile u16, @ptrFromInt(us.Buffer + i * 2)).*;
        if (ch == '\r' or ch == '\n') {
            out[j] = ';';
            j += 1;
        } else if (ch < 128) {
            out[j] = @truncate(ch);
            j += 1;
        } else {
            out[j] = '?';
            j += 1;
        }
    }
    return out[0..j];
}

pub fn dispatch(frame: *InterruptFrame) void {
    const syscall_no = frame.rax;
    const result: i64 = dispatchNtSsdt(frame, @truncate(syscall_no));
    frame.rax = @bitCast(result);
    // 返用户前在 PASSIVE 排空内核 APC（与 `interrupt_x86.handleSyscall` 路径一致）。
    @import("../../ke/apc.zig").deliverKernelApcsForCurrentThread();
    // 返回用户态前确保当前线程 CR3 与所属进程一致（与调度器 `activateCr3ForProcessId` 互补；见 docs/cn/VM_ISOLATION.md）。
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| asp.activate();
    }
}

fn dispatchNtSsdt(frame: *InterruptFrame, idx: u32) i64 {
    // G-C4（可选）：若需 WOW64/内核复用同一派发核心，可再抽出 `dispatchNtSsdtFromFrame`；现保持单路径以降低 IRQL/重入组合风险。
    const p1 = frame.r10;
    const p2 = frame.rdx;
    const p3 = frame.r8;
    const p4 = frame.r9;

    return switch (idx) {
        ssdt.NtWaitForSingleObject => blk: {
            const alertable = p2 != 0;
            const timeout_ptr: ?*const i64 = if (p3 == 0) null else @ptrFromInt(p3);
            const st = ntdll.NtWaitForSingleObject(p1, alertable, timeout_ptr);
            break :blk ntResult(st);
        },
        ssdt.NtAllocateVirtualMemory => syscall_mm.dispatchNtAllocateVirtualMemory(frame),
        ssdt.NtFreeVirtualMemory => syscall_mm.dispatchNtFreeVirtualMemory(frame),
        ssdt.NtQuerySystemInformation => blk: {
            const len: u32 = @truncate(p3);
            const buf_ptr = p2;
            if (buf_ptr == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const proc_q = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const asp_q = proc_q.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (len > 0 and !probe.probeUserMemory(asp_q, buf_ptr, len, true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_q, p4, @sizeOf(u32), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl: *u32 = @ptrFromInt(p4);
            const buf: [*]u8 = @ptrFromInt(buf_ptr);
            const st = ntdll.NtQuerySystemInformation(@truncate(p1), buf[0..len], rl);
            break :blk ntResult(st);
        },
        ssdt.NtCreateFile => blk: {
            const proc_f = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const asp_f = proc_f.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p3 == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_f, p3, 64, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_f, p4, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const io = p4;
            const alloc_sz = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const fa = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const sh = syscall_abi.userStackArg(frame, 2) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const disp = syscall_abi.userStackArg(frame, 3) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const opt = syscall_abi.userStackArg(frame, 4) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const ea = syscall_abi.userStackArg(frame, 5) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const ealen: u32 = @truncate(syscall_abi.userStackArg(frame, 6) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION));
            const st = ntdll.NtCreateFile(
                @ptrFromInt(p1),
                @truncate(p2),
                @ptrFromInt(p3),
                @ptrFromInt(io),
                alloc_sz,
                @truncate(fa),
                @truncate(sh),
                @truncate(disp),
                @truncate(opt),
                @ptrFromInt(ea),
                ealen,
            );
            break :blk ntResult(st);
        },
        ssdt.NtClose => ntResult(ntdll.NtClose(p1)),
        ssdt.NtYieldExecution => blk: {
            const scheduler = @import("../../ke/scheduler.zig");
            scheduler.yield();
            break :blk 0;
        },
        ssdt.NtTerminateProcess => ntResult(ntdll.NtTerminateProcess(p1, @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtCreateThread => blk: {
            const st = ntdll.NtCreateThread(@ptrFromInt(p1), @truncate(p2));
            break :blk ntResult(st);
        },
        ssdt.NtTerminateThread => ntResult(ntdll.NtTerminateThread(p1, @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtProtectVirtualMemory => syscall_mm.dispatchNtProtectVirtualMemory(frame),
        ssdt.NtDelayExecution => blk: {
            const proc_de = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_de = proc_de.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_de, p2, 8, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const interval = @as(*const volatile i64, @ptrFromInt(p2)).*;
            const st = ntdll.NtDelayExecution(@truncate(p1), interval);
            break :blk ntResult(st);
        },
        ssdt.NtOpenKey => blk: {
            const proc_ok = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_ok = proc_ok.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_ok, p1, @sizeOf(ntdll.HANDLE), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_ok, p3, 64, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var pathbuf: [512]u8 = undefined;
            const raw = readRegPathFromObjectAttributes(p3, &pathbuf) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const path_norm = ob.normalizeNtObjectPath(raw);
            var redir_buf: [512]u8 = undefined;
            const path_open = wow64_redirect.applyWow64RegistryMachineSoftwarePath(proc_ok.is_wow64, path_norm, &redir_buf) orelse path_norm;
            const reg_key_idx = registry.openKeyByNtPath(path_open) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const hdr = registry.keyHeaderPtr(reg_key_idx) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const h = proc_ok.handle_table.allocHandle(@intFromPtr(hdr), ob.GENERIC_READ, .key) orelse break :blk ntResult(ntdll.STATUS_INSUFFICIENT_RESOURCES);
            @as(*volatile ntdll.HANDLE, @ptrFromInt(p1)).* = h;
            break :blk 0;
        },
        ssdt.NtQueryValueKey => blk: {
            const proc_qvk = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_qvk = proc_qvk.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const stack_len = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const result_len_va = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const len: u32 = @truncate(stack_len);
            if (p2 == 0 or p4 == 0 or result_len_va == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserUnicodeString(asp_qvk, p2, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_qvk, result_len_va, @sizeOf(u32), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (len > 0 and !probe.probeUserMemory(asp_qvk, p4, len, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const result_len: *u32 = @ptrFromInt(result_len_va);
            const st = ntdll.NtQueryValueKey(
                p1,
                @ptrFromInt(p2),
                @truncate(p3),
                @ptrFromInt(p4),
                len,
                result_len,
            );
            break :blk ntResult(st);
        },
        ssdt.NtCreateKey => blk: {
            const proc_ck = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_ck = proc_ck.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_ck, p1, @sizeOf(ntdll.HANDLE), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_ck, p3, 64, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var pathbuf: [512]u8 = undefined;
            const raw = readRegPathFromObjectAttributes(p3, &pathbuf) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const path_norm = ob.normalizeNtObjectPath(raw);
            var redir_buf: [512]u8 = undefined;
            const path_ck = wow64_redirect.applyWow64RegistryMachineSoftwarePath(proc_ck.is_wow64, path_norm, &redir_buf) orelse path_norm;
            const cr = registry.createKeyFromNtPath(path_ck) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const disp_va = syscall_abi.userStackArg(frame, 16) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (disp_va != 0) {
                if (!probe.probeUserMemory(asp_ck, disp_va, 4, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
                @as(*volatile u32, @ptrFromInt(disp_va)).* = if (cr.created) ntdll.REG_CREATED_NEW_KEY else ntdll.REG_OPENED_EXISTING_KEY;
            }
            const hdr_ck = registry.keyHeaderPtr(cr.idx) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const mask_ck = ob.GENERIC_READ | ob.GENERIC_WRITE;
            const h_ck = proc_ck.handle_table.allocHandle(@intFromPtr(hdr_ck), mask_ck, .key) orelse break :blk ntResult(ntdll.STATUS_INSUFFICIENT_RESOURCES);
            @as(*volatile ntdll.HANDLE, @ptrFromInt(p1)).* = h_ck;
            break :blk 0;
        },
        ssdt.NtSetValueKey => blk: {
            const proc_sv = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_sv = proc_sv.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserUnicodeString(asp_sv, p2, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const data_va = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const data_sz_u = syscall_abi.userStackArg(frame, 8) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const data_sz: u32 = @truncate(data_sz_u);
            if (data_sz > 256) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (data_sz > 0 and data_va == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (data_sz > 0 and !probe.probeUserMemory(asp_sv, data_va, data_sz, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const us_sv = @as(*const volatile extern struct {
                Length: u16,
                MaximumLength: u16,
                Buffer: u64,
            }, @ptrFromInt(p2));
            var namebuf: [128]u8 = undefined;
            var nj: usize = 0;
            const wchar_count = @as(usize, @intCast(us_sv.Length)) / 2;
            var wi: usize = 0;
            while (wi < wchar_count and nj < namebuf.len) : (wi += 1) {
                const ch = @as(*const volatile u16, @ptrFromInt(us_sv.Buffer + wi * 2)).*;
                namebuf[nj] = if (ch < 128) @truncate(ch) else '?';
                nj += 1;
            }
            var us_local: ntdll.UNICODE_STRING = .{};
            const cpy = @min(nj, us_local.buffer.len);
            @memcpy(us_local.buffer[0..cpy], namebuf[0..cpy]);
            us_local.length = @intCast(cpy);
            var databuf: [256]u8 = undefined;
            const dslice: []const u8 = if (data_sz == 0) &[_]u8{} else ds: {
                @memcpy(databuf[0..data_sz], (@as([*]const u8, @ptrFromInt(data_va)))[0..data_sz]);
                break :ds databuf[0..data_sz];
            };
            const st_sv = ntdll.NtSetValueKey(
                p1,
                &us_local,
                @truncate(p3),
                @truncate(p4),
                dslice,
            );
            break :blk ntResult(st_sv);
        },
        ssdt.NtEnumerateKey => blk: {
            // WOW64：`KeyHandle` 须在 `NtOpenKey`/`NtCreateKey` 时已走 `Wow6432Node` 逻辑；枚举句柄本身不重写路径。
            const proc_ek = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_ek = proc_ek.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const len_ek = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const result_len_va = syscall_abi.userStackArg(frame, 8) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const len32: u32 = @truncate(len_ek);
            if (p4 == 0 or result_len_va == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_ek, result_len_va, @sizeOf(u32), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (len32 > 0 and !probe.probeUserMemory(asp_ek, p4, len32, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl_ek: *u32 = @ptrFromInt(result_len_va);
            const st_ek = ntdll.NtEnumerateKey(
                p1,
                @truncate(p2),
                @truncate(p3),
                @ptrFromInt(p4),
                len32,
                rl_ek,
            );
            break :blk ntResult(st_ek);
        },
        ssdt.NtEnumerateValueKey => blk: {
            const proc_ev = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_ev = proc_ev.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const len_ev = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const result_len_ev_va = syscall_abi.userStackArg(frame, 8) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const len_ev32: u32 = @truncate(len_ev);
            if (p4 == 0 or result_len_ev_va == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_ev, result_len_ev_va, @sizeOf(u32), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (len_ev32 > 0 and !probe.probeUserMemory(asp_ev, p4, len_ev32, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl_ev: *u32 = @ptrFromInt(result_len_ev_va);
            const st_ev = ntdll.NtEnumerateValueKey(
                p1,
                @truncate(p2),
                @truncate(p3),
                @ptrFromInt(p4),
                len_ev32,
                rl_ev,
            );
            break :blk ntResult(st_ev);
        },
        ssdt.NtReadFile => syscall_nt_extras.dispatchNtReadFile(frame),
        ssdt.NtWriteFile => syscall_nt_extras.dispatchNtWriteFile(frame),
        ssdt.NtDeviceIoControlFile => syscall_nt_extras.dispatchNtDeviceIoControlFile(frame),
        ssdt.NtLockVirtualMemory => syscall_mm.dispatchNtLockVirtualMemory(frame),
        ssdt.NtUnlockVirtualMemory => syscall_mm.dispatchNtUnlockVirtualMemory(frame),
        // `NtUserGetMessage`：空队列可 `STATUS_PENDING`（协作式阻塞）；`min>max`（且非 0,0）→ `STATUS_INVALID_PARAMETER`。
        // `NtUserPeekMessage`：空队列 `STATUS_NO_MORE_ENTRIES` + 清零 `MSG*`（映射为 PeekMessage FALSE）；有消息 `STATUS_SUCCESS`。
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPeekMessage => blk: {
            const a5 = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = user32.ntUserPeekMessageSyscall(p1, p2, @truncate(p3), @truncate(p4), @truncate(a5));
            break :blk ntResult(st);
        },
        ssdt.NtUserPostMessage => ntResult(user32.ntUserPostMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserSetWindowPos => blk: {
            const cxv = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const cyv = syscall_abi.userStackArg(frame, 8) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const flg = syscall_abi.userStackArg(frame, 16) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = user32.ntUserSetWindowPosSyscall(p1, p2, p3, p4, cxv, cyv, @truncate(flg));
            break :blk ntResult(st);
        },
        ssdt.NtUserSendMessage => ntResult(user32.ntUserSendMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserDispatchMessage => blk: {
            const proc_ud = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_ud = proc_ud.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 != 0 and !probe.probeUserMemory(asp_ud, p1, @sizeOf(user32.MSG), false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            break :blk ntResult(user32.ntUserDispatchMessageSyscall(p1));
        },
        ssdt.NtReadVirtualMemory => blk: {
            const nread_va = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const proc_rm = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_rm = proc_rm.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p3 == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_rm, p3, @truncate(p4), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (nread_va != 0 and !probe.probeUserMemory(asp_rm, nread_va, @sizeOf(usize), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = ntdll.NtReadVirtualMemory(
                @truncate(p1),
                p2,
                @ptrFromInt(p3),
                @truncate(p4),
                if (nread_va == 0) null else @ptrFromInt(nread_va),
            );
            break :blk ntResult(st);
        },
        ssdt.NtWriteVirtualMemory => blk: {
            const nw_va = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const proc_wm = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            const asp_wm = proc_wm.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p3 == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_wm, p3, @truncate(p4), false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (nw_va != 0 and !probe.probeUserMemory(asp_wm, nw_va, @sizeOf(usize), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = ntdll.NtWriteVirtualMemory(
                @truncate(p1),
                p2,
                @ptrFromInt(p3),
                @truncate(p4),
                if (nw_va == 0) null else @ptrFromInt(nw_va),
            );
            break :blk ntResult(st);
        },
        ssdt.NtCreatePort => dispatchNtCreatePort(frame),
        ssdt.NtConnectPort => dispatchNtConnectPort(frame),
        ssdt.NtRequestWaitReplyPort => syscall_nt_extras.dispatchNtRequestWaitReplyPort(frame),
        ssdt.NtDuplicateObject => syscall_nt_extras.dispatchNtDuplicateObject(frame),
        ssdt.NtDisplayString => dispatchNtDisplayString(frame),
        ssdt.NtCreateSection => syscall_mm.dispatchNtCreateSection(frame),
        ssdt.NtMapViewOfSection => syscall_mm.dispatchNtMapViewOfSection(frame),
        ssdt.NtUnmapViewOfSection => syscall_mm.dispatchNtUnmapViewOfSection(frame),
        ssdt.NtQueryVirtualMemory => blk: {
            const proc_qv = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const asp_qv = proc_qv.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const len: u32 = @truncate(syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION));
            const retlen_ptr = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (p4 != 0 and len > 0 and !probe.probeUserMemory(asp_qv, p4, len, true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_qv, retlen_ptr, @sizeOf(u32), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl: *u32 = @ptrFromInt(retlen_ptr);
            const buf: ?*anyopaque = if (p4 == 0) null else @ptrFromInt(p4);
            const st = ntdll.NtQueryVirtualMemory(p1, p2, @truncate(p3), buf, len, rl);
            break :blk ntResult(st);
        },
        ssdt.NtOpenProcess => blk: {
            const proc_op = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const asp_op = proc_op.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(asp_op, p1, @sizeOf(ntdll.HANDLE), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(asp_op, p3, 64, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const client_id = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (client_id != 0 and !probe.probeUserMemory(asp_op, client_id, 16, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var local: ntdll.HANDLE = 0;
            const st = ntdll.NtOpenProcess(&local, @truncate(p2), @ptrFromInt(p3), if (client_id == 0) null else @ptrFromInt(client_id));
            if (st != ntdll.STATUS_SUCCESS) break :blk ntResult(st);
            @as(*volatile ntdll.HANDLE, @ptrFromInt(p1)).* = local;
            break :blk 0;
        },
        ssdt.NtCreateProcess => syscall_nt_extras.dispatchNtCreateProcess(frame),
        ssdt.NtWaitForMultipleObjects => syscall_nt_extras.dispatchNtWaitForMultipleObjects(frame),
        ssdt.NtSetInformationObject => syscall_nt_extras.dispatchNtSetInformationObject(frame),
        ssdt.NtSignalAndWaitForSingleObject => syscall_nt_extras.dispatchNtSignalAndWaitForSingleObject(frame),
        ssdt.NtCreateMutant => syscall_nt_extras.dispatchNtCreateMutant(frame),
        ssdt.NtOpenMutant => syscall_nt_extras.dispatchNtOpenMutant(frame),
        ssdt.NtReleaseMutant => syscall_nt_extras.dispatchNtReleaseMutant(frame),
        ssdt.NtQueryMutant => syscall_nt_extras.dispatchNtQueryMutant(frame),
        ssdt.NtQueryInformationProcess => syscall_nt_extras.dispatchNtQueryInformationProcess(frame),
        ssdt.NtSetInformationProcess => syscall_nt_extras.dispatchNtSetInformationProcess(frame),
        ssdt.NtQueryInformationThread => syscall_nt_extras.dispatchNtQueryInformationThread(frame),
        ssdt.NtSetInformationThread => syscall_nt_extras.dispatchNtSetInformationThread(frame),
        ssdt.NtResumeThread => syscall_nt_extras.dispatchNtResumeThread(frame),
        ssdt.NtSuspendThread => syscall_nt_extras.dispatchNtSuspendThread(frame),
        ssdt.NtAlertThread => syscall_nt_extras.dispatchNtAlertThread(frame),
        ssdt.NtTestAlert => syscall_nt_extras.dispatchNtTestAlert(frame),
        ssdt.NtCreateSemaphore => syscall_nt_extras.dispatchNtCreateSemaphore(frame),
        ssdt.NtOpenSemaphore => syscall_nt_extras.dispatchNtOpenSemaphore(frame),
        ssdt.NtReleaseSemaphore => syscall_nt_extras.dispatchNtReleaseSemaphore(frame),
        ssdt.NtCreateEvent => syscall_nt_extras.dispatchNtCreateEvent(frame),
        ssdt.NtOpenEvent => syscall_nt_extras.dispatchNtOpenEvent(frame),
        ssdt.NtSetEvent => syscall_nt_extras.dispatchNtSetEvent(frame),
        ssdt.NtResetEvent => syscall_nt_extras.dispatchNtResetEvent(frame),
        ssdt.NtPulseEvent => syscall_nt_extras.dispatchNtPulseEvent(frame),
        ssdt.NtClearEvent => syscall_nt_extras.dispatchNtClearEvent(frame),
        ssdt.NtOpenThread => syscall_nt_extras.dispatchNtOpenThread(frame),
        ssdt.NtQueryObject => syscall_nt_extras.dispatchNtQueryObject(frame),
        ssdt.NtOpenFile => syscall_nt_extras.dispatchNtOpenFile(frame),
        ssdt.NtFlushBuffersFile => syscall_nt_extras.dispatchNtFlushBuffersFile(frame),
        ssdt.NtFsControlFile => syscall_nt_extras.dispatchNtFsControlFile(frame),
        ssdt.NtCancelIoFile => syscall_nt_extras.dispatchNtCancelIoFile(frame),
        ssdt.NtCancelIoFileEx => syscall_nt_extras.dispatchNtCancelIoFileEx(frame),
        ssdt.NtCreateUserProcess => syscall_nt_extras.dispatchNtCreateUserProcess(frame),
        ssdt.NtShutdownSystem => ntResult(ntdll.NtShutdownSystem(@truncate(frame.r10))),
        ssdt.NtInitiatePowerAction => ntResult(ntdll.NtInitiatePowerAction(
            @truncate(frame.r10),
            @truncate(frame.rdx),
            @truncate(frame.r8),
            @truncate(frame.r9),
        )),
        ssdt.NtCreateThreadEx,
        ssdt.NtAlpcConnectPort,
        ssdt.NtAlpcCreatePort,
        ssdt.NtAlpcSendWaitReceivePort,
        => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        else => blk: {
            klog.warn("Unknown NT syscall idx 0x%x", .{idx});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

fn dispatchNtCreatePort(frame: *InterruptFrame) i64 {
    const port_handle_user = frame.r10;
    const oa_user = frame.rdx;
    if (port_handle_user == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var name_buf: [32]u8 = undefined;
    const nm = readPortNameFromObjectAttributes(oa_user, &name_buf) orelse
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreatePort(&local, nm);
    if (st != ntdll.STATUS_SUCCESS) return ntResult(st);
    @as(*volatile u64, @ptrFromInt(port_handle_user)).* = local;
    return 0;
}

fn dispatchNtConnectPort(frame: *InterruptFrame) i64 {
    const port_handle_user = frame.r10;
    const server_name_us = frame.rdx;
    if (port_handle_user == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var name_buf: [32]u8 = undefined;
    const nm = readUserUnicodePathName(server_name_us, &name_buf) orelse
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtConnectPort(&local, nm);
    if (st != ntdll.STATUS_SUCCESS) return ntResult(st);
    @as(*volatile u64, @ptrFromInt(port_handle_user)).* = local;
    return 0;
}

fn dispatchNtDisplayString(frame: *InterruptFrame) i64 {
    const us_ptr = frame.r10;
    var buf: [256]u8 = undefined;
    const slice = readUserUnicodeForDisplay(us_ptr, &buf) orelse
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const arch_mod = @import("../../arch.zig");
    arch_mod.consoleWrite(slice);
    arch_mod.consoleWrite("\r\n");
    return 0;
}
