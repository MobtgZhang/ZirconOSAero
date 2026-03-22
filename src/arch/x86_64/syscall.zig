//! Syscall dispatch for x86_64
//! int 0x80 (vector 128): rax=syscall_no, rdi,rsi,rdx,r10,r8,r9=args
//! Return value placed in frame.rax

const ipc = @import("../../lpc/ipc.zig");
const process = @import("../../ps/process.zig");
const klog = @import("../../rtl/klog.zig");
const ob = @import("../../ob/object.zig");
const vm = @import("../../mm/vm.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

pub const SYS_CREATE_PROCESS: u64 = 0;
pub const SYS_CREATE_THREAD: u64 = 1;
pub const SYS_IPC_SEND: u64 = 2;
pub const SYS_IPC_RECEIVE: u64 = 3;
pub const SYS_MAP_MEMORY: u64 = 4;
pub const SYS_UNMAP_MEMORY: u64 = 5;
pub const SYS_EXIT_PROCESS: u64 = 6;
pub const SYS_OPEN_HANDLE: u64 = 7;
pub const SYS_CLOSE_HANDLE: u64 = 8;
pub const SYS_WAIT_OBJECT: u64 = 9;
pub const SYS_CREATE_PORT: u64 = 10;
pub const SYS_CONNECT_PORT: u64 = 11;
pub const SYS_GET_PID: u64 = 12;
pub const SYS_YIELD: u64 = 13;
pub const SYS_DEBUG_PRINT: u64 = 14;

pub const STATUS_SUCCESS: i64 = 0;
pub const STATUS_INVALID_PARAMETER: i64 = -1;
pub const STATUS_QUEUE_FULL: i64 = -2;
pub const STATUS_NO_MESSAGE: i64 = -3;
pub const STATUS_ACCESS_DENIED: i64 = -4;
pub const STATUS_NO_MEMORY: i64 = -5;

pub fn dispatch(frame: *InterruptFrame) void {
    const syscall_no = frame.rax;
    const arg1 = frame.rdi;
    const arg2 = frame.rsi;
    const arg3 = frame.rdx;
    _ = frame.r10;
    _ = frame.r8;
    _ = frame.r9;

    const result: i64 = switch (syscall_no) {
        SYS_IPC_SEND => handleIpcSend(arg1, arg2, arg3),
        SYS_IPC_RECEIVE => handleIpcReceive(arg1),
        SYS_CREATE_PROCESS => handleCreateProcess(arg1),
        SYS_CREATE_THREAD => handleCreateThread(arg1, arg2),
        SYS_MAP_MEMORY => handleMapMemory(arg1, arg2, arg3),
        SYS_EXIT_PROCESS => handleExitProcess(arg1),
        SYS_CLOSE_HANDLE => handleCloseHandle(arg1),
        SYS_GET_PID => @intCast(process.getCurrentPid()),
        SYS_YIELD => blk: {
            const scheduler = @import("../../ke/scheduler.zig");
            scheduler.yield();
            break :blk STATUS_SUCCESS;
        },
        SYS_DEBUG_PRINT => handleDebugPrint(arg1, arg2),
        else => blk: {
            klog.warn("Unknown syscall %u", .{syscall_no});
            break :blk STATUS_INVALID_PARAMETER;
        },
    };

    frame.rax = @bitCast(result);
}

fn handleIpcSend(sender: u64, receiver: u64, opcode: u64) i64 {
    return ipc.send(@intCast(sender), @intCast(receiver), @intCast(opcode), null);
}

fn handleIpcReceive(_: u64) i64 {
    const msg = ipc.receive(process.getCurrentPid());
    if (msg) |m| {
        return @intCast(m.sender);
    }
    return STATUS_NO_MESSAGE;
}

fn handleCreateProcess(frame_alloc_ptr: u64) i64 {
    if (frame_alloc_ptr == 0) return STATUS_INVALID_PARAMETER;
    const alloc = @as(*@import("../../mm/frame.zig").FrameAllocator, @ptrFromInt(frame_alloc_ptr));
    const p = process.createProcess(alloc);
    if (p) |proc| {
        return @intCast(proc.pid);
    }
    return STATUS_NO_MEMORY;
}

fn handleCreateThread(_: u64, _: u64) i64 {
    const tid = process.allocTid() orelse return STATUS_NO_MEMORY;
    return @intCast(tid);
}

fn handleMapMemory(virt: u64, _: u64, _: u64) i64 {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_PARAMETER;
    if (proc.address_space) |*space| {
        const flags = vm.MapFlags{ .writable = true, .user = true };
        if (space.mapPageAlloc(virt, flags)) |_| {
            return STATUS_SUCCESS;
        }
    }
    return STATUS_NO_MEMORY;
}

fn handleExitProcess(exit_code: u64) i64 {
    const pid = process.getCurrentPid();
    _ = process.terminateProcess(pid, @intCast(exit_code));
    return STATUS_SUCCESS;
}

fn handleCloseHandle(handle_val: u64) i64 {
    const proc = process.getCurrentProcess() orelse return STATUS_INVALID_PARAMETER;
    const handle: ob.Handle = @intCast(handle_val);
    if (proc.handle_table.closeHandle(handle)) {
        return STATUS_SUCCESS;
    }
    return STATUS_INVALID_PARAMETER;
}

fn handleDebugPrint(buf_ptr: u64, len: u64) i64 {
    if (buf_ptr == 0 or len == 0 or len > 256) return STATUS_INVALID_PARAMETER;
    const ptr = @as([*]const u8, @ptrFromInt(buf_ptr));
    const slice = ptr[0..@intCast(len)];
    const arch = @import("../../arch.zig");
    arch.consoleWrite(slice);
    return STATUS_SUCCESS;
}
