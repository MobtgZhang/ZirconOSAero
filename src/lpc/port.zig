//! LPC Port Implementation
//! NT-style port-based IPC: CreatePort, ConnectPort, RequestWaitReply
//!
//! Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/local-procedure-calls-lpc-
//!
//! 里程碑：[docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K6.4（与 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md) 同步）。
//! **P4-C4**：SMP 下端口队列与 `ipc` 消息环的细粒度锁为长期项；当前假定引导早期单线程初始化路径。

const ipc = @import("ipc.zig");
const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

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
    /// 与 `mm/vm.zig` `AddressSpace.section_view_*` 登记配套的 **用户态句柄/索引** 占位；`mapViewIntoProcess` 成功时由会话层写入，供 LPC 大块传输绑定。
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
    for (ports[0..port_count]) |*p| {
        if (p.state == .inactive or p.state == .closed) continue;
        if (nameMatch(p.name[0..p.name_len], name)) return p;
    }
    return null;
}

pub fn findPortById(id: u32) ?*Port {
    ensureInit();
    if (id == 0 or id > port_count) return null;
    return &ports[id - 1];
}

pub fn connectPort(client_pid: u32, name: []const u8) ?*Port {
    ensureInit();

    const server = findPort(name) orelse return null;
    if (server.state != .listening) return null;

    const client = createPort(client_pid, name) orelse return null;
    client.state = .connected;
    client.connected_port = server.id;

    if (server.connected_port == 0) {
        server.connected_port = client.id;
    }

    klog.debug("LPC: Port connected (client=%u -> server=%u)", .{
        client.id, server.id,
    });
    return client;
}

pub fn closePort(port_id: u32) bool {
    ensureInit();
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
pub fn requestWaitReplyPort(
    client_pid: u32,
    port_id: u32,
    opcode: u32,
    data: ?*const [ipc.MSG_DATA_SIZE]u8,
) ?ipc.Message {
    const client_port = findPortById(port_id) orelse return null;
    if (client_port.connected_port == 0) return null;
    const server_port = findPortById(client_port.connected_port) orelse return null;
    _ = ipc.send(client_pid, server_port.owner_pid, opcode, data);
    return ipc.receive(client_pid);
}
