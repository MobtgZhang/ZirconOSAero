//! VGA Display Driver (NT-style Miniport)
//! Manages VGA hardware for text and graphics modes.
//! Reference: ReactOS drivers/video/miniport/vga/
//!
//! Provides mode setting, text output, and basic graphics primitives
//! for VGA-compatible hardware. Registers with the I/O Manager as
//! a DeviceObject of type .framebuffer.

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 { return 0; }
        pub fn ioWait() void {}
    };

// ── VGA Register Ports ──

const VGA_MISC_READ: u16 = 0x3CC;
const VGA_MISC_WRITE: u16 = 0x3C2;
const VGA_SEQ_INDEX: u16 = 0x3C4;
const VGA_SEQ_DATA: u16 = 0x3C5;
const VGA_CRTC_INDEX: u16 = 0x3D4;
const VGA_CRTC_DATA: u16 = 0x3D5;
const VGA_GC_INDEX: u16 = 0x3CE;
const VGA_GC_DATA: u16 = 0x3CF;
const VGA_AC_INDEX: u16 = 0x3C0;
const VGA_AC_READ: u16 = 0x3C1;
const VGA_AC_WRITE: u16 = 0x3C0;
const VGA_DAC_READ_INDEX: u16 = 0x3C7;
const VGA_DAC_WRITE_INDEX: u16 = 0x3C8;
const VGA_DAC_DATA: u16 = 0x3C9;
const VGA_STATUS_1: u16 = 0x3DA;

const VGA_TEXT_BUFFER: usize = 0xB8000;
const VGA_GFX_BUFFER: usize = 0xA0000;

// ── Video Mode Definitions ──

pub const VideoMode = enum(u8) {
    text_80x25 = 0x03,
    gfx_320x200_256 = 0x13,
    gfx_640x480_16 = 0x12,
    gfx_640x480_256 = 0x80, // VBE mode (placeholder)
    gfx_800x600_256 = 0x81,
    gfx_1024x768_256 = 0x82,
};

pub const ModeInfo = struct {
    mode: VideoMode,
    width: u32,
    height: u32,
    bpp: u8,
    pitch: u32,
    framebuffer: usize,
    text_mode: bool,
};

const supported_modes = [_]ModeInfo{
    .{ .mode = .text_80x25, .width = 80, .height = 25, .bpp = 4, .pitch = 160, .framebuffer = VGA_TEXT_BUFFER, .text_mode = true },
    .{ .mode = .gfx_320x200_256, .width = 320, .height = 200, .bpp = 8, .pitch = 320, .framebuffer = VGA_GFX_BUFFER, .text_mode = false },
    .{ .mode = .gfx_640x480_16, .width = 640, .height = 480, .bpp = 4, .pitch = 80, .framebuffer = VGA_GFX_BUFFER, .text_mode = false },
};

// ── Driver State ──

var current_mode: VideoMode = .text_80x25;
var current_width: u32 = 80;
var current_height: u32 = 25;
var current_bpp: u8 = 4;
var current_pitch: u32 = 160;
var current_fb: usize = VGA_TEXT_BUFFER;
var is_text_mode: bool = true;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

// ── IOCTL Codes (NT-style) ──

pub const IOCTL_VIDEO_QUERY_NUM_MODES: u32 = 0x00070000;
pub const IOCTL_VIDEO_QUERY_CURRENT_MODE: u32 = 0x00070004;
pub const IOCTL_VIDEO_SET_MODE: u32 = 0x00070008;
pub const IOCTL_VIDEO_RESET: u32 = 0x0007000C;
pub const IOCTL_VIDEO_MAP_FRAMEBUFFER: u32 = 0x00070010;
pub const IOCTL_VIDEO_UNMAP_FRAMEBUFFER: u32 = 0x00070014;
pub const IOCTL_VIDEO_SET_PALETTE: u32 = 0x00070018;
pub const IOCTL_VIDEO_QUERY_PALETTE: u32 = 0x0007001C;
pub const IOCTL_VIDEO_SET_CURSOR_POS: u32 = 0x00070020;
pub const IOCTL_VIDEO_ENABLE_CURSOR: u32 = 0x00070024;

// ── VGA Register Programming ──

fn vgaWriteSeq(index: u8, data: u8) void {
    portio.outb(VGA_SEQ_INDEX, index);
    portio.outb(VGA_SEQ_DATA, data);
}

fn vgaReadSeq(index: u8) u8 {
    portio.outb(VGA_SEQ_INDEX, index);
    return portio.inb(VGA_SEQ_DATA);
}

fn vgaWriteCrtc(index: u8, data: u8) void {
    portio.outb(VGA_CRTC_INDEX, index);
    portio.outb(VGA_CRTC_DATA, data);
}

fn vgaReadCrtc(index: u8) u8 {
    portio.outb(VGA_CRTC_INDEX, index);
    return portio.inb(VGA_CRTC_DATA);
}

fn vgaWriteGc(index: u8, data: u8) void {
    portio.outb(VGA_GC_INDEX, index);
    portio.outb(VGA_GC_DATA, data);
}

fn vgaWriteAc(index: u8, data: u8) void {
    _ = portio.inb(VGA_STATUS_1);
    portio.outb(VGA_AC_INDEX, index);
    portio.outb(VGA_AC_WRITE, data);
}

fn vgaEnablePalette() void {
    _ = portio.inb(VGA_STATUS_1);
    portio.outb(VGA_AC_INDEX, 0x20);
}

// ── Mode Setting ──

pub fn setTextMode() void {
    portio.outb(VGA_MISC_WRITE, 0x67);

    vgaWriteSeq(0x00, 0x03);
    vgaWriteSeq(0x01, 0x00);
    vgaWriteSeq(0x02, 0x03);
    vgaWriteSeq(0x03, 0x00);
    vgaWriteSeq(0x04, 0x02);

    vgaWriteCrtc(0x11, vgaReadCrtc(0x11) & 0x7F);

    vgaWriteCrtc(0x00, 0x5F);
    vgaWriteCrtc(0x01, 0x4F);
    vgaWriteCrtc(0x02, 0x50);
    vgaWriteCrtc(0x03, 0x82);
    vgaWriteCrtc(0x04, 0x55);
    vgaWriteCrtc(0x05, 0x81);
    vgaWriteCrtc(0x06, 0xBF);
    vgaWriteCrtc(0x07, 0x1F);
    vgaWriteCrtc(0x08, 0x00);
    vgaWriteCrtc(0x09, 0x4F);
    vgaWriteCrtc(0x0A, 0x0D);
    vgaWriteCrtc(0x0B, 0x0E);
    vgaWriteCrtc(0x10, 0x9C);
    vgaWriteCrtc(0x11, 0x8E);
    vgaWriteCrtc(0x12, 0x8F);
    vgaWriteCrtc(0x13, 0x28);
    vgaWriteCrtc(0x14, 0x1F);
    vgaWriteCrtc(0x15, 0x96);
    vgaWriteCrtc(0x16, 0xB9);
    vgaWriteCrtc(0x17, 0xA3);

    vgaWriteGc(0x00, 0x00);
    vgaWriteGc(0x01, 0x00);
    vgaWriteGc(0x02, 0x00);
    vgaWriteGc(0x03, 0x00);
    vgaWriteGc(0x04, 0x00);
    vgaWriteGc(0x05, 0x10);
    vgaWriteGc(0x06, 0x0E);
    vgaWriteGc(0x07, 0x00);
    vgaWriteGc(0x08, 0xFF);

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        vgaWriteAc(i, i);
    }
    vgaWriteAc(0x10, 0x0C);
    vgaWriteAc(0x11, 0x00);
    vgaWriteAc(0x12, 0x0F);
    vgaWriteAc(0x13, 0x08);
    vgaWriteAc(0x14, 0x00);
    vgaEnablePalette();

    current_mode = .text_80x25;
    current_width = 80;
    current_height = 25;
    current_bpp = 4;
    current_pitch = 160;
    current_fb = VGA_TEXT_BUFFER;
    is_text_mode = true;
}

pub fn setMode13h() void {
    portio.outb(VGA_MISC_WRITE, 0x63);

    vgaWriteSeq(0x00, 0x03);
    vgaWriteSeq(0x01, 0x01);
    vgaWriteSeq(0x02, 0x0F);
    vgaWriteSeq(0x03, 0x00);
    vgaWriteSeq(0x04, 0x0E);

    vgaWriteCrtc(0x11, vgaReadCrtc(0x11) & 0x7F);

    vgaWriteCrtc(0x00, 0x5F);
    vgaWriteCrtc(0x01, 0x4F);
    vgaWriteCrtc(0x02, 0x50);
    vgaWriteCrtc(0x03, 0x82);
    vgaWriteCrtc(0x04, 0x54);
    vgaWriteCrtc(0x05, 0x80);
    vgaWriteCrtc(0x06, 0xBF);
    vgaWriteCrtc(0x07, 0x1F);
    vgaWriteCrtc(0x08, 0x00);
    vgaWriteCrtc(0x09, 0x41);
    vgaWriteCrtc(0x10, 0x9C);
    vgaWriteCrtc(0x11, 0x8E);
    vgaWriteCrtc(0x12, 0x8F);
    vgaWriteCrtc(0x13, 0x28);
    vgaWriteCrtc(0x14, 0x40);
    vgaWriteCrtc(0x15, 0x96);
    vgaWriteCrtc(0x16, 0xB9);
    vgaWriteCrtc(0x17, 0xA3);

    vgaWriteGc(0x00, 0x00);
    vgaWriteGc(0x01, 0x00);
    vgaWriteGc(0x02, 0x00);
    vgaWriteGc(0x03, 0x00);
    vgaWriteGc(0x04, 0x00);
    vgaWriteGc(0x05, 0x40);
    vgaWriteGc(0x06, 0x05);
    vgaWriteGc(0x07, 0x0F);
    vgaWriteGc(0x08, 0xFF);

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        vgaWriteAc(i, i);
    }
    vgaWriteAc(0x10, 0x41);
    vgaWriteAc(0x11, 0x00);
    vgaWriteAc(0x12, 0x0F);
    vgaWriteAc(0x13, 0x00);
    vgaWriteAc(0x14, 0x00);
    vgaEnablePalette();

    current_mode = .gfx_320x200_256;
    current_width = 320;
    current_height = 200;
    current_bpp = 8;
    current_pitch = 320;
    current_fb = VGA_GFX_BUFFER;
    is_text_mode = false;
}

// ── Palette Control ──

pub fn setPaletteEntry(index: u8, r: u8, g: u8, b: u8) void {
    portio.outb(VGA_DAC_WRITE_INDEX, index);
    portio.outb(VGA_DAC_DATA, r >> 2);
    portio.outb(VGA_DAC_DATA, g >> 2);
    portio.outb(VGA_DAC_DATA, b >> 2);
}

pub fn getPaletteEntry(index: u8) struct { r: u8, g: u8, b: u8 } {
    portio.outb(VGA_DAC_READ_INDEX, index);
    const r = portio.inb(VGA_DAC_DATA);
    const g = portio.inb(VGA_DAC_DATA);
    const b = portio.inb(VGA_DAC_DATA);
    return .{ .r = r << 2, .g = g << 2, .b = b << 2 };
}

pub fn setDefaultPalette() void {
    const default_pal = [16][3]u8{
        .{ 0x00, 0x00, 0x00 }, // black
        .{ 0x00, 0x00, 0xAA }, // blue
        .{ 0x00, 0xAA, 0x00 }, // green
        .{ 0x00, 0xAA, 0xAA }, // cyan
        .{ 0xAA, 0x00, 0x00 }, // red
        .{ 0xAA, 0x00, 0xAA }, // magenta
        .{ 0xAA, 0x55, 0x00 }, // brown
        .{ 0xAA, 0xAA, 0xAA }, // light grey
        .{ 0x55, 0x55, 0x55 }, // dark grey
        .{ 0x55, 0x55, 0xFF }, // light blue
        .{ 0x55, 0xFF, 0x55 }, // light green
        .{ 0x55, 0xFF, 0xFF }, // light cyan
        .{ 0xFF, 0x55, 0x55 }, // light red
        .{ 0xFF, 0x55, 0xFF }, // light magenta
        .{ 0xFF, 0xFF, 0x55 }, // yellow
        .{ 0xFF, 0xFF, 0xFF }, // white
    };
    for (default_pal, 0..) |entry, i| {
        setPaletteEntry(@intCast(i), entry[0], entry[1], entry[2]);
    }
}

// ── Cursor Control ──

pub fn setCursorPosition(x: u16, y: u16) void {
    const pos: u16 = y * 80 + x;
    vgaWriteCrtc(0x0F, @truncate(pos & 0xFF));
    vgaWriteCrtc(0x0E, @truncate((pos >> 8) & 0xFF));
}

pub fn enableCursor(start_line: u8, end_line: u8) void {
    vgaWriteCrtc(0x0A, (vgaReadCrtc(0x0A) & 0xC0) | start_line);
    vgaWriteCrtc(0x0B, (vgaReadCrtc(0x0B) & 0xE0) | end_line);
}

pub fn disableCursor() void {
    vgaWriteCrtc(0x0A, 0x20);
}

// ── Graphics Primitives (Mode 13h) ──

pub fn putPixel(x: u32, y: u32, color: u8) void {
    if (x >= current_width or y >= current_height) return;
    const ptr: [*]volatile u8 = @ptrFromInt(current_fb);
    ptr[y * current_pitch + x] = color;
}

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u8) void {
    const ptr: [*]volatile u8 = @ptrFromInt(current_fb);
    var py: u32 = y;
    while (py < y + h and py < current_height) : (py += 1) {
        var px: u32 = x;
        while (px < x + w and px < current_width) : (px += 1) {
            ptr[py * current_pitch + px] = color;
        }
    }
}

pub fn clearScreen(color: u8) void {
    fillRect(0, 0, current_width, current_height, color);
}

// ── IRP Dispatch (NT Driver Model) ──

fn vgaDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => return handleIoctl(irp),
        .read => {
            irp.complete(.success, 0);
            return .success;
        },
        .write => {
            irp.complete(.success, 0);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.IoStatus {
    switch (irp.ioctl_code) {
        IOCTL_VIDEO_QUERY_NUM_MODES => {
            irp.complete(.success, supported_modes.len);
            return .success;
        },
        IOCTL_VIDEO_QUERY_CURRENT_MODE => {
            irp.complete(.success, @intFromEnum(current_mode));
            return .success;
        },
        IOCTL_VIDEO_SET_MODE => {
            const mode_byte: u8 = @truncate(irp.buffer_ptr & 0xFF);
            const mode: VideoMode = @enumFromInt(mode_byte);
            switch (mode) {
                .text_80x25 => setTextMode(),
                .gfx_320x200_256 => setMode13h(),
                else => {
                    irp.complete(.not_implemented, 0);
                    return .not_implemented;
                },
            }
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_VIDEO_RESET => {
            setTextMode();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_VIDEO_MAP_FRAMEBUFFER => {
            irp.buffer_ptr = current_fb;
            irp.complete(.success, current_pitch * current_height);
            return .success;
        },
        IOCTL_VIDEO_SET_PALETTE => {
            setDefaultPalette();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_VIDEO_SET_CURSOR_POS => {
            const x: u16 = @truncate(irp.buffer_ptr & 0xFFFF);
            const y: u16 = @truncate((irp.buffer_ptr >> 16) & 0xFFFF);
            setCursorPosition(x, y);
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_VIDEO_ENABLE_CURSOR => {
            if (irp.buffer_ptr != 0) {
                enableCursor(13, 14);
            } else {
                disableCursor();
            }
            irp.complete(.success, 0);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

// ── State Query ──

pub fn getCurrentMode() VideoMode {
    return current_mode;
}

pub fn getWidth() u32 {
    return current_width;
}

pub fn getHeight() u32 {
    return current_height;
}

pub fn getBpp() u8 {
    return current_bpp;
}

pub fn getFramebufferAddr() usize {
    return current_fb;
}

pub fn isTextMode() bool {
    return is_text_mode;
}

pub fn isInitialized() bool {
    return driver_initialized;
}

// ── Initialization ──

pub fn init() void {
    driver_idx = io.registerDriver("\\Driver\\Vga", vgaDispatch) orelse {
        klog.err("VGA: Failed to register driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\Video0", .framebuffer, driver_idx) orelse {
        klog.err("VGA: Failed to create device", .{});
        return;
    };

    setDefaultPalette();
    driver_initialized = true;

    klog.info("VGA Driver: initialized (mode=0x%x, %ux%u, device=\\Device\\Video0)", .{
        @intFromEnum(current_mode), current_width, current_height,
    });
}
