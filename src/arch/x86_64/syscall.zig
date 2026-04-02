//! x86_64 系统调用分发：`syscall` 与 `int 0x80`（向量 128）共用本模块与同一 **NT 6.1 x64** 寄存器约定。
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
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;
const user32 = @import("../../subsystems/win32/user32.zig");

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
    var asp = proc.address_space orelse return null;
    if (!probe.probeUserUnicodeString(&asp, unicode_str_va, false)) return null;
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
    var asp_u = proc_u.address_space orelse return null;
    if (!probe.probeUserUnicodeString(&asp_u, unicode_str_va, false)) return null;
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
    var asp_r = proc_r.address_space orelse return null;
    if (!probe.probeUserMemory(&asp_r, obj_attr_va, 64, false)) return null;
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
    var asp = proc.address_space orelse return null;
    if (!probe.probeUserUnicodeString(&asp, unicode_str_va, false)) return null;
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
}

fn dispatchNtSsdt(frame: *InterruptFrame, idx: u32) i64 {
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
        ssdt.NtAllocateVirtualMemory => blk: {
            const a5 = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const a6 = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = ntdll.NtAllocateVirtualMemory(
                p1,
                @ptrFromInt(p2),
                p3,
                @ptrFromInt(p4),
                @truncate(a5),
                @truncate(a6),
            );
            break :blk ntResult(st);
        },
        ssdt.NtFreeVirtualMemory => blk: {
            const st = ntdll.NtFreeVirtualMemory(
                p1,
                @ptrFromInt(p2),
                @ptrFromInt(p3),
                @truncate(p4),
            );
            break :blk ntResult(st);
        },
        ssdt.NtQuerySystemInformation => blk: {
            const len: u32 = @truncate(p3);
            const buf_ptr = p2;
            if (buf_ptr == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const proc_q = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            var asp_q = proc_q.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (len > 0 and !probe.probeUserMemory(&asp_q, buf_ptr, len, true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_q, p4, @sizeOf(u32), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl: *u32 = @ptrFromInt(p4);
            const buf: [*]u8 = @ptrFromInt(buf_ptr);
            const st = ntdll.NtQuerySystemInformation(@truncate(p1), buf[0..len], rl);
            break :blk ntResult(st);
        },
        ssdt.NtCreateFile => blk: {
            const proc_f = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            var asp_f = proc_f.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p3 == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_f, p3, 64, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_f, p4, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
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
        ssdt.NtProtectVirtualMemory => blk: {
            const oldp_slot = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const proc_pr = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            var asp_pr = proc_pr.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p2 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_pr, p2, 8, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_pr, p3, 8, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var oldp_opt: ?*u32 = null;
            if (oldp_slot != 0) {
                if (!probe.probeUserMemory(&asp_pr, oldp_slot, 4, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
                oldp_opt = @ptrFromInt(oldp_slot);
            }
            const st = ntdll.NtProtectVirtualMemory(
                p1,
                @ptrFromInt(p2),
                @ptrFromInt(p3),
                @truncate(p4),
                oldp_opt,
            );
            break :blk ntResult(st);
        },
        ssdt.NtDelayExecution => blk: {
            const proc_de = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            var asp_de = proc_de.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_de, p2, 8, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const interval = @as(*const volatile i64, @ptrFromInt(p2)).*;
            const st = ntdll.NtDelayExecution(@truncate(p1), interval);
            break :blk ntResult(st);
        },
        ssdt.NtOpenKey => blk: {
            const proc_ok = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            var asp_ok = proc_ok.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_ok, p1, @sizeOf(ntdll.HANDLE), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_ok, p3, 64, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var pathbuf: [512]u8 = undefined;
            const raw = readRegPathFromObjectAttributes(p3, &pathbuf) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const path_norm = ob.normalizeNtObjectPath(raw);
            const reg_key_idx = registry.openKeyByNtPath(path_norm) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const hdr = registry.keyHeaderPtr(reg_key_idx) orelse break :blk ntResult(ntdll.STATUS_OBJECT_NAME_NOT_FOUND);
            const h = proc_ok.handle_table.allocHandle(@intFromPtr(hdr), ob.GENERIC_READ, .key) orelse break :blk ntResult(ntdll.STATUS_INSUFFICIENT_RESOURCES);
            @as(*volatile ntdll.HANDLE, @ptrFromInt(p1)).* = h;
            break :blk 0;
        },
        ssdt.NtQueryValueKey => blk: {
            const proc_qvk = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_HANDLE);
            var asp_qvk = proc_qvk.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const stack_len = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const result_len_va = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const len: u32 = @truncate(stack_len);
            if (p2 == 0 or p4 == 0 or result_len_va == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserUnicodeString(&asp_qvk, p2, false)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_qvk, result_len_va, @sizeOf(u32), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (len > 0 and !probe.probeUserMemory(&asp_qvk, p4, len, true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
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
            var asp_ck = proc_ck.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_ck, p1, @sizeOf(ntdll.HANDLE), true)) break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = ntdll.NtCreateKey(
                @ptrFromInt(p1),
                @truncate(p2),
                null,
                0,
                null,
                0,
                null,
            );
            break :blk ntResult(st);
        },
        ssdt.NtSetValueKey => blk: {
            const empty: []const u8 = &.{};
            const st = ntdll.NtSetValueKey(p1, empty, 0, 0, empty);
            break :blk ntResult(st);
        },
        ssdt.NtReadFile => syscall_nt_extras.dispatchNtReadFile(frame),
        ssdt.NtWriteFile => syscall_nt_extras.dispatchNtWriteFile(frame),
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPeekMessage => blk: {
            const a5 = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = user32.ntUserPeekMessageSyscall(p1, p2, @truncate(p3), @truncate(p4), @truncate(a5));
            break :blk ntResult(st);
        },
        ssdt.NtCreatePort => dispatchNtCreatePort(frame),
        ssdt.NtConnectPort => dispatchNtConnectPort(frame),
        ssdt.NtRequestWaitReplyPort => syscall_nt_extras.dispatchNtRequestWaitReplyPort(frame),
        ssdt.NtDuplicateObject => syscall_nt_extras.dispatchNtDuplicateObject(frame),
        ssdt.NtDisplayString => dispatchNtDisplayString(frame),
        ssdt.NtCreateSection => dispatchNtCreateSection(frame),
        ssdt.NtMapViewOfSection => dispatchNtMapViewOfSection(frame),
        ssdt.NtUnmapViewOfSection => blk: {
            const st = ntdll.NtUnmapViewOfSection(p1, p2);
            break :blk ntResult(st);
        },
        ssdt.NtQueryVirtualMemory => blk: {
            const proc_qv = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            var asp_qv = proc_qv.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const len: u32 = @truncate(syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION));
            const retlen_ptr = syscall_abi.userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (p4 != 0 and len > 0 and !probe.probeUserMemory(&asp_qv, p4, len, true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_qv, retlen_ptr, @sizeOf(u32), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const rl: *u32 = @ptrFromInt(retlen_ptr);
            const buf: ?*anyopaque = if (p4 == 0) null else @ptrFromInt(p4);
            const st = ntdll.NtQueryVirtualMemory(p1, p2, @truncate(p3), buf, len, rl);
            break :blk ntResult(st);
        },
        ssdt.NtOpenProcess => blk: {
            const proc_op = process.getCurrentProcess() orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            var asp_op = proc_op.address_space orelse break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (p1 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            if (!probe.probeUserMemory(&asp_op, p1, @sizeOf(ntdll.HANDLE), true))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (!probe.probeUserMemory(&asp_op, p3, 64, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const client_id = syscall_abi.userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            if (client_id != 0 and !probe.probeUserMemory(&asp_op, client_id, 16, false))
                break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            var local: ntdll.HANDLE = 0;
            const st = ntdll.NtOpenProcess(&local, @truncate(p2), @ptrFromInt(p3), if (client_id == 0) null else @ptrFromInt(client_id));
            if (st != ntdll.STATUS_SUCCESS) break :blk ntResult(st);
            @as(*volatile ntdll.HANDLE, @ptrFromInt(p1)).* = local;
            break :blk 0;
        },
        else => blk: {
            klog.warn("Unknown NT syscall idx 0x%x", .{idx});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

fn dispatchNtCreateSection(frame: *InterruptFrame) i64 {
    const out_handle = frame.r10;
    const max_sz_ptr = frame.r9;
    if (out_handle == 0 or max_sz_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc_s = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var asp_s = proc_s.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp_s, out_handle, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(&asp_s, max_sz_ptr, @sizeOf(u64), false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const page_prot = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const alloc_attr = syscall_abi.userStackArg(frame, 1) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const file_handle = syscall_abi.userStackArg(frame, 2) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    _ = frame.r8; // ObjectAttributes — ntdll 当前忽略；命名节见 MM 路线图
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateSection(
        &local,
        @truncate(frame.rdx),
        null,
        @ptrFromInt(max_sz_ptr),
        @truncate(page_prot),
        @truncate(alloc_attr),
        @truncate(file_handle),
    );
    if (st != ntdll.STATUS_SUCCESS) return ntResult(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_handle)).* = local;
    return 0;
}

fn dispatchNtMapViewOfSection(frame: *InterruptFrame) i64 {
    const base_user = frame.r8;
    const view_sz_ptr = syscall_abi.userStackArg(frame, 2) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (base_user == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc_m = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    var asp_m = proc_m.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp_m, base_user, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(&asp_m, view_sz_ptr, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const sec_off_stack = syscall_abi.userStackArg(frame, 1) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (sec_off_stack != 0) {
        if (!probe.probeUserMemory(&asp_m, sec_off_stack, @sizeOf(u64), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    }
    const commit_sz = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const inherit_disp = syscall_abi.userStackArg(frame, 3) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const alloc_type = syscall_abi.userStackArg(frame, 4) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const win_prot = syscall_abi.userStackArg(frame, 5) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtMapViewOfSection(
        @truncate(frame.r10),
        frame.rdx,
        @ptrFromInt(base_user),
        frame.r9,
        commit_sz,
        if (sec_off_stack == 0) null else @ptrFromInt(sec_off_stack),
        @ptrFromInt(view_sz_ptr),
        @truncate(inherit_disp),
        @truncate(alloc_type),
        @truncate(win_prot),
    );
    return ntResult(st);
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

