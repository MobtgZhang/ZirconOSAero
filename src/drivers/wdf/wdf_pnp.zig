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
//! WDF PnP/电源管理实现
//! 基于微软公开WDF技术文档，符合Clean Room开发规范

const std = @import("std");
const nt = @import("../../nt61.zig");
const io = @import("../../io/io.zig");
const wdf = @import("wdf_types.zig");
const wdf_device = @import("wdf_device.zig");

/// PnP和电源管理回调函数表
pub const WDF_PNP_POWER_CALLBACKS = extern struct {
    Size: u16 = @sizeOf(WDF_PNP_POWER_CALLBACKS),
    EvtDeviceAdd: ?fn (driver: wdf.WDFDRIVER, device_init: *anyopaque) callconv(.C) wdf.WDF_STATUS,
    EvtDevicePrepareHardware: ?fn (device: wdf.WDFDEVICE, resources: *nt.CM_RESOURCE_LIST, resources_translated: *nt.CM_RESOURCE_LIST) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceReleaseHardware: ?fn (device: wdf.WDFDEVICE, resources: *nt.CM_RESOURCE_LIST) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceD0Entry: ?fn (device: wdf.WDFDEVICE, previous_state: wdf.WDF_POWER_DEVICE_STATE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceD0Exit: ?fn (device: wdf.WDFDEVICE, target_state: wdf.WDF_POWER_DEVICE_STATE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceSelfManagedIoInit: ?fn (device: wdf.WDFDEVICE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceSelfManagedIoCleanup: ?fn (device: wdf.WDFDEVICE) callconv(.C) void,
    EvtDeviceSelfManagedIoSuspend: ?fn (device: wdf.WDFDEVICE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceSelfManagedIoRestart: ?fn (device: wdf.WDFDEVICE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceQueryRemove: ?fn (device: wdf.WDFDEVICE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceQueryStop: ?fn (device: wdf.WDFDEVICE) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceSurpriseRemoval: ?fn (device: wdf.WDFDEVICE) callconv(.C) void,
    EvtDeviceQueryCapabilities: ?fn (device: wdf.WDFDEVICE, capabilities: *nt.DEVICE_CAPABILITIES) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceQueryResources: ?fn (device: wdf.WDFDEVICE, resources: **nt.CM_RESOURCE_LIST) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceQueryResourceRequirements: ?fn (device: wdf.WDFDEVICE, requirements: **nt.IO_RESOURCE_REQUIREMENTS_LIST) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceFilterResourceRequirements: ?fn (device: wdf.WDFDEVICE, requirements: *nt.IO_RESOURCE_REQUIREMENTS_LIST) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceUsageNotification: ?fn (device: wdf.WDFDEVICE, usage_type: nt.DEVICE_USAGE_NOTIFICATION_TYPE, in_path: bool) callconv(.C) wdf.WDF_STATUS,
    EvtDeviceRelationsQuery: ?fn (device: wdf.WDFDEVICE, relation_type: nt.DEVICE_RELATION_TYPE, relations: **nt.DEVICE_RELATIONS) callconv(.C) wdf.WDF_STATUS,
};

/// 电源策略设置
pub const WDF_POWER_POLICY_SETTINGS = extern struct {
    Size: u16 = @sizeOf(WDF_POWER_POLICY_SETTINGS),
    UserControlOfD0Idle: nt.NTSTATUS,
    IdleTimeout: u32,
    IdleUsbSuspend: bool,
    S0IdleWakeEnabled: bool,
    SxWakeEnabled: bool,
    WakeFromD0Enabled: bool,
    WakeFromDxEnabled: bool,
    MinimumDeviceSleepState: wdf.WDF_POWER_DEVICE_STATE,
    ArmWakeOnSx: bool,
    WakeTimer: bool,
    WakeTimerPeriod: u32,
};

/// 初始化PnP回调
pub fn WdfPnpPowerCallbacksInit(callbacks: *WDF_PNP_POWER_CALLBACKS, evt_device_add: ?fn (driver: wdf.WDFDRIVER, device_init: *anyopaque) callconv(.C) wdf.WDF_STATUS) void {
    callbacks.* = .{
        .EvtDeviceAdd = evt_device_add,
    };
}

/// 设置设备PnP回调
pub fn WdfDeviceSetPnpPowerCallbacks(device: wdf.WDFDEVICE, callbacks: *const WDF_PNP_POWER_CALLBACKS) void {
    const wdf_dev = wdf_device.fromHandle(device);
    wdf_dev.pnp_callbacks = callbacks.*;
}

/// 初始化电源策略设置
pub fn WdfDeviceInitSetPowerPolicySettings(device_init: *anyopaque, settings: *const WDF_POWER_POLICY_SETTINGS) void {
    _ = device_init;
    _ = settings;
    // TODO: 实现电源策略设置存储
}

/// 处理PnP IRP请求
pub fn WdfDispatchPnp(device: wdf.WDFDEVICE, irp: *io.IRP) nt.NTSTATUS {
    const wdf_dev = wdf_device.fromHandle(device);
    const io_stack = io.IoGetCurrentIrpStackLocation(irp);
    const minor_func = io_stack.Parameters.MinorFunction;

    switch (minor_func) {
        io.IRP_MN_START_DEVICE => {
            return handleStartDevice(wdf_dev, irp);
        },
        io.IRP_MN_STOP_DEVICE => {
            return handleStopDevice(wdf_dev, irp);
        },
        io.IRP_MN_REMOVE_DEVICE => {
            return handleRemoveDevice(wdf_dev, irp);
        },
        io.IRP_MN_SURPRISE_REMOVAL => {
            return handleSurpriseRemoval(wdf_dev, irp);
        },
        io.IRP_MN_QUERY_REMOVE_DEVICE => {
            return handleQueryRemove(wdf_dev, irp);
        },
        io.IRP_MN_CANCEL_REMOVE_DEVICE => {
            return handleCancelRemove(wdf_dev, irp);
        },
        io.IRP_MN_QUERY_STOP_DEVICE => {
            return handleQueryStop(wdf_dev, irp);
        },
        io.IRP_MN_CANCEL_STOP_DEVICE => {
            return handleCancelStop(wdf_dev, irp);
        },
        io.IRP_MN_QUERY_CAPABILITIES => {
            return handleQueryCapabilities(wdf_dev, irp);
        },
        io.IRP_MN_QUERY_RESOURCE_REQUIREMENTS => {
            return handleQueryResourceRequirements(wdf_dev, irp);
        },
        io.IRP_MN_FILTER_RESOURCE_REQUIREMENTS => {
            return handleFilterResourceRequirements(wdf_dev, irp);
        },
        else => {
            // 将未处理的IRP传递给下一层驱动
            return io.IoSkipCurrentIrpStackLocation(irp);
        },
    }
}

/// 处理电源IRP请求
pub fn WdfDispatchPower(device: wdf.WDFDEVICE, irp: *io.IRP) nt.NTSTATUS {
    const wdf_dev = wdf_device.fromHandle(device);
    const io_stack = io.IoGetCurrentIrpStackLocation(irp);
    const minor_func = io_stack.Parameters.MinorFunction;

    switch (minor_func) {
        io.IRP_MN_SET_POWER => {
            const power_type = io_stack.Parameters.Power.Type;
            const power_state = io_stack.Parameters.Power.State;

            if (power_type == io.PowerDevice) {
                return handleSetDevicePower(wdf_dev, irp, power_state.DeviceState);
            } else if (power_type == io.PowerSystem) {
                return handleSetSystemPower(wdf_dev, irp, power_state.SystemState);
            }
        },
        io.IRP_MN_QUERY_POWER => {
            return handleQueryPower(wdf_dev, irp);
        },
        io.IRP_MN_WAIT_WAKE => {
            return handleWaitWake(wdf_dev, irp);
        },
        io.IRP_MN_POWER_SEQUENCE => {
            return handlePowerSequence(wdf_dev, irp);
        },
        else => {
            // 将未处理的IRP传递给下一层驱动
            return io.IoSkipCurrentIrpStackLocation(irp);
        },
    }

    irp.IoStatus.Status = nt.STATUS_NOT_SUPPORTED;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_NOT_SUPPORTED;
}

fn handleStartDevice(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    // 调用驱动的PrepareHardware回调
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;
    if (wdf_dev.pnp_callbacks.EvtDevicePrepareHardware) |prepare_hw| {
        const resources = irp.Parameters.StartDevice.AllocatedResources;
        const resources_translated = irp.Parameters.StartDevice.AllocatedResourcesTranslated;
        const wdf_status = prepare_hw(wdf_dev.toHandle(), resources, resources_translated);
        status = wdf_status;
    }

    if (nt.NT_SUCCESS(status)) {
        // 调用D0Entry回调
        if (wdf_dev.pnp_callbacks.EvtDeviceD0Entry) |d0_entry| {
            const wdf_status = d0_entry(wdf_dev.toHandle(), .D3);
            status = wdf_status;
        }
    }

    if (nt.NT_SUCCESS(status)) {
        // 启动自管理IO
        if (wdf_dev.pnp_callbacks.EvtDeviceSelfManagedIoInit) |self_managed_init| {
            const wdf_status = self_managed_init(wdf_dev.toHandle());
            status = wdf_status;
        }
    }

    wdf_dev.device_state = .working;
    wdf_dev.power_state = .D0;

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleStopDevice(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    // 暂停自管理IO
    if (wdf_dev.pnp_callbacks.EvtDeviceSelfManagedIoSuspend) |self_managed_suspend| {
        _ = self_managed_suspend(wdf_dev.toHandle());
    }

    // 调用D0Exit回调
    if (wdf_dev.pnp_callbacks.EvtDeviceD0Exit) |d0_exit| {
        _ = d0_exit(wdf_dev.toHandle(), .D3);
    }

    // 调用ReleaseHardware回调
    if (wdf_dev.pnp_callbacks.EvtDeviceReleaseHardware) |release_hw| {
        _ = release_hw(wdf_dev.toHandle(), null);
    }

    wdf_dev.device_state = .stopped;
    wdf_dev.power_state = .D3;

    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleRemoveDevice(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    // 清理自管理IO
    if (wdf_dev.pnp_callbacks.EvtDeviceSelfManagedIoCleanup) |self_managed_cleanup| {
        self_managed_cleanup(wdf_dev.toHandle());
    }

    // 如果设备仍在工作状态，先停止
    if (wdf_dev.power_state == .D0) {
        if (wdf_dev.pnp_callbacks.EvtDeviceD0Exit) |d0_exit| {
            _ = d0_exit(wdf_dev.toHandle(), .D3);
        }
    }

    // 释放硬件资源
    if (wdf_dev.pnp_callbacks.EvtDeviceReleaseHardware) |release_hw| {
        _ = release_hw(wdf_dev.toHandle(), null);
    }

    wdf_dev.device_state = .removed;
    wdf_dev.power_state = .D3;

    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleSurpriseRemoval(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    // 调用SurpriseRemoval回调
    if (wdf_dev.pnp_callbacks.EvtDeviceSurpriseRemoval) |surprise_removal| {
        surprise_removal(wdf_dev.toHandle());
    }

    wdf_dev.device_state = .surprise_removed;

    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleQueryRemove(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;

    if (wdf_dev.pnp_callbacks.EvtDeviceQueryRemove) |query_remove| {
        const wdf_status = query_remove(wdf_dev.toHandle());
        status = wdf_status;
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleCancelRemove(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    _ = wdf_dev;

    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleQueryStop(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;

    if (wdf_dev.pnp_callbacks.EvtDeviceQueryStop) |query_stop| {
        const wdf_status = query_stop(wdf_dev.toHandle());
        status = wdf_status;
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleCancelStop(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    _ = wdf_dev;

    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleQueryCapabilities(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;
    const capabilities = irp.Parameters.DeviceCapabilities.Capabilities;

    if (wdf_dev.pnp_callbacks.EvtDeviceQueryCapabilities) |query_caps| {
        const wdf_status = query_caps(wdf_dev.toHandle(), capabilities);
        status = wdf_status;
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleQueryResourceRequirements(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;
    var requirements: *nt.IO_RESOURCE_REQUIREMENTS_LIST = undefined;

    if (wdf_dev.pnp_callbacks.EvtDeviceQueryResourceRequirements) |query_requirements| {
        const wdf_status = query_requirements(wdf_dev.toHandle(), &requirements);
        status = wdf_status;
    } else {
        // 如果没有回调，直接转发到下层驱动
        return io.IoSkipCurrentIrpStackLocation(irp);
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = @intFromPtr(requirements);
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleFilterResourceRequirements(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;
    const requirements = irp.Parameters.FilterResourceRequirements.IOResourceRequirements;

    if (wdf_dev.pnp_callbacks.EvtDeviceFilterResourceRequirements) |filter_requirements| {
        const wdf_status = filter_requirements(wdf_dev.toHandle(), requirements);
        status = wdf_status;
    } else {
        // 如果没有回调，直接转发到下层驱动
        return io.IoSkipCurrentIrpStackLocation(irp);
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleSetDevicePower(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP, target_state: wdf.WDF_POWER_DEVICE_STATE) nt.NTSTATUS {
    var status: nt.NTSTATUS = nt.STATUS_SUCCESS;

    if (target_state == .D0) {
        // 进入D0状态
        if (wdf_dev.pnp_callbacks.EvtDeviceD0Entry) |d0_entry| {
            const wdf_status = d0_entry(wdf_dev.toHandle(), wdf_dev.power_state);
            status = wdf_status;
        }

        if (nt.NT_SUCCESS(status)) {
            wdf_dev.power_state = .D0;

            // 重启自管理IO
            if (wdf_dev.pnp_callbacks.EvtDeviceSelfManagedIoRestart) |self_managed_restart| {
                const wdf_status = self_managed_restart(wdf_dev.toHandle());
                status = wdf_status;
            }
        }
    } else {
        // 退出D0状态
        if (wdf_dev.power_state == .D0) {
            // 暂停自管理IO
            if (wdf_dev.pnp_callbacks.EvtDeviceSelfManagedIoSuspend) |self_managed_suspend| {
                const wdf_status = self_managed_suspend(wdf_dev.toHandle());
                status = wdf_status;
            }

            if (nt.NT_SUCCESS(status)) {
                if (wdf_dev.pnp_callbacks.EvtDeviceD0Exit) |d0_exit| {
                    const wdf_status = d0_exit(wdf_dev.toHandle(), target_state);
                    status = wdf_status;
                }

                if (nt.NT_SUCCESS(status)) {
                    wdf_dev.power_state = target_state;
                }
            }
        }
    }

    irp.IoStatus.Status = status;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return status;
}

fn handleSetSystemPower(_: *wdf_device.WdfDevice, irp: *io.IRP, _: nt.SYSTEM_POWER_STATE) nt.NTSTATUS {
    // 系统电源状态改变，直接转发到下层驱动
    return io.IoSkipCurrentIrpStackLocation(irp);
}

fn handleQueryPower(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    _ = wdf_dev;
    // 查询电源状态，默认允许
    irp.IoStatus.Status = nt.STATUS_SUCCESS;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_SUCCESS;
}

fn handleWaitWake(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    _ = wdf_dev;
    // 等待唤醒事件，默认不支持
    irp.IoStatus.Status = nt.STATUS_NOT_SUPPORTED;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_NOT_SUPPORTED;
}

fn handlePowerSequence(wdf_dev: *wdf_device.WdfDevice, irp: *io.IRP) nt.NTSTATUS {
    _ = wdf_dev;
    // 电源序列请求，默认不支持
    irp.IoStatus.Status = nt.STATUS_NOT_SUPPORTED;
    irp.IoStatus.Information = 0;
    io.IoCompleteRequest(irp, io.IO_NO_INCREMENT);
    return nt.STATUS_NOT_SUPPORTED;
}
