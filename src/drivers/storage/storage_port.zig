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
//! 存储端口抽象层
//! 统一AHCI/NVMe/USB等不同存储控制器的命令处理接口

const std = @import("std");
// TODO: 这些模块依赖尚未完全实现的内核模块，启用前需要先实现对应模块
const ntstatus = @import("../../../ntstatus.zig");
const irp = @import("../../../io/irp.zig");
const scsi = @import("scsi.zig");

/// 存储控制器类型
pub const StorageControllerType = enum(u8) {
    AHCI,
    NVMe,
    USB_MASS_STORAGE,
    VIRTIO_BLK,
    IDE,
    UNKNOWN,
};

/// 存储设备特性
pub const StorageDeviceFeatures = packed struct(u32) {
    removable: bool = false,
    ncq_supported: bool = false,
    tcq_supported: bool = false,
    trim_supported: bool = false,
    write_cache_supported: bool = false,
    smart_supported: bool = false,
    power_management_supported: bool = false,
    reserved: u25 = 0,
};

/// 存储设备信息
pub const StorageDeviceInfo = struct {
    vendor_id: []const u8,
    product_id: []const u8,
    revision: []const u8,
    serial_number: []const u8,
    total_sectors: u64,
    sector_size: u32,
    physical_block_size: u32,
    features: StorageDeviceFeatures,
    max_queue_depth: u32,
    max_transfer_size: u32,
};

/// 存储端口操作函数表
pub const StoragePortOperations = struct {
    /// 初始化控制器
    init: fn (*StoragePort) ntstatus.NTSTATUS,
    /// 重置控制器
    reset: fn (*StoragePort) ntstatus.NTSTATUS,
    /// 提交SCSI命令
    submit_scsi_command: fn (*StoragePort, *scsi.ScsiCommand) ntstatus.NTSTATUS,
    /// 中止命令
    abort_command: fn (*StoragePort, *scsi.ScsiCommand) ntstatus.NTSTATUS,
    /// 获取设备信息
    get_device_info: fn (*StoragePort, u32) ?*StorageDeviceInfo,
    /// 电源管理控制
    set_power_state: fn (*StoragePort, u32) ntstatus.NTSTATUS,
    /// 处理中断
    handle_interrupt: fn (*StoragePort) void,
    /// 销毁控制器
    deinit: fn (*StoragePort) void,
};

/// NCQ命令信息
pub const NCQCommand = struct {
    tag: u16,
    command: *scsi.ScsiCommand,
    completed: bool,
    result: scsi.ScsiCommandResult,
};

/// 存储端口抽象基类
pub const StoragePort = struct {
    type: StorageControllerType,
    ops: *const StoragePortOperations,
    allocator: std.mem.Allocator,
    device_count: u32,
    command_queue: scsi.ScsiCommandQueue,
    ncq_commands: []NCQCommand,
    current_ncq_depth: u32,
    max_ncq_depth: u32,
    features: StorageDeviceFeatures,
    private_data: ?*anyopaque = null,
    lock: std.Thread.Mutex = .{},

    /// 初始化存储端口
    pub fn init(allocator: std.mem.Allocator, controller_type: StorageControllerType, ops: *const StoragePortOperations, max_queue_depth: u32, max_ncq_depth: u32) !*StoragePort {
        const port = try allocator.create(StoragePort);
        port.* = StoragePort{
            .type = controller_type,
            .ops = ops,
            .allocator = allocator,
            .device_count = 0,
            .command_queue = scsi.ScsiCommandQueue.init(allocator, max_queue_depth),
            .ncq_commands = try allocator.alloc(NCQCommand, max_ncq_depth),
            .current_ncq_depth = 0,
            .max_ncq_depth = max_ncq_depth,
            .features = std.mem.zeroes(StorageDeviceFeatures),
        };

        // 初始化NCQ命令表
        for (port.ncq_commands, 0..) |*cmd, i| {
            cmd.tag = @as(u16, @truncate(i));
            cmd.completed = true;
        }

        // 调用控制器特定的初始化
        const status = ops.init(port);
        if (!ntstatus.NT_SUCCESS(status)) {
            port.deinit();
            return error.InitializationFailed;
        }

        return port;
    }

    /// 销毁存储端口
    pub fn deinit(self: *StoragePort) void {
        self.lock.lock();
        defer self.lock.unlock();

        // 清空命令队列
        self.command_queue.flush();

        // 调用控制器特定的销毁函数
        self.ops.deinit(self);

        // 释放资源
        self.allocator.free(self.ncq_commands);
        self.allocator.destroy(self);
    }

    /// 重置存储端口
    pub fn reset(self: *StoragePort) ntstatus.NTSTATUS {
        self.lock.lock();
        defer self.lock.unlock();

        self.command_queue.flush();
        self.current_ncq_depth = 0;

        for (self.ncq_commands) |*cmd| {
            cmd.completed = true;
        }

        return self.ops.reset(self);
    }

    /// 获取可用的NCQ标签
    fn getAvailableNCQTag(self: *StoragePort) ?u16 {
        for (self.ncq_commands, 0..) |*cmd, i| {
            if (cmd.completed) {
                return @as(u16, @truncate(i));
            }
        }
        return null;
    }

    /// 提交SCSI命令到存储端口
    pub fn submitCommand(self: *StoragePort, cmd: *scsi.ScsiCommand) ntstatus.NTSTATUS {
        self.lock.lock();
        defer self.lock.unlock();

        // 如果支持NCQ并且命令是读写命令，尝试使用NCQ提交
        if (self.features.ncq_supported and
            (cmd.opcode == .READ10 or cmd.opcode == .READ16 or
                cmd.opcode == .WRITE10 or cmd.opcode == .WRITE16))
        {
            if (self.current_ncq_depth < self.max_ncq_depth) {
                if (self.getAvailableNCQTag()) |tag| {
                    self.ncq_commands[tag].command = cmd;
                    self.ncq_commands[tag].completed = false;
                    self.current_ncq_depth += 1;

                    const status = self.ops.submit_scsi_command(self, cmd);
                    if (ntstatus.NT_SUCCESS(status)) {
                        return status;
                    }

                    // 提交失败，释放标签
                    self.ncq_commands[tag].completed = true;
                    self.current_ncq_depth -= 1;
                }
            }
        }

        // 不支持NCQ或者NCQ队列满，使用普通队列
        return self.command_queue.submitCommand(cmd.*) catch |err| switch (err) {
            error.QueueFull => ntstatus.STATUS_INSUFFICIENT_RESOURCES,
            else => ntstatus.STATUS_UNSUCCESSFUL,
        };
    }

    /// 完成NCQ命令
    pub fn completeNCQCommand(self: *StoragePort, tag: u16, result: scsi.ScsiCommandResult) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (tag >= self.ncq_commands.len) return;

        const ncq_cmd = &self.ncq_commands[tag];
        if (ncq_cmd.completed) return;

        ncq_cmd.completed = true;
        ncq_cmd.result = result;
        self.current_ncq_depth -= 1;

        // 调用完成回调
        if (ncq_cmd.command.complete_callback) |callback| {
            ncq_cmd.command.result = result;
            ncq_cmd.command.completed = true;
            callback(ncq_cmd.command);
        }
    }

    /// 处理中断
    pub fn handleInterrupt(self: *StoragePort) void {
        self.ops.handle_interrupt(self);
    }

    /// 获取设备信息
    pub fn getDeviceInfo(self: *StoragePort, lun: u32) ?*StorageDeviceInfo {
        return self.ops.get_device_info(self, lun);
    }

    /// 处理超时命令
    pub fn processTimeouts(self: *StoragePort, current_time: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        // 处理队列中的超时命令
        self.command_queue.processTimeouts(current_time);

        // 处理NCQ中的超时命令
        for (self.ncq_commands) |*ncq_cmd| {
            if (!ncq_cmd.completed) {
                const cmd = ncq_cmd.command;
                if (cmd.submitted_time + cmd.timeout_ms < current_time) {
                    if (cmd.retries < cmd.max_retries) {
                        // 重试命令
                        cmd.retries += 1;
                        cmd.submitted_time = current_time;
                        _ = self.ops.submit_scsi_command(self, cmd);
                    } else {
                        // 超时失败
                        ncq_cmd.completed = true;
                        self.current_ncq_depth -= 1;

                        cmd.completed = true;
                        cmd.result.status = .TASK_ABORTED;
                        cmd.result.sense_key = .HARDWARE_ERROR;
                        cmd.result.asc = .LOGICAL_UNIT_COMMUNICATION_FAILURE;

                        if (cmd.complete_callback) |callback| {
                            callback(cmd);
                        }
                    }
                }
            }
        }
    }
};

/// NT标准存储IOCTL控制码定义 (基于微软公开文档)
const IOCTL_DISK_BASE = 0x00000007;
const IOCTL_STORAGE_BASE = 0x0000002d;
const IOCTL_VOLUME_BASE = 0x00000056;

const METHOD_BUFFERED = 0;
const FILE_ANY_ACCESS = 0;
const FILE_READ_ACCESS = 1;
const FILE_WRITE_ACCESS = 2;

fn CTL_CODE(DeviceType: u32, Function: u32, Method: u32, Access: u32) u32 {
    return (DeviceType << 16) | (Access << 14) | (Function << 2) | Method;
}

pub const IOCTL_DISK_GET_DRIVE_GEOMETRY = CTL_CODE(IOCTL_DISK_BASE, 0x0000, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const IOCTL_DISK_GET_LENGTH_INFO = CTL_CODE(IOCTL_DISK_BASE, 0x0017, METHOD_BUFFERED, FILE_READ_ACCESS);
pub const IOCTL_DISK_GET_PARTITION_INFO_EX = CTL_CODE(IOCTL_DISK_BASE, 0x0012, METHOD_BUFFERED, FILE_READ_ACCESS);
pub const IOCTL_DISK_SET_PARTITION_INFO_EX = CTL_CODE(IOCTL_DISK_BASE, 0x0013, METHOD_BUFFERED, FILE_WRITE_ACCESS);
pub const IOCTL_DISK_FORMAT_TRACKS = CTL_CODE(IOCTL_DISK_BASE, 0x0006, METHOD_BUFFERED, FILE_WRITE_ACCESS);
pub const IOCTL_DISK_FORMAT_DRIVE = CTL_CODE(IOCTL_DISK_BASE, 0x0019, METHOD_BUFFERED, FILE_WRITE_ACCESS);
pub const IOCTL_DISK_EJECT_MEDIA = CTL_CODE(IOCTL_DISK_BASE, 0x0002, METHOD_BUFFERED, FILE_READ_ACCESS);
pub const IOCTL_STORAGE_QUERY_PROPERTY = CTL_CODE(IOCTL_STORAGE_BASE, 0x0500, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const IOCTL_STORAGE_EJECTION_CONTROL = CTL_CODE(IOCTL_STORAGE_BASE, 0x0250, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const IOCTL_VOLUME_GET_VOLUME_NAME = CTL_CODE(IOCTL_VOLUME_BASE, 0x0000, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = CTL_CODE(IOCTL_VOLUME_BASE, 0x0001, METHOD_BUFFERED, FILE_ANY_ACCESS);
pub const SMART_RCV_DRIVE_DATA = CTL_CODE(IOCTL_DISK_BASE, 0x007c, METHOD_BUFFERED, FILE_READ_ACCESS);

/// DISK_GEOMETRY 结构 (NT标准)
pub const DISK_GEOMETRY = extern struct {
    Cylinders: u64,
    MediaType: u32,
    TracksPerCylinder: u32,
    SectorsPerTrack: u32,
    BytesPerSector: u32,
};

/// GET_LENGTH_INFORMATION 结构 (NT标准)
pub const GET_LENGTH_INFORMATION = extern struct {
    Length: u64,
};

/// PARTITION_INFORMATION_EX 结构 (NT标准)
pub const PARTITION_STYLE = enum(u32) {
    MBR = 0,
    GPT = 1,
    RAW = 2,
};

pub const PARTITION_INFORMATION_MBR = extern struct {
    PartitionType: u8,
    BootIndicator: bool,
    RecognizedPartition: bool,
    HiddenSectors: u32,
    PartitionId: [16]u8, // GUID
};

pub const PARTITION_INFORMATION_GPT = extern struct {
    PartitionType: [16]u8, // GUID
    PartitionId: [16]u8, // GUID
    Attributes: u64,
    Name: [72]u16, // UTF-16
};

pub const PARTITION_INFORMATION_EX = extern struct {
    PartitionStyle: PARTITION_STYLE,
    StartingOffset: u64,
    PartitionLength: u64,
    PartitionNumber: u32,
    RewritePartition: bool,
    IsServicePartition: bool,
    PartitionInfo: extern union {
        Mbr: PARTITION_INFORMATION_MBR,
        Gpt: PARTITION_INFORMATION_GPT,
    },
};

/// STORAGE_PROPERTY_QUERY 结构 (NT标准)
pub const STORAGE_PROPERTY_ID = enum(u32) {
    StorageDeviceProperty = 0,
    StorageAdapterProperty = 1,
    StorageDeviceIdProperty = 2,
    StorageDeviceUniqueIdProperty = 3,
    StorageDeviceWriteCacheProperty = 4,
    StorageMiniportProperty = 5,
    StorageAccessAlignmentProperty = 6,
    StorageDeviceSeekPenaltyProperty = 7,
    StorageDeviceTrimProperty = 8,
};

pub const STORAGE_QUERY_TYPE = enum(u32) {
    PropertyStandardQuery = 0,
    PropertyExistsQuery = 1,
    PropertyMaskQuery = 2,
    PropertyQueryMaxDefined = 3,
};

pub const STORAGE_PROPERTY_QUERY = extern struct {
    PropertyId: STORAGE_PROPERTY_ID,
    QueryType: STORAGE_QUERY_TYPE,
    AdditionalParameters: [1]u8,
};

/// STORAGE_DEVICE_DESCRIPTOR 结构 (NT标准)
pub const STORAGE_DEVICE_DESCRIPTOR = extern struct {
    Version: u32,
    Size: u32,
    DeviceType: u8,
    DeviceTypeModifier: u8,
    RemovableMedia: bool,
    CommandQueueing: bool,
    VendorIdOffset: u32,
    ProductIdOffset: u32,
    ProductRevisionOffset: u32,
    SerialNumberOffset: u32,
    BusType: u32,
    RawPropertiesLength: u32,
    RawDeviceProperties: [1]u8,
};

/// SMART数据结构
pub const SMART_DATA = extern struct {
    Version: u16,
    Reserved: u16,
    Attributes: [30]extern struct {
        Id: u8,
        Status: u16,
        Value: u8,
        Worst: u8,
        Raw: [6]u8,
        Reserved: u8,
    },
};

/// VOLUME_NAME结构
pub const VOLUME_NAME = extern struct {
    NameLength: u32,
    Name: [256]u16, // UTF-16
};

/// VOLUME_DISK_EXTENTS结构
pub const DISK_EXTENT = extern struct {
    DiskNumber: u32,
    StartingOffset: u64,
    ExtentLength: u64,
};

pub const VOLUME_DISK_EXTENTS = extern struct {
    NumberOfDiskExtents: u32,
    Extents: [1]DISK_EXTENT,
};

/// 执行IOCTL请求
pub fn handleIOCTL(self: *StoragePort, irp_ptr: *irp.IRP) ntstatus.NTSTATUS {
    const stack = irp_ptr.getCurrentStackLocation();
    const io_control_code = stack.Parameters.DeviceIoControl.IoControlCode;
    const input_buffer = irp_ptr.AssociatedIrp.SystemBuffer;
    const input_buffer_length = stack.Parameters.DeviceIoControl.InputBufferLength;
    const output_buffer = irp_ptr.AssociatedIrp.SystemBuffer;
    const output_buffer_length = stack.Parameters.DeviceIoControl.OutputBufferLength;

    // 获取设备信息 (LUN 0)
    const dev_info = self.getDeviceInfo(0) orelse return ntstatus.STATUS_NO_SUCH_DEVICE;

    switch (io_control_code) {
        IOCTL_DISK_GET_DRIVE_GEOMETRY => {
            if (output_buffer_length < @sizeOf(DISK_GEOMETRY)) {
                irp_ptr.IoStatus.Information = @sizeOf(DISK_GEOMETRY);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const geometry: *DISK_GEOMETRY = @ptrCast(@alignCast(output_buffer));
            geometry.BytesPerSector = dev_info.sector_size;
            geometry.SectorsPerTrack = 63; // 模拟CHS参数
            geometry.TracksPerCylinder = 255;
            geometry.Cylinders = dev_info.total_sectors / (63 * 255);
            geometry.MediaType = 0; // Fixed media

            irp_ptr.IoStatus.Information = @sizeOf(DISK_GEOMETRY);
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_DISK_GET_LENGTH_INFO => {
            if (output_buffer_length < @sizeOf(GET_LENGTH_INFORMATION)) {
                irp_ptr.IoStatus.Information = @sizeOf(GET_LENGTH_INFORMATION);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const length_info: *GET_LENGTH_INFORMATION = @ptrCast(@alignCast(output_buffer));
            length_info.Length = dev_info.total_sectors * dev_info.sector_size;

            irp_ptr.IoStatus.Information = @sizeOf(GET_LENGTH_INFORMATION);
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_DISK_GET_PARTITION_INFO_EX => {
            if (output_buffer_length < @sizeOf(PARTITION_INFORMATION_EX)) {
                irp_ptr.IoStatus.Information = @sizeOf(PARTITION_INFORMATION_EX);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const part_info: *PARTITION_INFORMATION_EX = @ptrCast(@alignCast(output_buffer));
            // 暂时返回MBR类型的整个磁盘分区信息
            part_info.PartitionStyle = .MBR;
            part_info.StartingOffset = 0;
            part_info.PartitionLength = dev_info.total_sectors * dev_info.sector_size;
            part_info.PartitionNumber = 0;
            part_info.RewritePartition = false;
            part_info.IsServicePartition = false;
            part_info.PartitionInfo.Mbr.PartitionType = 0x07; // NTFS
            part_info.PartitionInfo.Mbr.BootIndicator = true;
            part_info.PartitionInfo.Mbr.RecognizedPartition = true;
            part_info.PartitionInfo.Mbr.HiddenSectors = 0;
            @memset(&part_info.PartitionInfo.Mbr.PartitionId, 0);

            irp_ptr.IoStatus.Information = @sizeOf(PARTITION_INFORMATION_EX);
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_DISK_SET_PARTITION_INFO_EX => {
            // 暂时返回成功，后续实现分区修改功能
            irp_ptr.IoStatus.Information = 0;
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_DISK_FORMAT_TRACKS, IOCTL_DISK_FORMAT_DRIVE => {
            // 模拟格式化成功，实际存储设备不需要低级格式化
            irp_ptr.IoStatus.Information = 0;
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_STORAGE_QUERY_PROPERTY => {
            if (input_buffer_length < @sizeOf(STORAGE_PROPERTY_QUERY)) {
                irp_ptr.IoStatus.Information = @sizeOf(STORAGE_PROPERTY_QUERY);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const query: *const STORAGE_PROPERTY_QUERY = @ptrCast(@alignCast(input_buffer));
            if (query.PropertyId == .StorageDeviceProperty and query.QueryType == .PropertyStandardQuery) {
                const required_size = @sizeOf(STORAGE_DEVICE_DESCRIPTOR) +
                    dev_info.vendor_id.len + 1 +
                    dev_info.product_id.len + 1 +
                    dev_info.revision.len + 1 +
                    dev_info.serial_number.len + 1;

                if (output_buffer_length < required_size) {
                    irp_ptr.IoStatus.Information = required_size;
                    return ntstatus.STATUS_BUFFER_TOO_SMALL;
                }

                const descriptor: *STORAGE_DEVICE_DESCRIPTOR = @ptrCast(@alignCast(output_buffer));
                descriptor.Version = @sizeOf(STORAGE_DEVICE_DESCRIPTOR);
                descriptor.Size = @as(u32, @truncate(required_size));
                descriptor.DeviceType = 0; // Direct access device
                descriptor.DeviceTypeModifier = 0;
                descriptor.RemovableMedia = dev_info.features.removable;
                descriptor.CommandQueueing = dev_info.features.ncq_supported;

                // 计算偏移 (手动计算的STORAGE_DEVICE_DESCRIPTOR中RawDeviceProperties字段的偏移量为36字节)
                var current_offset: u32 = 36;
                descriptor.VendorIdOffset = current_offset;
                @memcpy(output_buffer[current_offset..][0..dev_info.vendor_id.len], dev_info.vendor_id);
                output_buffer[current_offset + dev_info.vendor_id.len] = 0;
                current_offset += dev_info.vendor_id.len + 1;

                descriptor.ProductIdOffset = current_offset;
                @memcpy(output_buffer[current_offset..][0..dev_info.product_id.len], dev_info.product_id);
                output_buffer[current_offset + dev_info.product_id.len] = 0;
                current_offset += dev_info.product_id.len + 1;

                descriptor.ProductRevisionOffset = current_offset;
                @memcpy(output_buffer[current_offset..][0..dev_info.revision.len], dev_info.revision);
                output_buffer[current_offset + dev_info.revision.len] = 0;
                current_offset += dev_info.revision.len + 1;

                descriptor.SerialNumberOffset = current_offset;
                @memcpy(output_buffer[current_offset..][0..dev_info.serial_number.len], dev_info.serial_number);
                output_buffer[current_offset + dev_info.serial_number.len] = 0;
                current_offset += dev_info.serial_number.len + 1;

                descriptor.BusType = switch (self.type) {
                    .AHCI => 3, // SATA
                    .NVMe => 11, // NVMe
                    .USB_MASS_STORAGE => 7, // USB
                    .VIRTIO_BLK => 14, // Virtual
                    .IDE => 2, // IDE
                    else => 0, // Unknown
                };

                descriptor.RawPropertiesLength = 0;
                irp_ptr.IoStatus.Information = required_size;
                return ntstatus.STATUS_SUCCESS;
            }

            return ntstatus.STATUS_NOT_IMPLEMENTED;
        },

        SMART_RCV_DRIVE_DATA => {
            if (!dev_info.features.smart_supported) {
                return ntstatus.STATUS_NOT_SUPPORTED;
            }

            if (output_buffer_length < @sizeOf(SMART_DATA)) {
                irp_ptr.IoStatus.Information = @sizeOf(SMART_DATA);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            // 构造SMART数据，暂时返回健康状态
            const smart_data: *SMART_DATA = @ptrCast(@alignCast(output_buffer));
            smart_data.Version = 1;
            smart_data.Reserved = 0;

            // 重置所有属性
            @memset(&smart_data.Attributes, std.mem.zeroes(@TypeOf(smart_data.Attributes[0])));

            // 温度属性
            smart_data.Attributes[0].Id = 0xC2; // Temperature
            smart_data.Attributes[0].Value = 40; // 40°C
            smart_data.Attributes[0].Worst = 60; // 最高60°C
            smart_data.Attributes[0].Raw[0] = 40;

            // 健康状态属性
            smart_data.Attributes[1].Id = 0x05; // Reallocated Sectors Count
            smart_data.Attributes[1].Value = 100; // 最佳状态
            smart_data.Attributes[1].Worst = 100;
            smart_data.Attributes[1].Raw[0] = 0; // 无重定向扇区

            // 通电时间
            smart_data.Attributes[2].Id = 0x09; // Power On Hours
            smart_data.Attributes[2].Value = 100;
            smart_data.Attributes[2].Raw[0] = 100; // 100小时

            irp_ptr.IoStatus.Information = @sizeOf(SMART_DATA);
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_DISK_EJECT_MEDIA => {
            if (!dev_info.features.removable) {
                return ntstatus.STATUS_NOT_SUPPORTED;
            }

            // 模拟弹出成功
            irp_ptr.IoStatus.Information = 0;
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_STORAGE_EJECTION_CONTROL => {
            // 控制弹出功能，暂时返回成功
            irp_ptr.IoStatus.Information = 0;
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_VOLUME_GET_VOLUME_NAME => {
            if (output_buffer_length < @sizeOf(VOLUME_NAME)) {
                irp_ptr.IoStatus.Information = @sizeOf(VOLUME_NAME);
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const vol_name: *VOLUME_NAME = @ptrCast(@alignCast(output_buffer));
            // 生成卷名，格式为 "\\?\Volume{GUID}\"
            const name = "Volume{00000000-0000-0000-0000-000000000000}";
            vol_name.NameLength = @as(u32, @truncate(name.len * 2));

            // 转换为UTF-16
            var i: usize = 0;
            for (name) |c| {
                vol_name.Name[i] = c;
                i += 1;
            }
            vol_name.Name[i] = 0;

            irp_ptr.IoStatus.Information = @sizeOf(VOLUME_NAME);
            return ntstatus.STATUS_SUCCESS;
        },

        IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS => {
            const required_size = @sizeOf(VOLUME_DISK_EXTENTS) + @sizeOf(DISK_EXTENT) * 0;
            if (output_buffer_length < required_size) {
                irp_ptr.IoStatus.Information = required_size;
                return ntstatus.STATUS_BUFFER_TOO_SMALL;
            }

            const extents: *VOLUME_DISK_EXTENTS = @ptrCast(@alignCast(output_buffer));
            extents.NumberOfDiskExtents = 1;
            extents.Extents[0].DiskNumber = 0; // 暂时返回第一个磁盘
            extents.Extents[0].StartingOffset = 0;
            extents.Extents[0].ExtentLength = dev_info.total_sectors * dev_info.sector_size;

            irp_ptr.IoStatus.Information = required_size;
            return ntstatus.STATUS_SUCCESS;
        },

        else => {
            irp_ptr.IoStatus.Information = 0;
            return ntstatus.STATUS_NOT_IMPLEMENTED;
        },
    }
}

/// 存储端口管理器
pub const StoragePortManager = struct {
    allocator: std.mem.Allocator,
    ports: std.ArrayList(*StoragePort),
    lock: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) StoragePortManager {
        return StoragePortManager{
            .allocator = allocator,
            .ports = std.ArrayList(*StoragePort).init(allocator),
        };
    }

    pub fn deinit(self: *StoragePortManager) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.ports.items) |port| {
            port.deinit();
        }
        self.ports.deinit();
    }

    pub fn registerPort(self: *StoragePortManager, port: *StoragePort) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.ports.append(port);
    }

    pub fn unregisterPort(self: *StoragePortManager, port: *StoragePort) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.ports.items, 0..) |p, i| {
            if (p == port) {
                _ = self.ports.swapRemove(i);
                break;
            }
        }
    }

    pub fn getPortByIndex(self: *StoragePortManager, index: u32) ?*StoragePort {
        self.lock.lock();
        defer self.lock.unlock();

        if (index >= self.ports.items.len) return null;
        return self.ports.items[index];
    }

    pub fn processAllTimeouts(self: *StoragePortManager, current_time: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        for (self.ports.items) |port| {
            port.processTimeouts(current_time);
        }
    }
};

/// 全局存储端口管理器实例
pub var storage_port_manager: ?*StoragePortManager = null;

/// 初始化存储子系统
pub fn initializeStorageSubsystem(allocator: std.mem.Allocator) !void {
    storage_port_manager = try allocator.create(StoragePortManager);
    storage_port_manager.* = StoragePortManager.init(allocator);
}

/// 关闭存储子系统
pub fn shutdownStorageSubsystem() void {
    if (storage_port_manager) |manager| {
        manager.deinit();
        manager.allocator.destroy(manager);
        storage_port_manager = null;
    }
}
