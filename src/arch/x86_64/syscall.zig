//! x86_64 系统调用分发：`syscall` / `int 0x80`（向量 128）共用本模块。
//! - **NT 6.1 x64 SSDT 索引**（子集）：见 `ssdt_nt61.zig`；AMD64 约定第 1 参在 **R10**。
//! - **Zircon 遗留**：`ssdt_nt61.zircon_legacy_syscall_base + 0..15`，参数为 **RDI/RSI/RDX**（兼容旧 `int 0x80` 测试）。

const ipc = @import("../../lpc/ipc.zig");
const lpc_port = @import("../../lpc/port.zig");
const process = @import("../../ps/process.zig");
const klog = @import("../../rtl/klog.zig");
const ob = @import("../../ob/object.zig");
const vm = @import("../../mm/vm.zig");
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

/// 遗留常量（= `zircon_legacy_syscall_base + ord`）；新代码请使用 SSDT 号或本模块 `dispatch` 自动识别。
pub const SYS_CREATE_PROCESS: u64 = ssdt.zircon_legacy_syscall_base + 0;
pub const SYS_CREATE_THREAD: u64 = ssdt.zircon_legacy_syscall_base + 1;
pub const SYS_IPC_SEND: u64 = ssdt.zircon_legacy_syscall_base + 2;
pub const SYS_IPC_RECEIVE: u64 = ssdt.zircon_legacy_syscall_base + 3;
pub const SYS_MAP_MEMORY: u64 = ssdt.zircon_legacy_syscall_base + 4;
pub const SYS_UNMAP_MEMORY: u64 = ssdt.zircon_legacy_syscall_base + 5;
pub const SYS_EXIT_PROCESS: u64 = ssdt.zircon_legacy_syscall_base + 6;
pub const SYS_OPEN_HANDLE: u64 = ssdt.zircon_legacy_syscall_base + 7;
pub const SYS_CLOSE_HANDLE: u64 = ssdt.zircon_legacy_syscall_base + 8;
pub const SYS_WAIT_OBJECT: u64 = ssdt.zircon_legacy_syscall_base + 9;
pub const SYS_CREATE_PORT: u64 = ssdt.zircon_legacy_syscall_base + 10;
pub const SYS_CONNECT_PORT: u64 = ssdt.zircon_legacy_syscall_base + 11;
pub const SYS_GET_PID: u64 = ssdt.zircon_legacy_syscall_base + 12;
pub const SYS_YIELD: u64 = ssdt.zircon_legacy_syscall_base + 13;
pub const SYS_DEBUG_PRINT: u64 = ssdt.zircon_legacy_syscall_base + 14;

fn isLegacyZircon(syscall_no: u64) bool {
    return syscall_no >= ssdt.zircon_legacy_syscall_base and
        syscall_no < ssdt.zircon_legacy_syscall_base + 16;
}

fn legacyOrdinal(syscall_no: u64) u64 {
    return syscall_no - ssdt.zircon_legacy_syscall_base;
}

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

pub fn dispatch(frame: *InterruptFrame) void {
    const syscall_no = frame.rax;

    const result: i64 = if (isLegacyZircon(syscall_no))
        dispatchLegacy(frame, legacyOrdinal(syscall_no))
    else
        dispatchNtSsdt(frame, @truncate(syscall_no));

    frame.rax = @bitCast(result);
}

fn dispatchLegacy(frame: *InterruptFrame, ord: u64) i64 {
    const arg1 = frame.rdi;
    const arg2 = frame.rsi;
    const arg3 = frame.rdx;
    return switch (ord) {
        0 => handleCreateProcess(arg1),
        1 => handleCreateThread(arg1, arg2),
        2 => handleIpcSend(arg1, arg2, arg3),
        3 => handleIpcReceive(arg1),
        4 => handleMapMemory(arg1, arg2, arg3),
        5 => handleUnmapMemory(arg1),
        6 => handleExitProcess(arg1),
        7 => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        8 => handleCloseHandle(arg1),
        9 => STATUS_SUCCESS,
        10 => handleCreatePort(arg1, arg2),
        11 => handleConnectPort(arg1, arg2),
        12 => @intCast(process.getCurrentPid()),
        13 => blk: {
            const scheduler = @import("../../ke/scheduler.zig");
            scheduler.yield();
            break :blk 0;
        },
        14 => handleDebugPrint(arg1, arg2),
        else => blk: {
            klog.warn("Unknown legacy syscall ord %u", .{ord});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
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
        else => blk: {
            klog.warn("Unknown NT syscall idx 0x%x", .{idx});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

fn handleIpcSend(sender: u64, receiver: u64, opcode: u64) i64 {
    const r = ipc.send(@intCast(sender), @intCast(receiver), @intCast(opcode), null);
    if (r == 0) return 0;
    if (r == -2) return ntResult(ntdll.STATUS_INSUFFICIENT_RESOURCES);
    return ntResult(ntdll.STATUS_INVALID_PARAMETER);
}

fn handleIpcReceive(_: u64) i64 {
    const msg = ipc.receive(process.getCurrentPid());
    if (msg) |m| {
        return @intCast(m.sender);
    }
    return STATUS_NO_MESSAGE;
}

fn handleCreateProcess(frame_alloc_ptr: u64) i64 {
    if (frame_alloc_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const alloc = @as(*@import("../../mm/frame.zig").FrameAllocator, @ptrFromInt(frame_alloc_ptr));
    const p = process.createProcess(alloc);
    if (p) |proc| {
        return @intCast(proc.pid);
    }
    return ntResult(ntdll.STATUS_NO_MEMORY);
}

fn handleCreateThread(_: u64, _: u64) i64 {
    const tid = process.allocTid() orelse return ntResult(ntdll.STATUS_NO_MEMORY);
    return @intCast(tid);
}

fn handleMapMemory(virt: u64, _: u64, _: u64) i64 {
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (virt & 0xFFF != 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (proc.address_space) |*space| {
        const flags = vm.MapFlags{ .writable = true, .user = true };
        if (space.mapPageAlloc(virt, flags)) |_| {
            return 0;
        }
    }
    return ntResult(ntdll.STATUS_NO_MEMORY);
}

fn handleUnmapMemory(virt: u64) i64 {
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (virt & 0xFFF != 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (proc.address_space) |*space| {
        _ = space.unmapPage(virt);
        return 0;
    }
    return ntResult(ntdll.STATUS_INVALID_PARAMETER);
}

fn copyNameArg(name_ptr: u64, name_len: u64, out: *[32]u8) ?[]const u8 {
    if (name_ptr == 0 or name_len == 0 or name_len > out.len) return null;
    const p = @as([*]const u8, @ptrFromInt(name_ptr));
    @memcpy(out[0..name_len], p[0..name_len]);
    return out[0..name_len];
}

fn handleCreatePort(name_ptr: u64, name_len: u64) i64 {
    var buf: [32]u8 = undefined;
    const nm = copyNameArg(name_ptr, name_len, &buf) orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const pid = process.getCurrentPid();
    const pt = lpc_port.createPort(pid, nm) orelse return ntResult(ntdll.STATUS_NO_MEMORY);
    return @intCast(pt.id);
}

fn handleConnectPort(name_ptr: u64, name_len: u64) i64 {
    var buf: [32]u8 = undefined;
    const nm = copyNameArg(name_ptr, name_len, &buf) orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const pid = process.getCurrentPid();
    const pt = lpc_port.connectPort(pid, nm) orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    return @intCast(pt.id);
}

fn handleExitProcess(exit_code: u64) i64 {
    const pid = process.getCurrentPid();
    _ = process.terminateProcess(pid, @intCast(exit_code));
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

fn handleDebugPrint(buf_ptr: u64, len: u64) i64 {
    if (buf_ptr == 0 or len == 0 or len > 256) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const ptr = @as([*]const u8, @ptrFromInt(buf_ptr));
    const slice = ptr[0..@intCast(len)];
    const arch = @import("../../arch.zig");
    arch.consoleWrite(slice);
    return 0;
}
