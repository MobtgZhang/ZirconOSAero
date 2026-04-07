// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Host-only：镜像 `src/lpc/ipc.zig` 的 **两 PID 入队/出队** 语义（`pidToIndex`、`MSG_DATA_SIZE`），
// 验证一发一收往返，不链接内核调度器。
// Ref: docs/cn/NT61_CONTRACT_MATRIX.md §2.2 B1；`ipc.zig`

const std = @import("std");

const MSG_DATA_SIZE: usize = 64;
const QUEUE_SIZE: usize = 32;
const MAX_QUEUES: usize = 64;

const Message = struct {
    sender: u32,
    receiver: u32,
    opcode: u32,
    data: [MSG_DATA_SIZE]u8,
};

const MessageQueue = struct {
    messages: [QUEUE_SIZE]Message = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *MessageQueue, msg: Message) bool {
        if (self.count >= QUEUE_SIZE) return false;
        self.messages[self.tail] = msg;
        self.tail = (self.tail + 1) % QUEUE_SIZE;
        self.count += 1;
        return true;
    }

    fn pop(self: *MessageQueue) ?Message {
        if (self.count == 0) return null;
        const msg = self.messages[self.head];
        self.head = (self.head + 1) % QUEUE_SIZE;
        self.count -= 1;
        return msg;
    }
};

fn pidToIndex(pid: u32) ?usize {
    if (pid == 0 or pid > MAX_QUEUES) return null;
    return pid - 1;
}

test "two-pid LPC queue roundtrip mirrors ipc.zig" {
    var queues: [MAX_QUEUES]MessageQueue = undefined;
    for (&queues) |*q| q.* = .{};

    const sender_pid: u32 = 2;
    const receiver_pid: u32 = 3;
    const recv_idx = pidToIndex(receiver_pid).?;

    var msg: Message = undefined;
    msg.sender = sender_pid;
    msg.receiver = receiver_pid;
    msg.opcode = 0x10001;
    for (&msg.data) |*b| b.* = 0;
    msg.data[0] = 0xAB;
    msg.data[1] = 0xCD;

    try std.testing.expect(queues[recv_idx].push(msg));

    const got = queues[recv_idx].pop().?;
    try std.testing.expectEqual(sender_pid, got.sender);
    try std.testing.expectEqual(receiver_pid, got.receiver);
    try std.testing.expectEqual(@as(u32, 0x10001), got.opcode);
    try std.testing.expectEqual(@as(u8, 0xAB), got.data[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), got.data[1]);
}

// B4：镜像 `port.requestWaitReplyPort` — `ipc.send(client, server_port.owner_pid, …)`，应答进客户端队列。
test "LPC request-reply routing uses server owner pid not client pid" {
    var queues: [MAX_QUEUES]MessageQueue = undefined;
    for (&queues) |*q| q.* = .{};

    const server_owner_pid: u32 = 10;
    const client_pid: u32 = 20;
    const opcode: u32 = 0x4242;
    var payload: [MSG_DATA_SIZE]u8 = [_]u8{0} ** MSG_DATA_SIZE;
    payload[0] = 0x11;

    // Client → server queue (owner_pid)
    var req: Message = undefined;
    req.sender = client_pid;
    req.receiver = server_owner_pid;
    req.opcode = opcode;
    @memcpy(&req.data, &payload);

    const srv_idx = pidToIndex(server_owner_pid).?;
    const cli_idx = pidToIndex(client_pid).?;
    try std.testing.expect(queues[srv_idx].push(req));

    const inbound = queues[srv_idx].pop().?;
    try std.testing.expectEqual(server_owner_pid, inbound.receiver);

    var rep: Message = undefined;
    rep.sender = server_owner_pid;
    rep.receiver = client_pid;
    rep.opcode = opcode;
    rep.data[0] = 0x99;
    try std.testing.expect(queues[cli_idx].push(rep));

    const back = queues[cli_idx].pop().?;
    try std.testing.expectEqual(client_pid, back.receiver);
    try std.testing.expectEqual(@as(u8, 0x99), back.data[0]);
}
