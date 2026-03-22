//! LPC Port Implementation
//! NT-style port-based IPC: CreatePort, ConnectPort, RequestWaitReply

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

pub const Port = struct {
    header: ob.ObjectHeader = .{ .obj_type = .port },
    id: u32 = 0,
    owner_pid: u32 = 0,
    state: PortState = .inactive,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    connected_port: u32 = 0,

    pub fn init(id: u32, owner_pid: u32) Port {
        return .{
            .header = .{ .obj_type = .port },
            .id = id,
            .owner_pid = owner_pid,
            .state = .inactive,
            .name = [_]u8{0} ** 32,
            .name_len = 0,
            .connected_port = 0,
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
    ensureInit();
    if (port_count >= MAX_PORTS) return null;

    const id = port_count + 1;
    var port = &ports[port_count];
    port.* = Port.init(id, owner_pid);
    port.state = .listening;

    const copy_len = @min(name.len, port.name.len);
    @memcpy(port.name[0..copy_len], name[0..copy_len]);
    port.name_len = copy_len;

    port_count += 1;
    klog.debug("LPC: Port '%s' created (id=%u, owner=%u)", .{
        name, id, owner_pid,
    });
    return port;
}

pub fn findPort(name: []const u8) ?*Port {
    ensureInit();
    for (ports[0..port_count]) |*p| {
        if (p.state == .inactive or p.state == .closed) continue;
        if (nameMatch(p.name[0..p.name_len], name)) return p;
    }
    return null;
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
