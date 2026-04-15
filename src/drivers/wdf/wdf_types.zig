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
//! WDF句柄类型定义
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const nt = @import("../../nt61.zig");

/// WDF句柄类型定义
pub const WDFDRIVER = *opaque {};
pub const WDFDEVICE = *opaque {};
pub const WDFQUEUE = *opaque {};
pub const WDFREQUEST = *opaque {};
pub const WDFMEMORY = *opaque {};
pub const WDFINTERRUPT = *opaque {};
pub const WDFDMATRANSACTION = *opaque {};
pub const WDFDMAENABLER = *opaque {};
pub const WDFTIMER = *opaque {};
pub const WDFWORKITEM = *opaque {};
pub const WDFSTRING = *opaque {};
pub const WDFKEY = *opaque {};
pub const WDFIOTARGET = *opaque {};

/// WDF状态码定义
pub const WDF_STATUS = nt.NTSTATUS;

/// WDF I/O队列类型
pub const WDF_IO_QUEUE_TYPE = enum(u32) {
    invalid = 0,
    sequential = 1,
    parallel = 2,
    manual = 3,
};

/// WDF I/O队列调度方式
pub const WDF_IO_QUEUE_DISPATCH_TYPE = enum(u32) {
    invalid = 0,
    sequential = 1,
    parallel = 2,
    manual = 3,
};

/// WDF电源状态
pub const WDF_POWER_DEVICE_STATE = enum(u32) {
    invalid = 0,
    D0 = 1,
    D1 = 2,
    D2 = 3,
    D3 = 4,
    maximum = 5,
};

/// WDF设备状态
pub const WDF_DEVICE_STATE = enum(u32) {
    invalid = 0,
    not_present = 1,
    present = 2,
    stopped = 3,
    working = 4,
    removed = 5,
    surprise_removed = 6,
    failed = 7,
};

/// WDF PnP事件类型
pub const WDF_PNP_EVENT = enum(u32) {
    invalid = 0,
    add_device = 1,
    start_device = 2,
    stop_device = 3,
    remove_device = 4,
    surprise_remove = 5,
    query_remove = 6,
    cancel_remove = 7,
    query_stop = 8,
    cancel_stop = 9,
    query_capabilities = 10,
    query_resource_requirements = 11,
    filter_resource_requirements = 12,
    start_device_complete = 13,
    stop_device_complete = 14,
    remove_device_complete = 15,
    surprise_remove_complete = 16,
};

/// WDF电源事件类型
pub const WDF_POWER_EVENT = enum(u32) {
    invalid = 0,
    D0Entry = 1,
    D0Exit = 2,
    DeviceSleep = 3,
    DeviceWake = 4,
    SystemSleep = 5,
    SystemWake = 6,
    PowerPolicyQueryRemove = 7,
    PowerPolicyRemove = 8,
};

/// WDF I/O请求类型
pub const WDF_REQUEST_TYPE = enum(u32) {
    invalid = 0,
    create = 1,
    read = 2,
    write = 3,
    device_io_control = 4,
    cleanup = 5,
    close = 6,
    internal_device_io_control = 7,
    shutdown = 8,
    flush_buffers = 9,
    query_information = 10,
    set_information = 11,
    query_volume_information = 12,
    set_volume_information = 13,
    directory_control = 14,
    file_system_control = 15,
    lock_control = 16,
    query_ea = 17,
    set_ea = 18,
    query_security = 19,
    set_security = 20,
    power = 21,
    system_control = 22,
    device_change = 23,
    query_quota = 24,
    set_quota = 25,
    pnp = 26,
    maximum = 27,
};

/// WDF I/O完成状态
pub const WDF_REQUEST_COMPLETION_STATUS = enum(u32) {
    success = 0,
    canceled = 1,
    invalid_parameter = 2,
    no_memory = 3,
    io_error = 4,
    timeout = 5,
    not_supported = 6,
};

/// WDF内存标志
pub const WDF_MEMORY_FLAGS = packed struct(u32) {
    non_paged: bool = false,
    paged: bool = false,
    cached: bool = true,
    write_combined: bool = false,
    dma_buffer: bool = false,
    _reserved: u27 = 0,
};
