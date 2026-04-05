//! LPC Port Implementation
//! NT-style port-based IPC: CreatePort, ConnectPort, RequestWaitReply
//!
//! Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/local-procedure-calls-lpc-
//!
//! 里程碑：[docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K6.4（与 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md) 同步）。
//! **P4-C4**：SMP 下端口队列与 `ipc` 消息环的细粒度锁为长期项；当前假定引导早期单线程初始化路径。

const std = @import("std");
const arch = @import("../arch.zig");
const ipc = @import("ipc.zig");
const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");
const sched = @import("../ke/scheduler.zig");

/// P4-C4：端口表与 `port_count` 的细粒度锁；与 `ipc` 队列锁独立，避免与消息环死锁嵌套顺序混乱。
var port_gate: std.atomic.Value(u32) = .init(0);

fn lockPorts() void {
    while (port_gate.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
        std.atomic.spinLoopHint();
    }
}

fn unlockPorts() void {
    port_gate.store(0, .release);
}

/// csrss Win32 子系统：`opcode` 在 `0x10000..0x1FFFF` 时由 `subsystem` 注册的回调同步处理（同内核占位模型）。
var csr_lpc_handler: ?*const fn (client_pid: u32, opcode: u32, data: ?*const [ipc.MSG_DATA_SIZE]u8) i32 = null;

pub fn setCsrRequestHandler(handler: ?*const fn (client_pid: u32, opcode: u32, data: ?*const [ipc.MSG_DATA_SIZE]u8) i32) void {
    csr_lpc_handler = handler;
}

pub const MAX_PORTS: usize = 32;

pub const PortState = enum {
    inactive,
    listening,
    connected,
    closed,
};

/// NT LPC：连接端口（`connection_listener`：服务端监听）与通信端口（`message`：已连接会话）分离雏形。
/// 枚举底层值须与 [tests/lpc_portkind_host.zig](../../tests/lpc_portkind_host.zig) 及 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md) 同步。
pub const PortKind = enum(u8) {
    message = 0,
    connection_listener = 1,
};

pub const Port = struct {
    header: ob.ObjectHeader = .{ .obj_type = .port },
    id: u32 = 0,
    owner_pid: u32 = 0,
    state: PortState = .inactive,
    kind: PortKind = .message,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    connected_port: u32 = 0,
    /// 与 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md) 固定头变更时递增（v2：大消息/超时单一真源演进，载荷仍向后兼容 v1）。
    handshake_version: u8 = 2,
    /// 与 `mm/vm.zig` `AddressSpace.section_view_token` 等登记配套；`NtMapViewOfSection` 后可写 `vm.sectionViewTokenAt`。
    section_view_handle: u32 = 0,

    pub fn init(id: u32, owner_pid: u32) Port {
        return .{
            .header = .{ .obj_type = .port },
            .id = id,
            .owner_pid = owner_pid,
            .state = .inactive,
            .kind = .message,
            .name = [_]u8{0} ** 32,
            .name_len = 0,
            .connected_port = 0,
            .handshake_version = 2,
            .section_view_handle = 0,
        };
    }
};

var ports: [MAX_PORTS]Port = [_]Port{.{}} ** MAX_PORTS;
var port_count: u32 = 0;
var port_initialized: bool = false;

fn ensureInit() void {
    if (!port_initialized) {
        port_count = 0;
        port_initialized = true;
    }
}

fn nameMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub fn createPort(owner_pid: u32, name: []const u8) ?*Port {
    return createPortWithKind(owner_pid, name, .message);
}

/// 命名连接监听端口（`PortKind.connection_listener`）；客户端 `connectPort` 仍创建普通通信端口并配对。
pub fn createConnectionListenerPort(owner_pid: u32, name: []const u8) ?*Port {
    return createPortWithKind(owner_pid, name, .connection_listener);
}

fn createPortWithKind(owner_pid: u32, name: []const u8, kind: PortKind) ?*Port {
    ensureInit();
    lockPorts();
    defer unlockPorts();
    if (port_count >= MAX_PORTS) return null;

    const id = port_count + 1;
    var port = &ports[port_count];
    port.* = Port.init(id, owner_pid);
    port.state = .listening;
    port.kind = kind;

    const copy_len = @min(name.len, port.name.len);
    @memcpy(port.name[0..copy_len], name[0..copy_len]);
    port.name_len = copy_len;

    port_count += 1;
    klog.debug("LPC: Port '%s' created (id=%u, owner=%u, kind=%u)", .{
        name, id, owner_pid, @intFromEnum(kind),
    });
    return port;
}

pub fn setPortSectionView(port: *Port, view_handle: u32) void {
    port.section_view_handle = view_handle;
}

/// 将节视图句柄（可为 `NtMapViewOfSection` 返回的基址低位或专用 token）绑定到端口，供大消息共享缓冲路线图使用。
pub fn bindSectionViewToPort(port_id: u32, view_token: u32) void {
    const p = findPortById(port_id) orelse return;
    p.section_view_handle = view_token;
}

pub fn findPort(name: []const u8) ?*Port {
    ensureInit();
    lockPorts();
    defer unlockPorts();
    for (ports[0..port_count]) |*p| {
        if (p.state == .inactive or p.state == .closed) continue;
        if (nameMatch(p.name[0..p.name_len], name)) return p;
    }
    return null;
}

pub fn findPortById(id: u32) ?*Port {
    ensureInit();
    lockPorts();
    defer unlockPorts();
    if (id == 0 or id > port_count) return null;
    return &ports[id - 1];
}

pub fn connectPort(client_pid: u32, name: []const u8) ?*Port {
    ensureInit();
    lockPorts();
    defer unlockPorts();

    const server = blk: {
        for (ports[0..port_count]) |*p| {
            if (p.state == .inactive or p.state == .closed) continue;
            if (nameMatch(p.name[0..p.name_len], name)) break :blk p;
        }
        return null;
    };
    if (server.state != .listening) return null;

    if (port_count >= MAX_PORTS) return null;
    const id = port_count + 1;
    var client = &ports[port_count];
    client.* = Port.init(id, client_pid);
    client.state = .connected;
    client.connected_port = server.id;
    const copy_len = @min(name.len, client.name.len);
    @memcpy(client.name[0..copy_len], name[0..copy_len]);
    client.name_len = copy_len;
    port_count += 1;

    klog.debug("LPC: Port connected (client=%u -> server=%u)", .{
        client.id, server.id,
    });
    if (server.connected_port == 0) {
        server.connected_port = client.id;
    }
    return client;
}

pub fn closePort(port_id: u32) bool {
    ensureInit();
    lockPorts();
    defer unlockPorts();
    if (port_id == 0 or port_id > port_count) return false;
    var port = &ports[port_id - 1];
    port.state = .closed;
    return true;
}

pub fn requestWaitReply(
    client_pid: u32,
    server_name: []const u8,
    opcode: u32,
    data: ?*const [ipc.MSG_DATA_SIZE]u8,
) ?ipc.Message {
    const server = findPort(server_name) orelse return null;

    _ = ipc.send(client_pid, server.owner_pid, opcode, data);

    return ipc.receive(client_pid);
}

/// Client-side: `port_id` is the handle returned by `createPort` / `connectPort` (1-based id).
/// **跨进程（B1）**：载荷指针须 **内核可访问**；独立用户 VA 的探测/拷贝或节视图共享为路线图项（见 VM `probe` 与 `section_view_handle`）。
pub fn requestWaitReplyPort(
    client_pid: u32,
    port_id: u32,
    opcode: u32,
    data: ?*const [ipc.MSG_DATA_SIZE]u8,
) ?ipc.Message {
    const client_port = findPortById(port_id) orelse return null;
    if (client_port.owner_pid != client_pid) return null;
    if (client_port.connected_port == 0) return null;
    const server_port = findPortById(client_port.connected_port) orelse return null;
    _ = ipc.send(client_pid, server_port.owner_pid, opcode, data);

    if (opcode >= 0x10000 and opcode <= 0x1FFFF) {
        if (csr_lpc_handler) |h| {
            ipc.csrReplyPayloadReset();
            const ret = h(client_pid, opcode, data);
            var msg = ipc.Message.init(server_port.owner_pid, client_pid, opcode);
            msg.msg_type = .reply;
            std.mem.writeInt(i32, msg.data[0..4], ret, .little);
            // `get_message`（0x10025）：`user32` 序列化 `MSG`；`open_desktop`（0x10028）：4 字节 1-based HDESK。
            const csr_reply_extra_payload = opcode == 0x10025 or opcode == 0x10028;
            if (csr_reply_extra_payload) {
                const plen = ipc.csrReplyPayloadLen();
                if (plen > 0 and plen <= msg.data.len - 4) {
                    @memcpy(msg.data[4..][0..plen], ipc.csr_reply_payload[0..plen]);
                }
            }
            return msg;
        }
    }

    return ipc.receive(client_pid);
}

/// 服务端：`reply` 非空时先向客户端队列投递 `reply`（`msg_type=.reply`），再等待下一条入站消息（与 `NtReplyWaitReceivePort` 对偶）。
/// 调度启用且线程数 > 1 时经 `scheduler` 阻塞；否则回退自旋（单线程 / 早期引导）。
/// Ref: learn.microsoft.com — LPC `NtReplyWaitReceivePort` 行为级描述（clean-room）。
pub fn replyWaitReceivePort(
    server_pid: u32,
    port_id: u32,
    reply: ?*const ipc.Message,
    out_receive: *ipc.Message,
) bool {
    const srv = findPortById(port_id) orelse return false;
    if (srv.owner_pid != server_pid) return false;
    if (reply) |r| {
        _ = ipc.sendTyped(server_pid, r.sender, r.opcode, .reply, &r.data);
    }
    while (true) {
        ipc.lockMessageQueues();
        if (ipc.popReceiveLocked(server_pid)) |m| {
            ipc.unlockMessageQueues();
            out_receive.* = m;
            return true;
        }
        if (!sched.schedulingIsEnabled() or sched.getThreadCount() <= 1) {
            ipc.unlockMessageQueues();
            var n: usize = 0;
            while (n < 10000) : (n += 1) {
                if (ipc.receive(server_pid)) |m2| {
                    out_receive.* = m2;
                    return true;
                }
                arch.spinCpuRelax();
            }
            return false;
        }
        const tid = sched.getCurrentThreadId();
        sched.lockSchedIrq();
        if (ipc.peekReceiveLocked(server_pid) != null) {
            const m = ipc.popReceiveLocked(server_pid).?;
            sched.unlockSchedIrq();
            ipc.unlockMessageQueues();
            out_receive.* = m;
            return true;
        }
        sched.prepareLpcReceiveBlockLocked(tid, server_pid);
        ipc.unlockMessageQueues();
        sched.unlockSchedIrq();
        sched.tick();
    }
}
