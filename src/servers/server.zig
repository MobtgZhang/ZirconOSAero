//! Process Server - NT style system service
//! Handles process/thread creation and termination via IPC

const process = @import("../ps/process.zig");
const ipc = @import("../lpc/ipc.zig");
const FrameAllocator = @import("../mm/frame.zig").FrameAllocator;
const klog = @import("../rtl/klog.zig");

pub const PROCESS_SERVER_PID: u32 = 1;

pub const OP_CREATE_PROCESS: u32 = 1;
pub const OP_CREATE_THREAD: u32 = 2;
pub const OP_TERMINATE_PROCESS: u32 = 3;
pub const OP_QUERY_PROCESS: u32 = 4;
pub const OP_SUSPEND_PROCESS: u32 = 5;
pub const OP_RESUME_PROCESS: u32 = 6;

var frame_alloc: ?*FrameAllocator = null;
var server_initialized: bool = false;

pub fn init(alloc: *FrameAllocator) void {
    frame_alloc = alloc;
    process.init();

    const p = process.createSystemProcess(alloc, "System");
    if (p) |proc| {
        proc.is_system = true;
        process.setCurrentProcess(proc.pid);
        klog.info("Process Server (PID %u) started", .{proc.pid});
    } else {
        klog.err("Failed to create Process Server", .{});
    }

    server_initialized = true;
}

pub fn handleMessage() void {
    const msg = ipc.receive(PROCESS_SERVER_PID) orelse return;

    const sender = msg.sender;
    const opcode = msg.opcode;

    var reply_data: [ipc.MSG_DATA_SIZE]u8 = undefined;
    @memset(&reply_data, 0);

    switch (opcode) {
        OP_CREATE_PROCESS => {
            if (frame_alloc) |alloc| {
                const p = process.createProcess(alloc);
                if (p) |proc| {
                    proc.parent_pid = sender;
                    writeU32(&reply_data, proc.pid);
                    klog.debug("PsServer: process created (pid=%u, parent=%u)", .{
                        proc.pid, sender,
                    });
                }
            }
        },
        OP_CREATE_THREAD => {
            const tid = process.allocTid() orelse 0;
            writeU32(&reply_data, tid);
        },
        OP_TERMINATE_PROCESS => {
            const pid = readU32(&msg.data);
            const exit_code = readU32(msg.data[4..]);
            _ = process.terminateProcess(pid, exit_code);
        },
        OP_QUERY_PROCESS => {
            const pid = readU32(&msg.data);
            const p = process.findProcess(pid);
            if (p) |proc| {
                writeU32(&reply_data, proc.pid);
                reply_data[4] = @intFromEnum(proc.state);
                reply_data[5] = if (proc.is_system) 1 else 0;
            }
        },
        OP_SUSPEND_PROCESS => {
            const pid = readU32(&msg.data);
            const p = process.findProcess(pid);
            if (p) |proc| {
                proc.state = .suspended;
            }
        },
        OP_RESUME_PROCESS => {
            const pid = readU32(&msg.data);
            const p = process.findProcess(pid);
            if (p) |proc| {
                if (proc.state == .suspended) proc.state = .active;
            }
        },
        else => {
            klog.warn("PsServer: unknown opcode %u from sender %u", .{ opcode, sender });
        },
    }

    _ = ipc.send(PROCESS_SERVER_PID, sender, opcode, &reply_data);
}

fn writeU32(buf: []u8, value: u32) void {
    if (buf.len < 4) return;
    buf[0] = @intCast(value & 0xFF);
    buf[1] = @intCast((value >> 8) & 0xFF);
    buf[2] = @intCast((value >> 16) & 0xFF);
    buf[3] = @intCast((value >> 24) & 0xFF);
}

fn readU32(buf: []const u8) u32 {
    if (buf.len < 4) return 0;
    return @as(u32, buf[0]) |
        (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) |
        (@as(u32, buf[3]) << 24);
}

pub fn isInitialized() bool {
    return server_initialized;
}
