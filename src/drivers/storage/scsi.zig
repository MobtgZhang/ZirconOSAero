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

//!
//! SCSI命令解析器实现，遵循SPC-4/SBC-3规范
//! 实现SCSI命令集核心功能、命令队列管理、错误处理机制

const std = @import("std");
// TODO: 这些模块依赖尚未完全实现的内核模块，启用前需要先实现对应模块
const ntstatus = @import("../../../ntstatus.zig");
const irp = @import("../../../io/irp.zig");

/// SCSI命令操作码定义 (SPC-4规范)
pub const ScsiOpCode = enum(u8) {
    TEST_UNIT_READY = 0x00,
    REZERO_UNIT = 0x01,
    REQUEST_SENSE = 0x03,
    FORMAT_UNIT = 0x04,
    INQUIRY = 0x12,
    MODE_SELECT6 = 0x15,
    RESERVE6 = 0x16,
    RELEASE6 = 0x17,
    MODE_SENSE6 = 0x1A,
    START_STOP_UNIT = 0x1B,
    SEND_DIAGNOSTIC = 0x1D,
    PREVENT_ALLOW_MEDIUM_REMOVAL = 0x1E,
    READ_CAPACITY10 = 0x25,
    READ10 = 0x28,
    WRITE10 = 0x2A,
    SEEK10 = 0x2B,
    WRITE_VERIFY10 = 0x2E,
    VERIFY10 = 0x2F,
    SYNCHRONIZE_CACHE10 = 0x35,
    WRITE_BUFFER = 0x3B,
    READ_BUFFER = 0x3C,
    MODE_SELECT10 = 0x55,
    MODE_SENSE10 = 0x5A,
    PERSISTENT_RESERVE_IN = 0x5E,
    PERSISTENT_RESERVE_OUT = 0x5F,
    REPORT_LUNS = 0xA0,
    READ16 = 0x88,
    WRITE16 = 0x8A,
    READ_CAPACITY16 = 0x9E,
    SERVICE_ACTION_IN = 0x9E,
    SYNCHRONIZE_CACHE16 = 0x91,
    WRITE_VERIFY16 = 0x8E,
    VERIFY16 = 0x8F,
    UNMAP = 0x42,
    WRITE_SAME10 = 0x41,
    WRITE_SAME16 = 0x93,
    _,
};

/// SCSI命令状态码
pub const ScsiStatus = enum(u8) {
    GOOD = 0x00,
    CHECK_CONDITION = 0x02,
    CONDITION_MET = 0x04,
    BUSY = 0x08,
    INTERMEDIATE = 0x10,
    INTERMEDIATE_CONDITION_MET = 0x14,
    RESERVATION_CONFLICT = 0x18,
    TASK_SET_FULL = 0x28,
    ACA_ACTIVE = 0x30,
    TASK_ABORTED = 0x40,
    _,
};

/// SCSI感知键定义
pub const ScsiSenseKey = enum(u8) {
    NO_SENSE = 0x0,
    RECOVERED_ERROR = 0x1,
    NOT_READY = 0x2,
    MEDIUM_ERROR = 0x3,
    HARDWARE_ERROR = 0x4,
    ILLEGAL_REQUEST = 0x5,
    UNIT_ATTENTION = 0x6,
    DATA_PROTECT = 0x7,
    BLANK_CHECK = 0x8,
    VENDOR_SPECIFIC = 0x9,
    COPY_ABORTED = 0xA,
    ABORTED_COMMAND = 0xB,
    VOLUME_OVERFLOW = 0xD,
    MISCOMPARE = 0xE,
    _,
};

/// SCSI附加感知代码 (部分常用值)
pub const ScsiASC = enum(u8) {
    NO_ADDITIONAL_SENSE_INFORMATION = 0x00,
    LOGICAL_UNIT_NOT_READY_CAUSE_NOT_REPORTABLE = 0x04,
    LOGICAL_UNIT_NOT_READY_INITIALIZING_COMMAND_REQUIRED = 0x04,
    LOGICAL_UNIT_NOT_READY_MANUAL_INTERVENTION_REQUIRED = 0x04,
    LOGICAL_UNIT_NOT_READY_OPERATING_IN_SEQUENTIAL_MODE = 0x04,
    LOGICAL_UNIT_NOT_READY_TRANSITIONING_TO_OPERATIONAL_STATE = 0x04,
    LOGICAL_UNIT_DOES_NOT_RESPOND_TO_SELECTION = 0x05,
    LOGICAL_UNIT_COMMUNICATION_FAILURE = 0x08,
    WRITE_ERROR = 0x0C,
    WRITE_ERROR_RECOVERED_WITH_AUTO_REALLOCATION = 0x0C,
    UNRECOVERED_READ_ERROR = 0x11,
    READ_ERROR_RETRIES_EXHAUSTED = 0x11,
    INVALID_OPERATION_CODE = 0x20,
    INVALID_FIELD_IN_CDB = 0x24,
    LOGICAL_BLOCK_ADDRESS_OUT_OF_RANGE = 0x21,
    INVALID_FIELD_IN_PARAMETER_LIST = 0x26,
    WRITE_PROTECTED = 0x27,
    NOT_READY_TO_READY_CHANGE_MEDIUM_MAY_HAVE_CHANGED = 0x28,
    POWER_ON_RESET_OR_BUS_DEVICE_RESET_OCCURRED = 0x29,
    MEDIUM_NOT_PRESENT = 0x3A,
    _,
};

/// SCSI CDB (命令描述块) 通用结构
pub const ScsiCDB = extern union {
    bytes: [16]u8,
    test_unit_ready: extern struct {
        opcode: u8,
        reserved: [4]u8,
        control: u8,
    },
    inquiry: extern struct {
        opcode: u8,
        evpd: u1,
        reserved1: u3,
        page_code: u4,
        reserved2: [2]u8,
        allocation_length: u8,
        control: u8,
    },
    request_sense: extern struct {
        opcode: u8,
        desc: u1,
        reserved: [2]u8,
        allocation_length: u8,
        control: u8,
    },
    read_capacity10: extern struct {
        opcode: u8,
        reserved1: u8,
        lba: u32,
        reserved2: [2]u8,
        pmi: u1,
        reserved3: u7,
        control: u8,
    },
    read_capacity16: extern struct {
        opcode: u8,
        service_action: u5,
        reserved1: u3,
        lba: u64,
        allocation_length: u32,
        reserved2: u8,
        control: u8,
    },
    read10: extern struct {
        opcode: u8,
        reserved1: u8,
        lba: u32,
        reserved2: u8,
        transfer_length: u16,
        control: u8,
    },
    write10: extern struct {
        opcode: u8,
        reserved1: u8,
        lba: u32,
        reserved2: u8,
        transfer_length: u16,
        control: u8,
    },
    read16: extern struct {
        opcode: u8,
        dpo: u1,
        fua: u1,
        rarc: u1,
        reserved1: u5,
        lba: u64,
        transfer_length: u32,
        reserved2: u8,
        control: u8,
    },
    write16: extern struct {
        opcode: u8,
        dpo: u1,
        fua: u1,
        reserved1: u6,
        lba: u64,
        transfer_length: u32,
        reserved2: u8,
        control: u8,
    },
    unmap: extern struct {
        opcode: u8,
        reserved1: [3]u8,
        parameter_list_length: u16,
        reserved2: u8,
        control: u8,
    },
    start_stop_unit: extern struct {
        opcode: u8,
        immediate: u1,
        reserved1: u7,
        reserved2: [2]u8,
        power_condition_modifier: u4,
        reserved3: u2,
        loej: u1,
        start: u1,
        control: u8,
    },
};

/// SCSI INQUIRY响应结构
pub const ScsiInquiryData = extern struct {
    peripheral_device_type: u5,
    peripheral_qualifier: u3,
    rmb: u1,
    reserved1: u7,
    version: u8,
    response_data_format: u4,
    hiersup: u1,
    normaca: u1,
    reserved2: u1,
    aerc: u1,
    additional_length: u8,
    sccs: u1,
    acc: u1,
    tpg: u2,
    reserved3: u1,
    protect: u1,
    reserved4: u1,
    encserv: u1,
    vs: u1,
    multip: u1,
    mediachanger: u1,
    addr16: u1,
    reserved5: u1,
    wbus16: u1,
    sync: u1,
    cmdque: u1,
    vendor_id: [8]u8,
    product_id: [16]u8,
    product_revision: [4]u8,
};

/// SCSI READ CAPACITY (10字节) 响应结构
pub const ScsiReadCapacity10Data = extern struct {
    returned_lba: u32,
    block_length: u32,
};

/// SCSI READ CAPACITY (16字节) 响应结构
pub const ScsiReadCapacity16Data = extern struct {
    returned_lba: u64,
    block_length: u32,
    prot_en: u1,
    p_type: u3,
    reserved1: u3,
    logical_blocks_per_physical_block_exponent: u4,
    lowest_aligned_logical_block_address: u12,
    reserved2: [16]u8,
};

/// SCSI REQUEST SENSE响应结构 (固定格式)
pub const ScsiRequestSenseData = extern struct {
    response_code: u7,
    valid: u1,
    segment_number: u8,
    sense_key: u4,
    reserved1: u1,
    ili: u1,
    eom: u1,
    filemark: u1,
    information: u32,
    additional_sense_length: u8,
    command_specific_information: u32,
    asc: u8,
    ascq: u8,
    field_replaceable_unit_code: u8,
    sense_key_specific: [3]u8,
};

/// SCSI命令执行结果
pub const ScsiCommandResult = struct {
    status: ScsiStatus,
    sense_key: ScsiSenseKey = .NO_SENSE,
    asc: ScsiASC = .NO_ADDITIONAL_SENSE_INFORMATION,
    ascq: u8 = 0,
    bytes_transferred: usize = 0,
};

/// SCSI命令解析器
pub const ScsiParser = struct {
    /// 解析SCSI命令，返回命令类型和相关参数
    pub fn parse(cdb: *const ScsiCDB) !ScsiOpCode {
        const opcode = @as(ScsiOpCode, @enumFromInt(cdb.bytes[0]));

        // 验证命令长度合法性
        switch (opcode) {
            .TEST_UNIT_READY, .REQUEST_SENSE, .INQUIRY, .READ_CAPACITY10, .START_STOP_UNIT, .PREVENT_ALLOW_MEDIUM_REMOVAL => {
                if (cdb.bytes[0] & 0xE0 != 0) return error.InvalidCDBLength; // 6字节命令
            },
            .READ10, .WRITE10, .WRITE_VERIFY10, .VERIFY10, .SYNCHRONIZE_CACHE10, .MODE_SELECT10, .MODE_SENSE10 => {
                if (cdb.bytes[0] & 0xE0 != 0x20) return error.InvalidCDBLength; // 10字节命令
            },
            .READ16, .WRITE16, .READ_CAPACITY16, .WRITE_VERIFY16, .VERIFY16, .SYNCHRONIZE_CACHE16 => {
                if (cdb.bytes[0] & 0xE0 != 0x80) return error.InvalidCDBLength; // 16字节命令
            },
            else => {},
        }

        return opcode;
    }

    /// 获取命令中的LBA地址
    pub fn getLBA(cdb: *const ScsiCDB, opcode: ScsiOpCode) !u64 {
        switch (opcode) {
            .READ10, .WRITE10, .READ_CAPACITY10 => {
                return @as(u64, std.mem.bigToNative(u32, cdb.read10.lba));
            },
            .READ16, .WRITE16, .READ_CAPACITY16 => {
                return std.mem.bigToNative(u64, cdb.read16.lba);
            },
            else => return error.NoLBAInCommand,
        }
    }

    /// 获取命令中的传输长度 (扇区数)
    pub fn getTransferLength(cdb: *const ScsiCDB, opcode: ScsiOpCode) !u32 {
        switch (opcode) {
            .READ10, .WRITE10 => {
                return @as(u32, std.mem.bigToNative(u16, cdb.read10.transfer_length));
            },
            .READ16, .WRITE16 => {
                return std.mem.bigToNative(u32, cdb.read16.transfer_length);
            },
            else => return error.NoTransferLengthInCommand,
        }
    }

    /// 生成INQUIRY响应数据
    pub fn generateInquiryResponse(vendor_id: []const u8, product_id: []const u8, product_rev: []const u8, is_removable: bool) ScsiInquiryData {
        var resp: ScsiInquiryData = std.mem.zeroes(ScsiInquiryData);
        resp.peripheral_device_type = 0x00; // 直接访问块设备
        resp.peripheral_qualifier = 0x00; // 设备已连接
        resp.rmb = if (is_removable) 1 else 0;
        resp.version = 0x05; // SPC-3兼容
        resp.response_data_format = 0x02; // SPC-2+响应格式
        resp.additional_length = 0x1F; // 31字节附加数据

        // 填充ID信息
        @memcpy(resp.vendor_id[0..vendor_id.len], vendor_id);
        if (vendor_id.len < 8) @memset(resp.vendor_id[vendor_id.len..], ' ');

        @memcpy(resp.product_id[0..product_id.len], product_id);
        if (product_id.len < 16) @memset(resp.product_id[product_id.len..], ' ');

        @memcpy(resp.product_revision[0..product_rev.len], product_rev);
        if (product_rev.len < 4) @memset(resp.product_revision[product_rev.len..], ' ');

        resp.cmdque = 1; // 支持命令队列
        return resp;
    }

    /// 生成READ CAPACITY 10响应数据
    pub fn generateReadCapacity10Response(total_sectors: u64, sector_size: u32) ScsiReadCapacity10Data {
        var resp: ScsiReadCapacity10Data = undefined;
        resp.returned_lba = std.mem.nativeToBig(u32, @as(u32, @truncate(total_sectors - 1)));
        resp.block_length = std.mem.nativeToBig(u32, sector_size);
        return resp;
    }

    /// 生成READ CAPACITY 16响应数据
    pub fn generateReadCapacity16Response(total_sectors: u64, sector_size: u32, physical_block_exponent: u4) ScsiReadCapacity16Data {
        var resp: ScsiReadCapacity16Data = std.mem.zeroes(ScsiReadCapacity16Data);
        resp.returned_lba = std.mem.nativeToBig(u64, total_sectors - 1);
        resp.block_length = std.mem.nativeToBig(u32, sector_size);
        resp.logical_blocks_per_physical_block_exponent = physical_block_exponent;
        return resp;
    }

    /// 生成REQUEST SENSE响应数据
    pub fn generateRequestSenseResponse(sense_key: ScsiSenseKey, asc: ScsiASC, ascq: u8) ScsiRequestSenseData {
        var resp: ScsiRequestSenseData = std.mem.zeroes(ScsiRequestSenseData);
        resp.response_code = 0x70; // 当前错误固定格式
        resp.valid = 1;
        resp.sense_key = @intFromEnum(sense_key);
        resp.additional_sense_length = 0x0A; // 10字节附加数据
        resp.asc = @intFromEnum(asc);
        resp.ascq = ascq;
        return resp;
    }

    /// 检查命令是否为读命令
    pub fn isReadCommand(opcode: ScsiOpCode) bool {
        return switch (opcode) {
            .READ10, .READ16, .READ_BUFFER, .INQUIRY, .REQUEST_SENSE, .READ_CAPACITY10, .READ_CAPACITY16, .MODE_SENSE6, .MODE_SENSE10 => true,
            else => false,
        };
    }

    /// 检查命令是否为写命令
    pub fn isWriteCommand(opcode: ScsiOpCode) bool {
        return switch (opcode) {
            .WRITE10, .WRITE16, .WRITE_BUFFER, .MODE_SELECT6, .MODE_SELECT10, .FORMAT_UNIT, .UNMAP, .WRITE_SAME10, .WRITE_SAME16 => true,
            else => false,
        };
    }
};

/// SCSI命令优先级定义
pub const ScsiCommandPriority = enum(u8) {
    LOW = 0,
    NORMAL = 1,
    HIGH = 2,
    REALTIME = 3,
};

/// SCSI命令队列项
pub const ScsiCommand = struct {
    cdb: ScsiCDB,
    opcode: ScsiOpCode,
    priority: ScsiCommandPriority = .NORMAL,
    buffer: []u8,
    buffer_length: usize,
    lba: u64 = 0,
    transfer_length: u32 = 0,
    irp: ?*irp.IRP = null,
    timeout_ms: u32 = 30000, // 默认30秒超时
    retries: u8 = 0,
    max_retries: u8 = 3,
    submitted_time: u64 = 0,
    completed: bool = false,
    result: ScsiCommandResult = undefined,
    complete_callback: ?fn (*ScsiCommand) void = null,
};

/// SCSI命令队列管理
pub const ScsiCommandQueue = struct {
    allocator: std.mem.Allocator,
    queue: std.TailQueue(ScsiCommand),
    max_depth: u32 = 32,
    current_depth: u32 = 0,
    merge_enabled: bool = true,
    ncq_supported: bool = true,
    lock: std.Thread.Mutex = .{},

    /// 初始化命令队列
    pub fn init(allocator: std.mem.Allocator, max_depth: u32) ScsiCommandQueue {
        return ScsiCommandQueue{
            .allocator = allocator,
            .queue = .{},
            .max_depth = max_depth,
        };
    }

    /// 销毁命令队列
    pub fn deinit(self: *ScsiCommandQueue) void {
        self.lock.lock();
        defer self.lock.unlock();

        while (self.queue.popFirst()) |node| {
            self.allocator.destroy(node);
        }
    }

    /// 尝试合并相邻的读写命令
    fn tryMergeCommands(self: *ScsiCommandQueue, new_cmd: *ScsiCommand) bool {
        if (!self.merge_enabled) return false;
        if (new_cmd.opcode != .READ10 and new_cmd.opcode != .READ16 and
            new_cmd.opcode != .WRITE10 and new_cmd.opcode != .WRITE16) return false;

        var current = self.queue.first;
        while (current) |node| : (current = node.next) {
            const cmd = &node.data;
            if (cmd.opcode != new_cmd.opcode) continue;
            if (cmd.priority != new_cmd.priority) continue;

            // 检查是否相邻且连续
            if (cmd.lba + cmd.transfer_length == new_cmd.lba) {
                // 可以合并
                const total_length = cmd.transfer_length + new_cmd.transfer_length;
                if (total_length > 0xFFFF) continue; // 16位传输长度最大为65535

                // 扩展缓冲区
                const new_buffer = self.allocator.alloc(u8, (total_length * 512)) catch return false;
                @memcpy(new_buffer[0..cmd.buffer.len], cmd.buffer);
                @memcpy(new_buffer[cmd.buffer.len..], new_cmd.buffer);

                self.allocator.free(cmd.buffer);
                cmd.buffer = new_buffer;
                cmd.transfer_length = @as(u16, @truncate(total_length));
                return true;
            }
        }

        return false;
    }

    /// 提交命令到队列
    pub fn submitCommand(self: *ScsiCommandQueue, cmd: ScsiCommand) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.current_depth >= self.max_depth) return error.QueueFull;

        // 尝试合并命令
        if (self.tryMergeCommands(&cmd)) return;

        // 创建新节点
        const node = try self.allocator.create(std.TailQueue(ScsiCommand).Node);
        node.data = cmd;

        // 根据优先级插入到合适位置
        var current = self.queue.first;
        var insert_pos: ?*std.TailQueue(ScsiCommand).Node = null;

        while (current) |curr| : (current = curr.next) {
            if (@intFromEnum(curr.data.priority) < @intFromEnum(cmd.priority)) {
                insert_pos = curr;
                break;
            }
        }

        if (insert_pos) |pos| {
            self.queue.insertBefore(pos, node);
        } else {
            self.queue.append(node);
        }

        self.current_depth += 1;
    }

    /// 从队列取出下一个要执行的命令
    pub fn dequeueCommand(self: *ScsiCommandQueue) ?*ScsiCommand {
        self.lock.lock();
        defer self.lock.unlock();

        const node = self.queue.popFirst() orelse return null;
        self.current_depth -= 1;
        return &node.data;
    }

    /// 取消指定IRP关联的命令
    pub fn cancelCommandByIRP(self: *ScsiCommandQueue, irp_ptr: *irp.IRP) void {
        self.lock.lock();
        defer self.lock.unlock();

        var current = self.queue.first;
        while (current) |node| : (current = node.next) {
            if (node.data.irp == irp_ptr) {
                // 标记为已取消并从队列移除
                node.data.completed = true;
                node.data.result.status = .TASK_ABORTED;
                if (node.data.complete_callback) |callback| {
                    callback(&node.data);
                }
                self.queue.remove(node);
                self.allocator.destroy(node);
                self.current_depth -= 1;
                break;
            }
        }
    }

    /// 检查并处理超时命令
    pub fn processTimeouts(self: *ScsiCommandQueue, current_time: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        var current = self.queue.first;
        while (current) |node| : (current = node.next) {
            const cmd = &node.data;
            if (cmd.submitted_time + cmd.timeout_ms < current_time) {
                if (cmd.retries < cmd.max_retries) {
                    // 重试命令
                    cmd.retries += 1;
                    cmd.submitted_time = current_time;
                } else {
                    // 超时失败
                    cmd.completed = true;
                    cmd.result.status = .TASK_ABORTED;
                    cmd.result.sense_key = .HARDWARE_ERROR;
                    cmd.result.asc = .LOGICAL_UNIT_COMMUNICATION_FAILURE;
                    if (cmd.complete_callback) |callback| {
                        callback(cmd);
                    }
                    self.queue.remove(node);
                    self.allocator.destroy(node);
                    self.current_depth -= 1;
                }
            }
        }
    }

    /// 获取当前队列深度
    pub fn getCurrentDepth(self: *ScsiCommandQueue) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.current_depth;
    }

    /// 清空队列
    pub fn flush(self: *ScsiCommandQueue) void {
        self.lock.lock();
        defer self.lock.unlock();

        while (self.queue.popFirst()) |node| {
            if (!node.data.completed) {
                node.data.completed = true;
                node.data.result.status = .TASK_ABORTED;
                if (node.data.complete_callback) |callback| {
                    callback(&node.data);
                }
            }
            self.allocator.destroy(node);
        }
        self.current_depth = 0;
    }
};
