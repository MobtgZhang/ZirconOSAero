//! ZirconOS Driver Module Root
//! Centralized kernel-mode driver load order (NT 6.x–style: bus → class → PnP stack).
//! Reference: WDM driver model (Microsoft Learn / WDK), KMDF concepts mapped onto this kernel’s
//! `io.Irp` + `registerDriver` / `createDevice`.
//!
//! Categories:
//!   bus/      - PCI/PCIe configuration (Type 1 host access)
//!   storage/  - ATA/IDE class driver
//!   timer/    - PIT (HAL tick), RTC (CMOS)
//!   video/    - VGA, HDMI, Framebuffer, display manager
//!   audio/    - AC’97 (PortCls-style IOCTL surface)
//!   input/    - PS/2 8042、VirtIO-Input PCI（`input_hub` 聚合轮询）
//!   usb/      - USB：PCI 枚举 xHCI/EHCI 占位、根口枚举、Hub 控制传输、HID Boot 鼠标（事件环轮询）
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
    pub const intel_igpu = @import("video/intel_igpu.zig");
    pub const nvidia_gpu = @import("video/nvidia_gpu.zig");
    pub const amd_igpu = @import("video/amd_igpu.zig");
    pub const loongson_igpu = @import("video/loongson_igpu.zig");
    pub const desktop_fb_resolve = @import("video/desktop_fb_resolve.zig");
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

    const bopts_init = @import("build_options");
    if (builtin.target.cpu.arch == .loongarch64 and bopts_init.loongson_igpu) {
        video.loongson_igpu.init();
    }
    if (is_x86 and bopts_init.nvidia_gpu) {
        video.nvidia_gpu.init();
    }
    if (is_x86 and bopts_init.amd_igpu) {
        video.amd_igpu.init();
    }
    if (is_x86 and bopts_init.intel_igpu) {
        video.intel_igpu.init();
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

    const bopts_log = @import("build_options");
    klog.info("Drivers: Video ready (VGA=%s, HDMI=%s, Display=%s, LoongsonIGPU=%s, NVIDIA=%s, AMDDisplay=%s, IntelIGPU=%s)", .{
        if (video.vga.isInitialized()) "yes" else "no",
        if (video.hdmi.isInitialized()) "yes" else "no",
        if (video.display.isInitialized()) "yes" else "no",
        if (builtin.target.cpu.arch == .loongarch64 and bopts_log.loongson_igpu) blk: {
            if (video.loongson_igpu.isDeferredProbePending()) break :blk "defer";
            if (video.loongson_igpu.isActive()) break :blk "yes";
            break :blk "no";
        } else "n/a",
        if (is_x86 and bopts_log.nvidia_gpu)
        blk: {
            if (video.nvidia_gpu.isDeferredProbePending()) break :blk "defer";
            if (video.nvidia_gpu.isActive()) break :blk "yes";
            break :blk "no";
        } else "n/a",
        if (is_x86 and bopts_log.amd_igpu)
        blk: {
            if (video.amd_igpu.isDeferredProbePending()) break :blk "defer";
            if (video.amd_igpu.isActive()) break :blk "yes";
            break :blk "no";
        } else "n/a",
        if (is_x86 and bopts_log.intel_igpu)
        blk: {
            if (video.intel_igpu.isDeferredProbePending()) break :blk "defer";
            if (video.intel_igpu.isActive()) break :blk "yes";
            break :blk "no";
        } else "n/a",
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
    klog.info("Input: VirtIO_Input_PCI=%s PS2_hw=%s (initDesktopMode sets pointer bounds)", .{
        if (input.virtio_input_pci.isActive()) "active" else "inactive",
        if (is_x86)
            (if (input.mouse.isHardwareInitialized()) "ok" else "no")
        else
            "n/a",
    });
    const bopts = @import("build_options");
    klog.info("InputDiag: MOUSE_DEBUG=%u AGENT_NDJSON=%u NVIDIA_GPU=%u nvidia_defer=%u AMD_IGPU=%u amd_defer=%u INTEL_IGPU=%u intel_defer=%u idle_spin=%u — pointer stuck? see docs/cn/AeroDesktopRuntime.md; isolate: make AMD_IGPU=false / INTEL_IGPU=false / NVIDIA_GPU=false", .{
        @intFromBool(bopts.mouse_debug),
        @intFromBool(bopts.agent_ndjson),
        @intFromBool(bopts.nvidia_gpu),
        @intFromBool(bopts.nvidia_gpu_defer_probe),
        @intFromBool(bopts.amd_igpu),
        @intFromBool(bopts.amd_igpu_defer_probe),
        @intFromBool(bopts.intel_igpu),
        @intFromBool(bopts.intel_igpu_defer_probe),
        @intFromBool(bopts.desktop_idle_spin),
    });
}

pub fn initAudioDrivers() void {
    audio.ac97.init();

    klog.info("Drivers: Audio ready (AC97=%s)", .{
        if (audio.ac97.isInitialized()) "yes" else "no",
    });
}

/// GOP/桌面表面逻辑尺寸变化时统一更新指针边界、VirtIO ABS 基线与 DWM 光标状态（未来 `IOCTL_DISPLAY_SET_MODE` 亦应调用）。
pub fn notifyDisplayGeometryChanged(width: u32, height: u32) void {
    input.mouse.setScreenBounds(@intCast(width), @intCast(height));
    input.virtio_input_pci.resetPointerBaseline();
    if (is_x86) {
        input.mouse.reassertStreamEnable();
    }
    video.display.syncCursorFromMouse();
}

pub fn initDesktopMode(fb_addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    video.display.initDesktopMode(fb_addr, width, height, pitch, bpp, pixel_bgr);
    video.hdmi.syncFramebufferMode(width, height, bpp);

    input.mouse.setPosition(@intCast(width / 2), @intCast(height / 2));
    notifyDisplayGeometryChanged(width, height);

    klog.info("Drivers: Desktop display mode enabled (%ux%u@%ubpp)", .{ width, height, bpp });
    klog.info("Desktop: fb %ux%u pitch=%u bpp=%u BGR=%u mouse=(%d,%d) bounds=%ux%u", .{
        width,
        height,
        pitch,
        bpp,
        @intFromBool(pixel_bgr),
        input.mouse.getX(),
        input.mouse.getY(),
        width,
        height,
    });
    video.framebuffer.logDesktopPointerDiagnostics(
        input.virtio_input_pci.isActive(),
        if (is_x86) input.mouse.isHardwareInitialized() else false,
    );
}

pub fn isInitialized() bool {
    return drivers_initialized;
}

pub fn isDesktopReady() bool {
    return video.display.isDesktopReady();
}
