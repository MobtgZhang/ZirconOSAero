//! ZirconOS Driver Module Root
//! Centralized kernel-mode driver load order (NT 6.x–style: bus → class → PnP stack).
//! Reference: WDM driver model, ReactOS `drivers/` tree, Windows Driver Kit (KMDF concepts
//! mapped onto this kernel’s `io.Irp` + `registerDriver` / `createDevice`).
//!
//! Categories:
//!   bus/      - PCI/PCIe configuration (Type 1 host access)
//!   storage/  - ATA/IDE class driver
//!   timer/    - PIT (HAL tick), RTC (CMOS)
//!   video/    - VGA, HDMI, Framebuffer, display manager
//!   audio/    - AC’97 (PortCls-style IOCTL surface)
//!   input/    - PS/2 8042、VirtIO-Input PCI（`input_hub` 聚合轮询）
//!   usb/      - USB 主机 + HID 类占位（MMIO/枚举待接）
//!
//! Each driver registers a `DriverObject` dispatch routine and one or more `DeviceObject`s.

const builtin = @import("builtin");
const klog = @import("../rtl/klog.zig");

const is_x86 = (builtin.target.cpu.arch == .x86_64);

pub const bus = if (is_x86) struct {
    pub const pcie = @import("bus/pcie.zig");
    pub const i2c = @import("bus/i2c.zig");
    pub const spi = @import("bus/spi.zig");
    pub const serial_bus = @import("bus/serial_bus.zig");
} else struct {
    pub const pcie = @import("bus/pcie.zig");
    pub const i2c = @import("bus/i2c.zig");
    pub const spi = @import("bus/spi.zig");
};

pub const timer = if (is_x86) struct {
    pub const pit_timer = @import("timer/pit_timer.zig");
    pub const rtc = @import("timer/rtc.zig");
} else struct {};

pub const storage = if (is_x86) struct {
    pub const ata = @import("storage/ata.zig");
} else struct {};

pub const video = struct {
    pub const vga = @import("video/vga.zig");
    pub const hdmi = @import("video/hdmi.zig");
    pub const framebuffer = @import("video/framebuffer.zig");
    pub const display = @import("video/display.zig");
    /// Shell UI strings (English default); future MUI/language packs extend `shell_strings.zig`.
    pub const shell_strings = @import("video/shell_strings.zig");
    pub const icons = @import("video/icons.zig");
    pub const startmenu = @import("video/startmenu.zig");
    pub const dwm_compositor = @import("video/dwm_compositor.zig");
    pub const material = @import("video/material.zig");
};

pub const audio = struct {
    pub const core = @import("audio/audio.zig");
    pub const ac97 = @import("audio/ac97.zig");
};

pub const input = struct {
    pub const mouse = @import("input/mouse.zig");
    pub const input_hub = @import("input/input_hub.zig");
    pub const virtio_input_pci = @import("input/virtio_input_pci.zig");
    pub const kbd = @import("input/kbd.zig");
};

pub const usb = @import("usb/usb.zig");

pub const net = struct {
    pub const ndis = @import("net/ndis.zig");
};

var drivers_initialized: bool = false;

pub fn init() void {
    klog.info("Drivers: Initializing driver stack...", .{});

    if (bus.pcie.supports_pci_config) {
        bus.pcie.init();
    }

    if (is_x86) {
        bus.serial_bus.init();
        storage.ata.init();
        timer.pit_timer.init();
        timer.rtc.init();
    }

    video.display.init();

    net.ndis.init();
    usb.init();

    drivers_initialized = true;

    klog.info("Drivers: Video ready (VGA=%s, HDMI=%s, Display=%s)", .{
        if (video.vga.isInitialized()) "yes" else "no",
        if (video.hdmi.isInitialized()) "yes" else "no",
        if (video.display.isInitialized()) "yes" else "no",
    });

    if (is_x86) {
        klog.info("Drivers: Bus/Timer/Storage (PCI=%s, PIT=%s, RTC=%s, ATA=%s, USB=%s)", .{
            if (bus.pcie.isInitialized()) "yes" else "no",
            if (timer.pit_timer.isInitialized()) "yes" else "no",
            if (timer.rtc.isInitialized()) "yes" else "no",
            if (storage.ata.isInitialized()) "yes" else "no",
            if (usb.isInitialized()) "yes" else "no",
        });
    } else if (bus.pcie.supports_pci_config) {
        klog.info("Drivers: PCI=%s, USB=%s", .{
            if (bus.pcie.isInitialized()) "yes" else "no",
            if (usb.isInitialized()) "yes" else "no",
        });
    }
}

pub fn initInputDrivers() void {
    if (is_x86 or builtin.target.cpu.arch == .loongarch64) {
        input.kbd.init();
    }
    input.mouse.registerWithIo();
    input.virtio_input_pci.init();

    klog.info("Drivers: Input ready (Kbd=%s, Mouse=%s, VirtIOInput=%s)", .{
        if (input.kbd.isInitialized()) "yes" else "no",
        if (input.mouse.isInitialized()) "yes" else "no",
        if (input.virtio_input_pci.isActive()) "yes" else "no",
    });
}

pub fn initAudioDrivers() void {
    audio.ac97.init();

    klog.info("Drivers: Audio ready (AC97=%s)", .{
        if (audio.ac97.isInitialized()) "yes" else "no",
    });
}

pub fn initDesktopMode(fb_addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    video.display.initDesktopMode(fb_addr, width, height, pitch, bpp, pixel_bgr);
    video.hdmi.syncFramebufferMode(width, height, bpp);

    input.mouse.setScreenBounds(@intCast(width), @intCast(height));
    input.mouse.setPosition(@intCast(width / 2), @intCast(height / 2));
    if (is_x86) {
        input.mouse.reassertStreamEnable();
    }

    klog.info("Drivers: Desktop display mode enabled (%ux%u@%ubpp)", .{ width, height, bpp });
}

pub fn isInitialized() bool {
    return drivers_initialized;
}

pub fn isDesktopReady() bool {
    return video.display.isDesktopReady();
}
