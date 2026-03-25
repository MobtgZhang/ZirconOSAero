//! USB Chapter 9：请求、描述符布局与解析（小端）。

pub const REQ_GET_STATUS: u8 = 0;
pub const REQ_CLEAR_FEATURE: u8 = 1;
pub const REQ_SET_FEATURE: u8 = 3;
pub const REQ_SET_ADDRESS: u8 = 5;
pub const REQ_GET_DESCRIPTOR: u8 = 6;
pub const REQ_SET_DESCRIPTOR: u8 = 7;
pub const REQ_GET_CONFIGURATION: u8 = 8;
pub const REQ_SET_CONFIGURATION: u8 = 9;
pub const REQ_SET_INTERFACE: u8 = 11;

pub const DESC_DEVICE: u8 = 1;
pub const DESC_CONFIG: u8 = 2;
pub const DESC_STRING: u8 = 3;
pub const DESC_INTERFACE: u8 = 4;
pub const DESC_ENDPOINT: u8 = 5;
pub const DESC_HID: u8 = 0x21;
pub const DESC_HUB: u8 = 0x29;

pub const FEAT_DEVICE_REMOTE_WAKEUP: u16 = 1;
pub const FEAT_ENDPOINT_HALT: u16 = 0;
pub const FEAT_PORT_POWER: u8 = 8;
pub const FEAT_PORT_RESET: u8 = 4;
pub const FEAT_PORT_ENABLE: u8 = 1;
pub const FEAT_PORT_CONNECTION: u8 = 0;

pub const REQ_TYPE_DEVICE_OUT: u8 = 0x00;
pub const REQ_TYPE_DEVICE_IN: u8 = 0x80;
pub const REQ_TYPE_CLASS_OUT: u8 = 0x20;
pub const REQ_TYPE_CLASS_IN: u8 = 0xA0;
pub const REQ_TYPE_STANDARD_OUT: u8 = 0x00;
pub const REQ_TYPE_STANDARD_IN: u8 = 0x80;

pub const HID_REQ_SET_PROTOCOL: u8 = 0x0B;
pub const HID_PROTOCOL_BOOT: u16 = 0;
pub const HID_PROTOCOL_REPORT: u16 = 1;

pub const SetupPacket = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

pub const DeviceDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16,
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize0: u8,
    idVendor: u16,
    idProduct: u16,
    bcdDevice: u16,
    iManufacturer: u8,
    iProduct: u8,
    iSerialNumber: u8,
    bNumConfigurations: u8,
};

pub const ConfigDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16,
    bNumInterfaces: u8,
    bConfigurationValue: u8,
    iConfiguration: u8,
    bmAttributes: u8,
    bMaxPower: u8,
};

pub const InterfaceDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,
};

pub const EndpointDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8,
    bmAttributes: u8,
    wMaxPacketSize: u16,
    bInterval: u8,
};

/// Hub 类描述符（USB 2.0 hub）
pub const HubDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bNbrPorts: u8,
    wHubCharacteristics: u16,
    bPwrOn2PwrGood: u8,
    bHubContrCurrent: u8,
    /// 可变长 DeviceRemovable + PortPwrCtrlMask；最小解析用前 9 字节
    _pad0: u8 = 0,
    _pad1: u8 = 0,
};

pub fn readU16Le(buf: []const u8, off: usize) u16 {
    if (off + 2 > buf.len) return 0;
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

/// 在配置描述符 blob 中查找首个 HID 引导接口及其中断 IN 端点。
/// 返回：interface 偏移、endpoint 偏移；未找到返回 null。
pub fn findBootHidInterruptIn(cfg: []const u8) ?struct { iface_off: usize, ep_off: usize } {
    var i: usize = 0;
    while (i + 2 <= cfg.len) {
        const len = cfg[i];
        const typ = cfg[i + 1];
        if (len < 2 or i + len > cfg.len) break;
        if (typ == DESC_INTERFACE and len >= @sizeOf(InterfaceDescriptor)) {
            const ifc: *align(1) const InterfaceDescriptor = @ptrCast(cfg[i..][0..@sizeOf(InterfaceDescriptor)]);
            if (ifc.bInterfaceClass == 0x03 and ifc.bInterfaceSubClass == 0x01) {
                var j = i + len;
                while (j + 2 <= cfg.len) {
                    const el = cfg[j];
                    const et = cfg[j + 1];
                    if (el < 2 or j + el > cfg.len) break;
                    if (et == DESC_ENDPOINT and el >= @sizeOf(EndpointDescriptor)) {
                        const ep: *align(1) const EndpointDescriptor = @ptrCast(cfg[j..][0..@sizeOf(EndpointDescriptor)]);
                        const addr = ep.bEndpointAddress;
                        const in = (addr & 0x80) != 0;
                        const xfer = ep.bmAttributes & 0x03;
                        if (in and xfer == 0x03) {
                            return .{ .iface_off = i, .ep_off = j };
                        }
                    }
                    j += el;
                }
            }
        }
        i += len;
    }
    return null;
}

/// 查找首个 HUB 类接口（bInterfaceClass == 9）
pub fn findHubInterface(cfg: []const u8) ?usize {
    var i: usize = 0;
    while (i + 2 <= cfg.len) {
        const len = cfg[i];
        const typ = cfg[i + 1];
        if (len < 2 or i + len > cfg.len) break;
        if (typ == DESC_INTERFACE and len >= @sizeOf(InterfaceDescriptor)) {
            const ifc: *align(1) const InterfaceDescriptor = @ptrCast(cfg[i..][0..@sizeOf(InterfaceDescriptor)]);
            if (ifc.bInterfaceClass == 0x09) return i;
        }
        i += len;
    }
    return null;
}
