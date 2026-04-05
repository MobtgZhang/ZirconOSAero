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
