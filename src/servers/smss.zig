//! Session Manager Subsystem (SMSS) - NT style
//! Manages sessions, starts subsystem hosts (CSRSS), and manages the boot sequence.
//! Implements the NT-style session manager process.

const process = @import("../ps/process.zig");
const ipc = @import("../lpc/ipc.zig");
const port = @import("../lpc/port.zig");
const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");
const FrameAllocator = @import("../mm/frame.zig").FrameAllocator;

pub const SMSS_PID: u32 = 2;
const MAX_SESSIONS: usize = 8;
const MAX_SUBSYSTEMS: usize = 16;

pub const SessionState = enum {
    creating,
    active,
    disconnected,
    terminated,
};

pub const Session = struct {
    id: u32 = 0,
    state: SessionState = .creating,
    process_count: u32 = 0,
    csrss_pid: u32 = 0,
    winlogon_pid: u32 = 0,
    shell_pid: u32 = 0,
    is_console: bool = false,
};

pub const SubsystemType = enum(u8) {
    native = 0,
    win32 = 1,
    posix = 2,
    wow64 = 3,
};

pub const SubsystemInfo = struct {
    sub_type: SubsystemType = .native,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    server_pid: u32 = 0,
    is_active: bool = false,
    port_name: [32]u8 = [_]u8{0} ** 32,
    port_name_len: usize = 0,
};

var sessions: [MAX_SESSIONS]Session = [_]Session{.{}} ** MAX_SESSIONS;
var session_count: u32 = 0;
var next_session_id: u32 = 0;

var subsystems: [MAX_SUBSYSTEMS]SubsystemInfo = [_]SubsystemInfo{.{}} ** MAX_SUBSYSTEMS;
var subsystem_count: usize = 0;

var smss_initialized: bool = false;
var smss_port: ?*port.Port = null;

pub fn init(alloc: *FrameAllocator) void {
    session_count = 0;
    next_session_id = 0;
    subsystem_count = 0;

    smss_port = port.createPort(SMSS_PID, "\\LPC\\SmssServer");

    const smss_proc = process.createSystemProcess(alloc, "smss");
    if (smss_proc) |_| {
        klog.info("SMSS: Session Manager started", .{});
    }

    _ = createSession(true);

    registerSubsystem(.native, "Native", "\\LPC\\NativeSubsys");
    registerSubsystem(.win32, "Win32", "\\LPC\\Win32Subsys");

    smss_initialized = true;
    klog.info("SMSS: %u sessions, %u subsystems registered", .{ session_count, subsystem_count });
}

pub fn createSession(is_console: bool) ?u32 {
    if (session_count >= MAX_SESSIONS) return null;

    const id = next_session_id;
    next_session_id += 1;

    var session = &sessions[session_count];
    session.* = .{};
    session.id = id;
    session.state = .active;
    session.is_console = is_console;
    session_count += 1;

    _ = ob.insertNamespace("\\Sessions\\0", .directory, 0, 3);

    klog.info("SMSS: Session %u created (console=%u)", .{ id, @as(u32, if (is_console) 1 else 0) });
    return id;
}

fn registerSubsystem(sub_type: SubsystemType, name: []const u8, port_name: []const u8) void {
    if (subsystem_count >= MAX_SUBSYSTEMS) return;

    var sub = &subsystems[subsystem_count];
    sub.* = .{};
    sub.sub_type = sub_type;
    sub.is_active = true;

    const name_copy = @min(name.len, sub.name.len);
    @memcpy(sub.name[0..name_copy], name[0..name_copy]);
    sub.name_len = name_copy;

    const port_copy = @min(port_name.len, sub.port_name.len);
    @memcpy(sub.port_name[0..port_copy], port_name[0..port_copy]);
    sub.port_name_len = port_copy;

    _ = port.createPort(SMSS_PID, port_name);

    subsystem_count += 1;
    klog.debug("SMSS: Subsystem '%s' registered (port=%s)", .{ name, port_name });
}

pub fn handleMessage() void {
    if (!smss_initialized) return;
    const msg = ipc.receive(SMSS_PID) orelse return;

    switch (msg.opcode) {
        1 => {
            const sid = createSession(false);
            var reply: [ipc.MSG_DATA_SIZE]u8 = [_]u8{0} ** ipc.MSG_DATA_SIZE;
            if (sid) |s| {
                reply[0] = @intCast(s & 0xFF);
                reply[1] = @intCast((s >> 8) & 0xFF);
            }
            _ = ipc.send(SMSS_PID, msg.sender, msg.opcode, &reply);
        },
        2 => {
            var reply: [ipc.MSG_DATA_SIZE]u8 = [_]u8{0} ** ipc.MSG_DATA_SIZE;
            reply[0] = @intCast(session_count & 0xFF);
            _ = ipc.send(SMSS_PID, msg.sender, msg.opcode, &reply);
        },
        else => {
            klog.debug("SMSS: Unknown opcode %u from pid %u", .{ msg.opcode, msg.sender });
        },
    }
}

pub fn getSessionCount() u32 {
    return session_count;
}

pub fn getSession(id: u32) ?*Session {
    for (sessions[0..session_count]) |*s| {
        if (s.id == id) return s;
    }
    return null;
}

pub fn getSubsystemCount() usize {
    return subsystem_count;
}

pub fn isInitialized() bool {
    return smss_initialized;
}
