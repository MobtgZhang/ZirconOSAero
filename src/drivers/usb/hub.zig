//! USB Hub：描述符布局、端口特性常量；复位/供电等控制传输由 xHCI 层发起。
//! TT（HS hub 下 FS/LS）：在 xHCI Slot Context 填 TT Hub Slot / TT Port / Think Time（见 xhci 内 `fillSlotTtFields`）。

const usb_core = @import("usb_core.zig");

pub const PORT_FEAT_CONNECTION: u8 = 0;
pub const PORT_FEAT_ENABLE: u8 = 1;
pub const PORT_FEAT_SUSPEND: u8 = 2;
pub const PORT_FEAT_OVER_CURRENT: u8 = 3;
pub const PORT_FEAT_RESET: u8 = 4;
pub const PORT_FEAT_POWER: u8 = 8;
pub const PORT_FEAT_LOWSPEED: u8 = 9;
pub const PORT_FEAT_C_CONNECTION: u16 = 16;
pub const PORT_FEAT_C_ENABLE: u16 = 17;
pub const PORT_FEAT_C_RESET: u16 = 20;

/// GET_DESCRIPTOR HUB / wValue 高字节 0x29
pub fn hubGetDescriptorSetup(wLength: u16) usb_core.SetupPacket {
    return .{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_IN,
        .bRequest = usb_core.REQ_GET_DESCRIPTOR,
        .wValue = (@as(u16, usb_core.DESC_HUB) << 8),
        .wIndex = 0,
        .wLength = wLength,
    };
}

pub fn clearPortFeatureSetup(port: u8, feature: u8) usb_core.SetupPacket {
    return .{
        .bmRequestType = usb_core.REQ_TYPE_CLASS_OUT,
        .bRequest = usb_core.REQ_CLEAR_FEATURE,
        .wValue = feature,
        .wIndex = @as(u16, port),
        .wLength = 0,
    };
}

pub fn setPortFeatureSetup(port: u8, feature: u8) usb_core.SetupPacket {
    return .{
        .bmRequestType = usb_core.REQ_TYPE_CLASS_OUT,
        .bRequest = usb_core.REQ_SET_FEATURE,
        .wValue = feature,
        .wIndex = @as(u16, port),
        .wLength = 0,
    };
}

pub fn getPortStatusSetup(port: u8) usb_core.SetupPacket {
    return .{
        .bmRequestType = usb_core.REQ_TYPE_CLASS_IN,
        .bRequest = usb_core.REQ_GET_STATUS,
        .wValue = 0,
        .wIndex = @as(u16, port),
        .wLength = 4,
    };
}
