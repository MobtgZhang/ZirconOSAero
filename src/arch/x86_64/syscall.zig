//! x86_64 系统调用分发：`syscall` 与 `int 0x80`（向量 128）共用本模块与同一 **NT 6.1 x64** 寄存器约定。
//! - **服务号**：`ssdt_nt61.zig` 中公开 SSDT 索引（Windows 7 SP1 x64 参考：j00ru/windows-syscalls）。
//! - **约定**：第 1 参在 **R10**（`syscall` 时 RCX 存用户 RIP，故不用 RCX 传参）；第 2–4 参为 **RDX/R8/R9**；其余在用户栈。

const process = @import("../../ps/process.zig");
const klog = @import("../../rtl/klog.zig");
const ob = @import("../../ob/object.zig");
const ntdll = @import("../../libs/ntdll.zig");
const ssdt = @import("ssdt_nt61.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;
const user32 = @import("../../subsystems/win32/user32.zig");

fn ntResult(s: ntdll.NTSTATUS) i64 {
    return @intCast(s);
}

pub const STATUS_SUCCESS: i64 = 0;
pub const STATUS_NO_MESSAGE: i64 = -3;
pub const STATUS_NOT_IMPLEMENTED: i64 = @intCast(ntdll.STATUS_NOT_IMPLEMENTED);

/// 自用户栈读取第 N 个 syscall 扩展参数（N=0 → 第 5 个实参），偏移相对 SYSCALL 时的用户 RSP。
fn userStackArg(frame: *InterruptFrame, nth_stack_arg: u8) ?u64 {
    const proc = process.getCurrentProcess() orelse return null;
    var asp = proc.address_space orelse return null;
    const off: u64 = 0x28 + @as(u64, nth_stack_arg) * 8;
    if (frame.rsp > 0xFFFF_FFFF_FFFF_F000) return null;
    const va = frame.rsp +% off;
    if (va < frame.rsp) return null;
    const aligned = va & ~@as(u64, 7);
    _ = asp.getPhysical(aligned) orelse return null;
    // SAFETY: 已确认页映射存在；地址来自用户 RSP + 固定 Win64 syscall 栈偏移。
    return @as(*const volatile u64, @ptrFromInt(va)).*;
}

/// 自用户态 `UNICODE_STRING`（Length 为字节数）读取窄字符名到 `out`（UTF-16LE 低字节，非 ASCII 置 `?`）。
fn readUserUnicodePathName(unicode_str_va: u64, out: *[32]u8) ?[]const u8 {
    if (unicode_str_va == 0) return null;
    // SAFETY: 用户指针；仅用于 syscall 路径，与现有内核用户指针策略一致。
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
            const a5 = userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const a6 = userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
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
            if (buf_ptr == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const rl: *u32 = @ptrFromInt(p4);
            const buf: [*]u8 = @ptrFromInt(buf_ptr);
            const st = ntdll.NtQuerySystemInformation(@truncate(p1), buf[0..len], rl);
            break :blk ntResult(st);
        },
        ssdt.NtCreateFile => blk: {
            const io = p4;
            const alloc_sz = userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const fa = userStackArg(frame, 1) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const sh = userStackArg(frame, 2) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const disp = userStackArg(frame, 3) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const opt = userStackArg(frame, 4) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const ea = userStackArg(frame, 5) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const ealen: u32 = @truncate(userStackArg(frame, 6) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION));
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
        ssdt.NtClose => handleCloseHandle(p1),
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
        ssdt.NtReadFile, ssdt.NtWriteFile => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPeekMessage => blk: {
            const a5 = userStackArg(frame, 0) orelse break :blk ntResult(ntdll.STATUS_ACCESS_VIOLATION);
            const st = user32.ntUserPeekMessageSyscall(p1, p2, @truncate(p3), @truncate(p4), @truncate(a5));
            break :blk ntResult(st);
        },
        ssdt.NtCreatePort => dispatchNtCreatePort(frame),
        ssdt.NtConnectPort => dispatchNtConnectPort(frame),
        ssdt.NtRequestWaitReplyPort => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtDisplayString => dispatchNtDisplayString(frame),
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

fn handleCloseHandle(handle_val: u64) i64 {
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const handle: ob.Handle = @intCast(handle_val);
    if (proc.handle_table.closeHandle(handle)) {
        return 0;
    }
    return ntResult(ntdll.STATUS_INVALID_PARAMETER);
}
