//! Desktop gadgets (Windows 7 sidebar / floating gadgets model)
//! Exposes CPU / network meter state for compositors that draw circular glass gadgets.

const theme = @import("theme.zig");

pub const CpuMeterGadget = struct {
    center_x: i32 = 0,
    center_y: i32 = 0,
    radius: i32 = 0,
    cpu_percent: u8 = 0,
    net_kbps_str: [16]u8 = [_]u8{0} ** 16,
    net_kbps_len: u8 = 0,
    visible: bool = true,
};

var cpu_meter: CpuMeterGadget = .{};

pub fn init() void {
    const L = theme.Layout;
    cpu_meter = .{
        .center_x = L.gadget_cpu_default_x,
        .center_y = L.gadget_cpu_default_y,
        .radius = L.gadget_cpu_radius,
        .cpu_percent = 23,
        .visible = true,
    };
    cpu_meter.net_kbps_len = setStr(&cpu_meter.net_kbps_str, "0K/s");
}

fn setStr(dest: *[16]u8, src: []const u8) u8 {
    const n = @min(src.len, dest.len);
    for (0..n) |i| dest[i] = src[i];
    return @intCast(n);
}

/// Demo tick: nudges CPU readout slightly (host compositor may replace with real metrics).
pub fn tickDemo(frame: u64) void {
    const f = @as(u32, @truncate(frame % 64));
    cpu_meter.cpu_percent = @intCast(18 + (f % 14));
    const net: []const u8 = if (frame % 90 < 45) "0K/s" else "12K/s";
    cpu_meter.net_kbps_len = setStr(&cpu_meter.net_kbps_str, net);
}

pub fn getCpuMeter() *const CpuMeterGadget {
    return &cpu_meter;
}

pub fn setCpuMeterVisible(v: bool) void {
    cpu_meter.visible = v;
}

pub fn setCpuPercent(p: u8) void {
    cpu_meter.cpu_percent = @min(p, 100);
}

pub fn setNetworkLabel(text: []const u8) void {
    cpu_meter.net_kbps_len = setStr(&cpu_meter.net_kbps_str, text);
}
