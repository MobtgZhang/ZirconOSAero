//! IPC (Inter-Process Communication) - LPC style message passing
//! NT style Microkernel core: all system services communicate via IPC
//! Supports synchronous request/reply and async message passing

pub const MSG_DATA_SIZE: usize = 64;

pub const MessageType = enum(u8) {
    request = 0,
    reply = 1,
    notification = 2,
    connection_request = 3,
    connection_reply = 4,
};

pub const Message = struct {
    sender: u32,
    receiver: u32,
    opcode: u32,
    msg_type: MessageType = .request,
    sequence: u32 = 0,
    data: [MSG_DATA_SIZE]u8,

    pub fn init(sender_pid: u32, receiver_pid: u32, op: u32) Message {
        var msg: Message = undefined;
        msg.sender = sender_pid;
        msg.receiver = receiver_pid;
        msg.opcode = op;
        msg.msg_type = .request;
        msg.sequence = 0;
        for (&msg.data) |*b| b.* = 0;
        return msg;
    }
};

const QUEUE_SIZE: usize = 32;

const MessageQueue = struct {
    messages: [QUEUE_SIZE]Message = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn reset(self: *MessageQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }

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

    fn peek(self: *const MessageQueue) ?*const Message {
        if (self.count == 0) return null;
        return &self.messages[self.head];
    }

    fn isEmpty(self: *const MessageQueue) bool {
        return self.count == 0;
    }

    fn isFull(self: *const MessageQueue) bool {
        return self.count >= QUEUE_SIZE;
    }
};

const MAX_QUEUES: usize = 64;
var message_queues: [MAX_QUEUES]MessageQueue = undefined;
var queues_initialized: bool = false;
var next_sequence: u32 = 1;

fn ensureQueues() void {
    if (!queues_initialized) {
        for (&message_queues) |*q| q.reset();
        queues_initialized = true;
    }
}

fn pidToIndex(pid: u32) ?usize {
    if (pid == 0 or pid > MAX_QUEUES) return null;
    return pid - 1;
}

pub fn send(sender_pid: u32, receiver_pid: u32, opcode: u32, data: ?*const [MSG_DATA_SIZE]u8) i64 {
    ensureQueues();
    const recv_idx = pidToIndex(receiver_pid) orelse return -1;

    var msg = Message.init(sender_pid, receiver_pid, opcode);
    msg.sequence = next_sequence;
    next_sequence += 1;

    if (data) |d| {
        @memcpy(&msg.data, d);
    }

    if (!message_queues[recv_idx].push(msg)) {
        return -2;
    }
    return 0;
}

pub fn sendTyped(sender_pid: u32, receiver_pid: u32, opcode: u32, msg_type: MessageType, data: ?*const [MSG_DATA_SIZE]u8) i64 {
    ensureQueues();
    const recv_idx = pidToIndex(receiver_pid) orelse return -1;

    var msg = Message.init(sender_pid, receiver_pid, opcode);
    msg.msg_type = msg_type;
    msg.sequence = next_sequence;
    next_sequence += 1;

    if (data) |d| {
        @memcpy(&msg.data, d);
    }

    if (!message_queues[recv_idx].push(msg)) {
        return -2;
    }
    return 0;
}

pub fn receive(receiver_pid: u32) ?Message {
    ensureQueues();
    const idx = pidToIndex(receiver_pid) orelse return null;
    return message_queues[idx].pop();
}

pub fn tryReceive(receiver_pid: u32) ?Message {
    return receive(receiver_pid);
}

pub fn peek(receiver_pid: u32) ?*const Message {
    ensureQueues();
    const idx = pidToIndex(receiver_pid) orelse return null;
    return message_queues[idx].peek();
}

pub fn getQueueCount(pid: u32) usize {
    ensureQueues();
    const idx = pidToIndex(pid) orelse return 0;
    return message_queues[idx].count;
}

pub fn requestWaitReply(
    sender_pid: u32,
    receiver_pid: u32,
    opcode: u32,
    data: ?*const [MSG_DATA_SIZE]u8,
) ?Message {
    const result = send(sender_pid, receiver_pid, opcode, data);
    if (result < 0) return null;

    var attempts: usize = 0;
    while (attempts < 10000) : (attempts += 1) {
        if (receive(sender_pid)) |reply| {
            if (reply.opcode == opcode) return reply;
        }
        asm volatile ("pause");
    }
    return null;
}
