// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/lpc/lpc.zig
// Purpose: Local Procedure Call (LPC) subsystem implementation,
//          compatible with NT 6.1 semantics.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/
//      local-procedure-calls, Windows Internals books (publicly documented
//      LPC concepts only)

const std = @import("std");
const klog = @import("../rtl/klog.zig");
const ob = @import("../ob/object.zig");
const ps = @import("../ps/process.zig");
const ke = @import("../ke/ke.zig");
const io = @import("../io/io.zig");
const ipc = @import("ipc.zig");

/// LPC port types (NT-compatible)
pub const PortType = enum(u8) {
    /// Server connection port (receives connection requests)
    ConnectionPort = 0,
    /// Server communication port (one per connected client)
    ServerCommunicationPort = 1,
    /// Client communication port (one per connection)
    ClientCommunicationPort = 2,
    /// Unconnected port
    UnconnectedPort = 3,
};

/// LPC message types
pub const MessageType = enum(u8) {
    /// Connection request
    ConnectionRequest = 1,
    /// Connection accepted
    ConnectionAccepted = 2,
    /// Connection rejected
    ConnectionRejected = 3,
    /// Request message
    Request = 4,
    /// Reply message
    Reply = 5,
    /// One-way (datagram) message
    Datagram = 6,
    /// Port close notification
    PortClosed = 7,
};

/// LPC constants (NT-compatible)
pub const MAX_PORT_NAME_LENGTH = 256;
pub const MAX_MESSAGE_DATA_LENGTH = 1024;
pub const MAX_PENDING_MESSAGES = 32;
pub const MAX_CONNECTION_REQUESTS = 16;
pub const MAX_CONNECTED_CLIENTS = 32;

/// LPC message structure (NT 6.1 compatible subset)
pub const LpcMessage = extern struct {
    /// Total message length (header + data)
    message_length: u16,
    /// Data length (payload only)
    data_length: u16,
    /// Message type
    message_type: MessageType,
    /// Message identifier
    message_id: u32,
    /// Client process ID
    client_process_id: u32,
    /// Client thread ID
    client_thread_id: u32,
    /// Returned status code for replies
    return_status: io.NTSTATUS = io.STATUS_SUCCESS,
    /// Message payload data
    data: [MAX_MESSAGE_DATA_LENGTH]u8 = [_]u8{0} ** MAX_MESSAGE_DATA_LENGTH,
};

/// LPC connection information structure (passed during connection)
pub const LpcConnectionInfo = struct {
    /// Client process ID
    process_id: u32,
    /// Client thread ID
    thread_id: u32,
    /// Maximum message size supported by client
    max_message_size: u16,
    /// Connection flags
    flags: u32 = 0,
};

/// LPC port object structure (NT 6.1 compatible subset)
pub const LpcPort = struct {
    /// Object header
    header: ob.ObjectHeader = .{ .obj_type = .lpc_port },
    /// Port name (for named ports)
    name: [MAX_PORT_NAME_LENGTH]u8 = [_]u8{0} ** MAX_PORT_NAME_LENGTH,
    /// Name length
    name_len: usize = 0,
    /// Port type
    port_type: PortType,
    /// Port ID
    port_id: u32 = 0,
    /// Process ID of port owner
    owner_process_id: u32 = 0,
    /// Connected port (for communication ports: points to peer port)
    connected_port: u32 = 0,
    /// Parent connection port (for server communication ports)
    parent_port: u32 = 0,
    /// Connection state
    connected: bool = false,
    /// Maximum message size supported by this port
    max_message_size: u16 = MAX_MESSAGE_DATA_LENGTH,
    /// Pending message queue
    message_queue: [MAX_PENDING_MESSAGES]LpcMessage = [_]LpcMessage{.{
        .message_length = @sizeOf(LpcMessage),
        .data_length = 0,
        .message_type = .Datagram,
        .message_id = 0,
        .client_process_id = 0,
        .client_thread_id = 0,
    }} ** MAX_PENDING_MESSAGES,
    /// Number of pending messages in queue
    message_count: usize = 0,
    /// Pending connection requests (only for connection ports)
    connection_queue: [MAX_CONNECTION_REQUESTS]LpcMessage = [_]LpcMessage{.{
        .message_length = @sizeOf(LpcMessage),
        .data_length = 0,
        .message_type = .ConnectionRequest,
        .message_id = 0,
        .client_process_id = 0,
        .client_thread_id = 0,
    }} ** MAX_CONNECTION_REQUESTS,
    /// Number of pending connection requests
    connection_count: usize = 0,
    /// Connected client ports (only for connection ports)
    client_ports: [MAX_CONNECTED_CLIENTS]u32 = [_]u32{0} ** MAX_CONNECTED_CLIENTS,
    /// Number of connected clients
    client_count: usize = 0,
    /// Event signaled when a message arrives
    message_event: *ke.EventObject = undefined,
    /// Event signaled when a connection request arrives
    connection_event: *ke.EventObject = undefined,
    /// Security descriptor (for access checks)
    security_descriptor: u64 = 0,
    /// Port flags
    flags: u32 = 0,
};

/// Global LPC port table
var ports: [ob.MAX_OBJECTS]LpcPort = [_]LpcPort{.{
    .port_type = .UnconnectedPort,
}} ** ob.MAX_OBJECTS;
var port_count: usize = 0;
var next_port_id: u32 = 1;
var lpc_initialized: bool = false;

/// Find port by name
fn findPortByName(name: []const u8) ?*LpcPort {
    for (0..port_count) |i| {
        const port = &ports[i];
        if (port.name_len == name.len and std.mem.eql(u8, port.name[0..port.name_len], name)) {
            return port;
        }
    }
    return null;
}

/// Find port by ID
fn findPortById(port_id: u32) ?*LpcPort {
    for (0..port_count) |i| {
        const port = &ports[i];
        if (port.port_id == port_id) {
            return port;
        }
    }
    return null;
}

/// Create a new LPC port (NT-compatible NtCreatePort equivalent)
pub fn NtCreatePort(
    out_port_id: *u32,
    name: []const u8,
    max_message_size: u16,
    max_connections: u32,
) io.NTSTATUS {
    if (!lpc_initialized) return io.STATUS_NOT_IMPLEMENTED;
    if (name.len > MAX_PORT_NAME_LENGTH) return io.STATUS_INVALID_PARAMETER;
    if (max_message_size > MAX_MESSAGE_DATA_LENGTH) return io.STATUS_INVALID_PARAMETER;
    if (max_connections > MAX_CONNECTED_CLIENTS) return io.STATUS_INVALID_PARAMETER;

    // Check if port name already exists
    if (findPortByName(name) != null) return io.STATUS_OBJECT_NAME_COLLISION;

    if (port_count >= ob.MAX_OBJECTS) return io.STATUS_INSUFFICIENT_RESOURCES;

    const current_process_id = ps.getCurrentProcessId();
    const port_idx = port_count;
    var port = &ports[port_idx];

    // Initialize port
    port.* = .{
        .port_type = .ConnectionPort,
        .port_id = next_port_id,
        .owner_process_id = current_process_id,
        .max_message_size = max_message_size,
    };

    next_port_id += 1;

    // Copy port name
    @memcpy(port.name[0..name.len], name);
    port.name_len = name.len;

    // Create events
    port.message_event = ke.KeCreateEvent(.SynchronizationEvent, false);
    port.connection_event = ke.KeCreateEvent(.SynchronizationEvent, false);

    port_count += 1;

    out_port_id.* = port.port_id;

    klog.debug("LPC: Created connection port '%s' (id=%u, owner=%u)", .{
        name, port.port_id, current_process_id,
    });

    return io.STATUS_SUCCESS;
}

/// Listen for connection requests on a connection port
pub fn NtListenPort(
    port_id: u32,
    out_message: *LpcMessage,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (port.port_type != .ConnectionPort) return io.STATUS_INVALID_PORT_TYPE;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    // Wait for connection request
    while (port.connection_count == 0) {
        ke.KeWaitForSingleObject(port.connection_event, .Executive, false, null);
    }

    // Dequeue connection request
    port.connection_count -= 1;
    out_message.* = port.connection_queue[port.connection_count];

    // Reset event if no more connections
    if (port.connection_count == 0) {
        ke.KeClearEvent(port.connection_event);
    }

    return io.STATUS_SUCCESS;
}

/// Accept an incoming connection request (NT-compatible NtAcceptConnectPort equivalent)
pub fn NtAcceptConnectPort(
    out_server_port_id: *u32,
    connection_port_id: u32,
    connection_message: *const LpcMessage,
    accept: bool,
) io.NTSTATUS {
    const conn_port = findPortById(connection_port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (conn_port.port_type != .ConnectionPort) return io.STATUS_INVALID_PORT_TYPE;
    if (conn_port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    if (!accept) {
        // Send rejection to client
        const client_port = findPortById(connection_message.client_process_id);
        if (client_port != null and client_port.?.connected_port == connection_port_id) {
            var reply: LpcMessage = .{
                .message_length = @sizeOf(LpcMessage),
                .data_length = 0,
                .message_type = .ConnectionRejected,
                .message_id = connection_message.message_id,
                .client_process_id = ps.getCurrentProcessId(),
                .client_thread_id = ps.getCurrentThreadId(),
                .return_status = io.STATUS_CONNECTION_REFUSED,
            };
            _ = sendMessage(client_port.?, &reply);
        }
        return io.STATUS_SUCCESS;
    }

    if (conn_port.client_count >= MAX_CONNECTED_CLIENTS) return io.STATUS_INSUFFICIENT_RESOURCES;
    if (port_count >= ob.MAX_OBJECTS) return io.STATUS_INSUFFICIENT_RESOURCES;

    // Create server communication port
    const server_port_idx = port_count;
    var server_port = &ports[server_port_idx];
    server_port.* = .{
        .port_type = .ServerCommunicationPort,
        .port_id = next_port_id,
        .owner_process_id = ps.getCurrentProcessId(),
        .parent_port = connection_port_id,
        .connected = true,
        .max_message_size = conn_port.max_message_size,
        .message_event = ke.KeCreateEvent(.SynchronizationEvent, false),
    };
    next_port_id += 1;
    port_count += 1;

    // Find client communication port
    const client_port = findPortById(connection_message.client_process_id) orelse return io.STATUS_INVALID_HANDLE;
    if (client_port.port_type != .ClientCommunicationPort) return io.STATUS_INVALID_PORT_TYPE;

    // Connect the ports
    server_port.connected_port = client_port.port_id;
    client_port.connected_port = server_port.port_id;
    client_port.connected = true;

    // Add client to connection port's client list
    conn_port.client_ports[conn_port.client_count] = client_port.port_id;
    conn_port.client_count += 1;

    // Send acceptance to client
    var reply: LpcMessage = .{
        .message_length = @sizeOf(LpcMessage),
        .data_length = 0,
        .message_type = .ConnectionAccepted,
        .message_id = connection_message.message_id,
        .client_process_id = ps.getCurrentProcessId(),
        .client_thread_id = ps.getCurrentThreadId(),
        .return_status = io.STATUS_SUCCESS,
    };
    _ = sendMessage(client_port, &reply);

    out_server_port_id.* = server_port.port_id;

    klog.debug("LPC: Accepted connection on port '%s', server port id=%u, client port id=%u", .{
        conn_port.name[0..conn_port.name_len], server_port.port_id, client_port.port_id,
    });

    return io.STATUS_SUCCESS;
}

/// Complete the connection process from client side (NT-compatible NtCompleteConnectPort equivalent)
pub fn NtCompleteConnectPort(
    port_id: u32,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (port.port_type != .ClientCommunicationPort) return io.STATUS_INVALID_PORT_TYPE;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;
    if (!port.connected) return io.STATUS_PORT_NOT_CONNECTED;

    return io.STATUS_SUCCESS;
}

/// Connect to a named LPC port (NT-compatible NtConnectPort equivalent)
pub fn NtConnectPort(
    out_port_id: *u32,
    port_name: []const u8,
    connection_info: *const LpcConnectionInfo,
    out_max_message_size: *u16,
) io.NTSTATUS {
    if (!lpc_initialized) return io.STATUS_NOT_IMPLEMENTED;
    if (port_name.len > MAX_PORT_NAME_LENGTH) return io.STATUS_INVALID_PARAMETER;

    // Find the server connection port
    const server_port = findPortByName(port_name) orelse return io.STATUS_OBJECT_NAME_NOT_FOUND;
    if (server_port.port_type != .ConnectionPort) return io.STATUS_INVALID_PORT_TYPE;

    if (port_count >= ob.MAX_OBJECTS) return io.STATUS_INSUFFICIENT_RESOURCES;

    // Create client communication port
    const client_port_idx = port_count;
    var client_port = &ports[client_port_idx];
    client_port.* = .{
        .port_type = .ClientCommunicationPort,
        .port_id = next_port_id,
        .owner_process_id = ps.getCurrentProcessId(),
        .connected_port = server_port.port_id,
        .max_message_size = connection_info.max_message_size,
        .message_event = ke.KeCreateEvent(.SynchronizationEvent, false),
    };
    next_port_id += 1;
    port_count += 1;

    // Prepare connection request message
    var request: LpcMessage = .{
        .message_length = @sizeOf(LpcMessage) + @sizeOf(LpcConnectionInfo),
        .data_length = @sizeOf(LpcConnectionInfo),
        .message_type = .ConnectionRequest,
        .message_id = 0x12345678, // TODO: Generate unique message ID
        .client_process_id = client_port.port_id, // Use port ID as identifier
        .client_thread_id = ps.getCurrentThreadId(),
    };

    // Copy connection info to message data
    const conn_info_ptr: *LpcConnectionInfo = @ptrCast(&request.data);
    conn_info_ptr.* = connection_info.*;

    // Add connection request to server port's queue
    if (server_port.connection_count >= MAX_CONNECTION_REQUESTS) {
        // Clean up client port
        port_count -= 1;
        return io.STATUS_INSUFFICIENT_RESOURCES;
    }

    server_port.connection_queue[server_port.connection_count] = request;
    server_port.connection_count += 1;
    ke.KeSetEvent(server_port.connection_event, 0, false);

    // Wait for connection response
    while (client_port.message_count == 0) {
        ke.KeWaitForSingleObject(client_port.message_event, .Executive, false, null);
    }

    // Get response
    client_port.message_count -= 1;
    const response = client_port.message_queue[client_port.message_count];

    // Reset event if no more messages
    if (client_port.message_count == 0) {
        ke.KeClearEvent(client_port.message_event);
    }

    if (response.message_type != .ConnectionAccepted) {
        // Connection rejected, clean up
        port_count -= 1;
        return io.STATUS_CONNECTION_REFUSED;
    }

    out_port_id.* = client_port.port_id;
    out_max_message_size.* = server_port.max_message_size;

    klog.debug("LPC: Connected to port '%s', client port id=%u", .{
        port_name, client_port.port_id,
    });

    return io.STATUS_SUCCESS;
}

/// Send message to a port (internal helper)
fn sendMessage(port: *LpcPort, message: *const LpcMessage) io.NTSTATUS {
    if (message.data_length > port.max_message_size) return io.STATUS_INVALID_PARAMETER;
    if (port.message_count >= MAX_PENDING_MESSAGES) return io.STATUS_INSUFFICIENT_RESOURCES;

    // 优先使用底层IPC队列传输
    var ipc_data: [ipc.MSG_DATA_SIZE]u8 = [_]u8{0} ** ipc.MSG_DATA_SIZE;
    const copy_len = @min(message.data_length, ipc.MSG_DATA_SIZE);
    @memcpy(ipc_data[0..copy_len], message.data[0..copy_len]);

    // 把LPC消息封装成IPC消息发送给端口所属进程
    const result = ipc.sendTyped(ps.getCurrentProcessId(), port.owner_process_id, @intFromEnum(message.message_type), switch (message.message_type) {
        .ConnectionRequest => .connection_request,
        .ConnectionAccepted, .ConnectionRejected => .connection_reply,
        .Request => .request,
        .Reply => .reply,
        else => .notification,
    }, &ipc_data);

    if (result < 0) {
        // IPC发送失败，降级到本地队列
        // Copy message to queue
        port.message_queue[port.message_count] = message.*;
        port.message_count += 1;

        // Signal message event
        ke.KeSetEvent(port.message_event, 0, false);
    }

    return io.STATUS_SUCCESS;
}

/// Send request and wait for reply (NT-compatible NtRequestWaitReplyPort equivalent)
pub fn NtRequestWaitReplyPort(
    port_id: u32,
    request_message: *const LpcMessage,
    reply_message: *LpcMessage,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (!port.connected) return io.STATUS_PORT_NOT_CONNECTED;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    // Find connected peer port
    const peer_port = findPortById(port.connected_port) orelse return io.STATUS_INVALID_HANDLE;

    // Send request to peer
    const status = sendMessage(peer_port, request_message);
    if (status != io.STATUS_SUCCESS) return status;

    // Wait for reply
    while (port.message_count == 0) {
        ke.KeWaitForSingleObject(port.message_event, .Executive, false, null);
    }

    // Get reply
    port.message_count -= 1;
    reply_message.* = port.message_queue[port.message_count];

    // Reset event if no more messages
    if (port.message_count == 0) {
        ke.KeClearEvent(port.message_event);
    }

    return reply_message.return_status;
}

/// Send reply to a request (NT-compatible NtReplyPort equivalent)
pub fn NtReplyPort(
    port_id: u32,
    reply_message: *const LpcMessage,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (!port.connected) return io.STATUS_PORT_NOT_CONNECTED;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    // Find connected peer port
    const peer_port = findPortById(port.connected_port) orelse return io.STATUS_INVALID_HANDLE;

    return sendMessage(peer_port, reply_message);
}

/// Receive message from port (NT-compatible NtReplyWaitReceivePort equivalent)
pub fn NtReplyWaitReceivePort(
    port_id: u32,
    reply_message: ?*const LpcMessage,
    out_message: *LpcMessage,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    // Send reply if provided
    if (reply_message != null) {
        if (!port.connected) return io.STATUS_PORT_NOT_CONNECTED;
        const peer_port = findPortById(port.connected_port) orelse return io.STATUS_INVALID_HANDLE;
        const status = sendMessage(peer_port, reply_message.?);
        if (status != io.STATUS_SUCCESS) return status;
    }

    // Wait for incoming message
    while (port.message_count == 0) {
        ke.KeWaitForSingleObject(port.message_event, .Executive, false, null);
    }

    // Get message
    port.message_count -= 1;
    out_message.* = port.message_queue[port.message_count];

    // Reset event if no more messages
    if (port.message_count == 0) {
        ke.KeClearEvent(port.message_event);
    }

    return io.STATUS_SUCCESS;
}

/// Close an LPC port (NT-compatible NtClose for LPC ports)
pub fn NtClosePort(
    port_id: u32,
) io.NTSTATUS {
    const port = findPortById(port_id) orelse return io.STATUS_INVALID_HANDLE;
    if (port.owner_process_id != ps.getCurrentProcessId()) return io.STATUS_ACCESS_DENIED;

    // Notify connected peer if any
    if (port.connected) {
        const peer_port = findPortById(port.connected_port);
        if (peer_port != null and peer_port.?.connected) {
            var close_msg: LpcMessage = .{
                .message_length = @sizeOf(LpcMessage),
                .data_length = 0,
                .message_type = .PortClosed,
                .message_id = 0,
                .client_process_id = port.owner_process_id,
                .client_thread_id = ps.getCurrentThreadId(),
                .return_status = io.STATUS_CONNECTION_RESET,
            };
            _ = sendMessage(peer_port.?, &close_msg);
            peer_port.?.connected = false;
            peer_port.?.connected_port = 0;
        }
    }

    // If this is a connection port, close all connected clients
    if (port.port_type == .ConnectionPort) {
        for (0..port.client_count) |i| {
            const client_port_id = port.client_ports[i];
            const client_port = findPortById(client_port_id);
            if (client_port != null) {
                client_port.?.connected = false;
                client_port.?.connected_port = 0;
                var close_msg: LpcMessage = .{
                    .message_length = @sizeOf(LpcMessage),
                    .data_length = 0,
                    .message_type = .PortClosed,
                    .message_id = 0,
                    .client_process_id = port.owner_process_id,
                    .client_thread_id = ps.getCurrentThreadId(),
                    .return_status = io.STATUS_CONNECTION_RESET,
                };
                _ = sendMessage(client_port.?, &close_msg);
            }
        }
    }

    // If this is a server communication port, remove from parent's client list
    if (port.port_type == .ServerCommunicationPort and port.parent_port != 0) {
        const parent_port = findPortById(port.parent_port);
        if (parent_port != null) {
            for (0..parent_port.?.client_count) |i| {
                if (parent_port.?.client_ports[i] == port_id) {
                    // Shift remaining entries
                    var j = i;
                    while (j < parent_port.?.client_count - 1) : (j += 1) {
                        parent_port.?.client_ports[j] = parent_port.?.client_ports[j + 1];
                    }
                    parent_port.?.client_count -= 1;
                    break;
                }
            }
        }
    }

    // Mark port as unconnected
    port.connected = false;
    port.port_type = .UnconnectedPort;

    klog.debug("LPC: Closed port id=%u", .{port_id});

    return io.STATUS_SUCCESS;
}

/// Initialize LPC subsystem
pub fn init() void {
    // Reset port table
    port_count = 0;
    next_port_id = 1;
    lpc_initialized = true;

    klog.info("LPC subsystem: initialized", .{});
}

test "LPC port creation and connection" {
    init();

    // Create server port
    var server_port_id: u32 = 0;
    const create_status = NtCreatePort(&server_port_id, "\\TestPort", 1024, 16);
    try std.testing.expect(create_status == io.STATUS_SUCCESS);

    // Client thread will connect to server
    const client_thread_fn = struct {
        fn threadEntry(ctx: u64) callconv(.C) u64 {
            _ = ctx;
            var client_port_id: u32 = 0;
            var max_msg_size: u16 = 0;
            const conn_info: LpcConnectionInfo = .{
                .process_id = ps.getCurrentProcessId(),
                .thread_id = ps.getCurrentThreadId(),
                .max_message_size = 1024,
            };
            const status = NtConnectPort(&client_port_id, "\\TestPort", &conn_info, &max_msg_size);
            return @as(u64, @bitCast(status));
        }
    }.threadEntry;

    // Start client thread
    const client_thread = ps.createKernelThread(client_thread_fn, 0);
    ps.resumeThread(client_thread);

    // Server listens for connection
    var conn_msg: LpcMessage = undefined;
    try std.testing.expect(NtListenPort(server_port_id, &conn_msg) == io.STATUS_SUCCESS);
    try std.testing.expect(conn_msg.message_type == .ConnectionRequest);

    // Accept connection
    var server_comm_port_id: u32 = 0;
    try std.testing.expect(NtAcceptConnectPort(&server_comm_port_id, server_port_id, &conn_msg, true) == io.STATUS_SUCCESS);

    // Wait for client thread to complete
    const client_status = ps.waitForThreadTermination(client_thread, null);
    try std.testing.expect(client_status == io.STATUS_SUCCESS);

    // Cleanup
    try std.testing.expect(NtClosePort(server_comm_port_id) == io.STATUS_SUCCESS);
    try std.testing.expect(NtClosePort(server_port_id) == io.STATUS_SUCCESS);
}
