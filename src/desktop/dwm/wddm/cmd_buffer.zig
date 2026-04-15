// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS Command Buffer Management

const std = @import("std");

// ============================================================================
// Command Types
// ============================================================================

pub const CommandType = enum(u16) {
    nop = 0,
    set_render_target = 1,
    clear_render_target = 2,
    draw = 3,
    draw_indexed = 4,
    set_vertex_buffer = 5,
    set_index_buffer = 6,
    set_shader = 7,
    set_blend_state = 8,
    set_viewport = 9,
    set_scissor = 10,
    copy_resource = 11,
    resolve_subresource = 12,
};

// ============================================================================
// Command Header
// ============================================================================

pub const CommandHeader = extern struct {
    type: CommandType,
    size: u16,
    flags: u16,
};

// ============================================================================
// Command Buffer
// ============================================================================

pub const MAX_COMMAND_BUFFER_SIZE: usize = 64 * 1024;
pub const MAX_COMMANDS: usize = 256;

pub const CommandBuffer = struct {
    data: [MAX_COMMAND_BUFFER_SIZE]u8,
    size: usize,
    used: usize,
    submission_id: u64,
};

// ============================================================================
// Command Buffer Manager
// ============================================================================

pub const MAX_COMMAND_BUFFERS: usize = 32;

pub const CommandBufferManager = struct {
    buffers: [MAX_COMMAND_BUFFERS]?CommandBuffer,
    buffer_count: usize,
    current_buffer: usize,
    next_submission_id: u64,

    pub fn init(self: *CommandBufferManager) void {
        self.buffer_count = 0;
        self.current_buffer = 0;
        self.next_submission_id = 1;

        // Pre-allocate command buffers
        var i: usize = 0;
        while (i < MAX_COMMAND_BUFFERS) : (i += 1) {
            self.buffers[i] = .{
                .data = undefined,
                .size = MAX_COMMAND_BUFFER_SIZE,
                .used = 0,
                .submission_id = 0,
            };
        }
        self.buffer_count = MAX_COMMAND_BUFFERS;
    }

    pub fn beginCommand(self: *CommandBufferManager) void {
        if (self.current_buffer < self.buffer_count) {
            if (self.buffers[self.current_buffer]) |*buf| {
                buf.used = 0;
            }
        }
    }

    pub fn addCommand(self: *CommandBufferManager, cmd_type: CommandType, data: []const u8) void {
        if (self.current_buffer >= self.buffer_count) return;
        if (self.buffers[self.current_buffer]) |*buf| {
            const header_size = @sizeOf(CommandHeader);
            if (buf.used + header_size + data.len > buf.size) return;

            const header: CommandHeader = .{
                .type = cmd_type,
                .size = @as(u16, @intCast(data.len)),
                .flags = 0,
            };

            @memcpy(buf.data[buf.used..][0..header_size], @as([*]const u8, @ptrFromInt(@intFromPtr(&header)))[0..header_size]);
            buf.used += header_size;

            @memcpy(buf.data[buf.used..][0..data.len], data.ptr[0..data.len]);
            buf.used += data.len;
        }
    }

    pub fn endCommand(self: *CommandBufferManager) u64 {
        const submission_id = self.next_submission_id;
        self.next_submission_id += 1;

        if (self.current_buffer < self.buffer_count) {
            if (self.buffers[self.current_buffer]) |*buf| {
                buf.submission_id = submission_id;
            }
            self.current_buffer += 1;
        }

        return submission_id;
    }

    pub fn getBuffer(self: *CommandBufferManager, index: usize) ?*const CommandBuffer {
        if (index < self.buffer_count) {
            return self.buffers[index];
        }
        return null;
    }

    pub fn reset(self: *CommandBufferManager) void {
        self.current_buffer = 0;
    }
};

// ============================================================================
// Global Command Buffer Manager
// ============================================================================

pub var g_cmd_buffer_manager: CommandBufferManager = .{};

pub fn initCommandBufferManager() void {
    g_cmd_buffer_manager.init();
}

pub fn beginRecording() void {
    g_cmd_buffer_manager.beginCommand();
}

pub fn addDrawCommand(vertex_count: u32, start_vertex: u32) void {
    var data: [8]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], vertex_count, .little);
    std.mem.writeInt(u32, data[4..8], start_vertex, .little);
    g_cmd_buffer_manager.addCommand(.draw, &data);
}

pub fn addDrawIndexedCommand(index_count: u32, start_index: u32, base_vertex: i32) void {
    var data: [12]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], index_count, .little);
    std.mem.writeInt(u32, data[4..8], start_index, .little);
    std.mem.writeInt(i32, data[8..12], base_vertex, .little);
    g_cmd_buffer_manager.addCommand(.draw_indexed, &data);
}

pub fn endRecording() u64 {
    return g_cmd_buffer_manager.endCommand();
}

pub fn resetCommandBuffers() void {
    g_cmd_buffer_manager.reset();
}
