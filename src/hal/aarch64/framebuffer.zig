//! GOP / 线性帧缓冲占位（与 LoongArch 路径一致，供 display / kernel 初始化）

var fb_addr: usize = 0;
var fb_pitch: usize = 0;
var fb_width: usize = 0;
var fb_height: usize = 0;
var fb_bpp: usize = 0;
var ready: bool = false;
var console_enabled: bool = true;

pub fn setConsoleEnabled(e: bool) void {
    console_enabled = e;
}

pub fn isConsoleEnabled() bool {
    return console_enabled;
}

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    fb_addr = addr;
    fb_width = width;
    fb_height = height;
    fb_pitch = pitch;
    fb_bpp = bpp;
    ready = true;
}

pub fn isReady() bool {
    return ready;
}

pub fn clear() void {
    if (!ready or !console_enabled) return;
    const total_bytes = fb_pitch * fb_height;
    const ptr: [*]volatile u8 = @ptrFromInt(fb_addr);
    var i: usize = 0;
    while (i < total_bytes) : (i += 1) {
        ptr[i] = 0;
    }
}

pub fn write(_: []const u8) void {}
