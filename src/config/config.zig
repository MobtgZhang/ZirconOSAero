//! ZirconOS Configuration Manager
//! Provides a global interface for reading OS configuration values.
//! Default configs are embedded at compile time; runtime overrides can be
//! loaded from VFS once the filesystem is available.

const builtin = @import("builtin");
const parser = @import("parser.zig");
const defaults = @import("config_defaults");
const klog = @import("../rtl/klog.zig");

pub const Config = parser.Config;
pub const Entry = parser.Entry;

var system_config: Config = .{};
var boot_config: Config = .{};
var desktop_config: Config = .{};
var initialized: bool = false;

pub fn init() void {
    klog.info("Config: Loading embedded default configuration...", .{});

    system_config.parse(defaults.system_conf);
    boot_config.parse(defaults.boot_conf);
    desktop_config.parse(defaults.desktop_conf);

    initialized = true;

    klog.info("Config: system.conf loaded (%u entries)", .{system_config.getEntryCount()});
    klog.info("Config: boot.conf loaded (%u entries)", .{boot_config.getEntryCount()});
    klog.info("Config: desktop.conf loaded (%u entries)", .{desktop_config.getEntryCount()});

    if (klog.DEBUG_MODE) {
        system_config.dump();
        boot_config.dump();
        desktop_config.dump();
    }
}

pub fn isInitialized() bool {
    return initialized;
}

// ─── System Config Accessors ───

pub fn getSystem() *const Config {
    return &system_config;
}

pub fn getBoot() *const Config {
    return &boot_config;
}

pub fn getHostname() []const u8 {
    return system_config.getOr("system", "hostname", "ZirconOS");
}

pub fn getVersion() []const u8 {
    return system_config.getOr("system", "version", "6.1.7601");
}

pub fn getCsdVersion() []const u8 {
    return system_config.getOr("system", "csd_version", "Service Pack 1");
}

pub fn getServicePackMajor() u64 {
    return system_config.getIntOr("system", "service_pack_major", 1);
}

pub fn getServicePackMinor() u64 {
    return system_config.getIntOr("system", "service_pack_minor", 0);
}

pub fn getSuiteMask() u64 {
    return system_config.getHexOr("system", "suite_mask", 0x0100);
}

pub fn getProductType() u64 {
    return system_config.getIntOr("system", "product_type", 1);
}

pub fn getArch() []const u8 {
    return system_config.getOr("system", "arch", "x86_64");
}

pub fn getMaxCpus() u64 {
    return system_config.getIntOr("system", "max_cpus", 4);
}

pub fn getTickRateHz() u64 {
    return system_config.getIntOr("system", "tick_rate_hz", 100);
}

// ─── Memory Config Accessors ───

pub fn getHeapSizeKb() u64 {
    return system_config.getIntOr("memory", "heap_size_kb", 4096);
}

pub fn getFrameSize() u64 {
    return system_config.getIntOr("memory", "frame_size", 4096);
}

pub fn getMaxPhysicalMb() u64 {
    return system_config.getIntOr("memory", "max_physical_mb", 4096);
}

pub fn getStackSizeKb() u64 {
    return system_config.getIntOr("memory", "stack_size_kb", 64);
}

pub fn getUserStackSizeKb() u64 {
    return system_config.getIntOr("memory", "user_stack_size_kb", 256);
}

pub fn getKernelHeapStart() u64 {
    return system_config.getHexOr("memory", "kernel_heap_start", 0xFFFF800000000000);
}

// ─── Scheduler Config Accessors ───

pub fn getMaxProcesses() u64 {
    return system_config.getIntOr("scheduler", "max_processes", 256);
}

pub fn getMaxThreads() u64 {
    return system_config.getIntOr("scheduler", "max_threads", 1024);
}

pub fn getTimeSliceMs() u64 {
    return system_config.getIntOr("scheduler", "time_slice_ms", 20);
}

pub fn getPriorityLevels() u64 {
    return system_config.getIntOr("scheduler", "priority_levels", 32);
}

// ─── Display Config Accessors ───

pub fn getDefaultWidth() u64 {
    return system_config.getIntOr("display", "default_width", 1024);
}

pub fn getDefaultHeight() u64 {
    return system_config.getIntOr("display", "default_height", 768);
}

pub fn getDefaultBpp() u64 {
    return system_config.getIntOr("display", "default_bpp", 32);
}

pub fn getFontHeight() u64 {
    return system_config.getIntOr("display", "font_height", 16);
}

pub fn getFontWidth() u64 {
    return system_config.getIntOr("display", "font_width", 8);
}

// ─── Console Config Accessors ───

pub fn isSerialEnabled() bool {
    return system_config.getBoolOr("console", "serial_enabled", true);
}

pub fn getSerialBaud() u64 {
    return system_config.getIntOr("console", "serial_baud", 115200);
}

pub fn getSerialPort() u64 {
    return system_config.getHexOr("console", "serial_port", 0x3F8);
}

pub fn isVgaEnabled() bool {
    return system_config.getBoolOr("console", "vga_enabled", true);
}

pub fn getLogLevel() []const u8 {
    return system_config.getOr("console", "log_level", "info");
}

// ─── Filesystem Config Accessors ───

pub fn getRootFs() []const u8 {
    return system_config.getOr("filesystem", "root_fs", "fat32");
}

pub fn getRootDevice() []const u8 {
    return system_config.getOr("filesystem", "root_device", "C");
}

pub fn getMaxOpenFiles() u64 {
    return system_config.getIntOr("filesystem", "max_open_files", 256);
}

pub fn getPathMax() u64 {
    return system_config.getIntOr("filesystem", "path_max", 260);
}

// ─── Network Config Accessors ───

pub fn isNetworkEnabled() bool {
    return system_config.getBoolOr("network", "enabled", false);
}

pub fn isDhcpEnabled() bool {
    return system_config.getBoolOr("network", "dhcp", true);
}

// ─── Win32 Config Accessors ───

pub fn isWin32Enabled() bool {
    return system_config.getBoolOr("win32", "subsystem_enabled", true);
}

pub fn isWow64Enabled() bool {
    return system_config.getBoolOr("win32", "wow64_enabled", true);
}

pub fn getMaxWindows() u64 {
    return system_config.getIntOr("win32", "max_windows", 128);
}

pub fn getMaxGdiObjects() u64 {
    return system_config.getIntOr("win32", "max_gdi_objects", 1024);
}

pub fn getDefaultShell() []const u8 {
    return system_config.getOr("win32", "default_shell", "cmd");
}

// ─── Boot Config Accessors ───

pub fn getBootTimeout() u64 {
    return boot_config.getIntOr("boot", "timeout", 5);
}

pub fn getDefaultBootEntry() []const u8 {
    return boot_config.getOr("boot", "default_entry", "normal");
}

pub fn isBootVerbose() bool {
    return boot_config.getBoolOr("boot", "verbose", false);
}

pub fn isSplashEnabled() bool {
    return boot_config.getBoolOr("boot", "splash_enabled", true);
}

pub fn getGrubGfxMode() []const u8 {
    return boot_config.getOr("grub", "gfxmode", "1024x768x32");
}

pub fn getTotalConfigEntries() usize {
    return system_config.getEntryCount() + boot_config.getEntryCount() + desktop_config.getEntryCount();
}

// ─── Desktop Config Accessors ───

pub fn getDesktop() *const Config {
    return &desktop_config;
}

pub fn getDesktopTheme() []const u8 {
    return desktop_config.getOr("desktop", "theme", "aero");
}

pub fn getDesktopColorScheme() []const u8 {
    return desktop_config.getOr("desktop", "color_scheme", "blue");
}

pub fn getDesktopShell() []const u8 {
    return desktop_config.getOr("desktop", "shell", "explorer");
}

pub fn isAutoLogon() bool {
    return desktop_config.getBoolOr("desktop", "auto_logon", false);
}

pub fn getAutoLogonUser() []const u8 {
    return desktop_config.getOr("desktop", "auto_logon_user", "");
}

pub fn getResolutionWidth() u64 {
    return desktop_config.getIntOr("resolution", "width", 1024);
}

pub fn getResolutionHeight() u64 {
    return desktop_config.getIntOr("resolution", "height", 768);
}

pub fn getResolutionBpp() u64 {
    return desktop_config.getIntOr("resolution", "bpp", 32);
}

pub fn getRefreshRate() u64 {
    return desktop_config.getIntOr("resolution", "refresh_rate", 60);
}

pub fn getDpi() u64 {
    return desktop_config.getIntOr("resolution", "dpi", 96);
}

pub fn getWallpaperStyle() []const u8 {
    return desktop_config.getOr("wallpaper", "style", "solid_color");
}

pub fn getWallpaperColor() u64 {
    return desktop_config.getHexOr("wallpaper", "color", 0x004E98);
}

pub fn getWallpaperPath() []const u8 {
    return desktop_config.getOr("wallpaper", "path", "");
}

pub fn getDisplayDriver() []const u8 {
    return desktop_config.getOr("display", "driver", "auto");
}

pub fn isVsyncEnabled() bool {
    return desktop_config.getBoolOr("display", "vsync", true);
}

pub fn isDoubleBufferEnabled() bool {
    return desktop_config.getBoolOr("display", "double_buffer", true);
}

/// 第二幅离屏后备（乒乓）；总表面数 = GOP + 2×离屏。默认关；大帧需连续物理页或静态区可容纳 2×frame。
pub fn isTripleBufferEnabled() bool {
    return desktop_config.getBoolOr("display", "triple_buffer", false);
}

/// 双缓冲时默认整幅 `memcpy` 到 GOP；为 false 时用脏矩形 `flipDirty`（须保证光标区已 mark dirty）。
/// LoongArch64 + UEFI/GOP 在 QEMU 上整幅 flip 代价高，默认改为脏矩形以减轻鼠标拖动卡顿（仍可在 desktop.conf 写 `present_full_flip=true`）。
pub fn isPresentFullFlipEnabled() bool {
    const arch_default: bool = switch (builtin.target.cpu.arch) {
        .loongarch64 => false,
        else => true,
    };
    return desktop_config.getBoolOr("display", "present_full_flip", arch_default);
}

/// 初始化时把当前可见 GOP 拷入离屏绘制缓冲（两槽均拷）；默认关。首帧前常与 `clearFramebuffer` 二选一。
pub fn isSeedDrawBufferFromGopEnabled() bool {
    return desktop_config.getBoolOr("display", "seed_gop_to_back", false);
}

/// 超大帧 `allocContiguous` 失败时退化为单缓冲直写 GOP；为 false 则仅告警并保持关双缓冲。
pub fn allowSingleBufferOnLargeAllocFail() bool {
    return desktop_config.getBoolOr("display", "fall_back_single_on_alloc_fail", true);
}

pub fn isHardwareCursorEnabled() bool {
    return desktop_config.getBoolOr("display", "hardware_cursor", true);
}

pub fn getMaxMonitors() u64 {
    return desktop_config.getIntOr("display", "max_monitors", 4);
}

pub fn isVgaDriverEnabled() bool {
    return desktop_config.getBoolOr("video_driver", "vga_enabled", true);
}

pub fn isFramebufferDriverEnabled() bool {
    return desktop_config.getBoolOr("video_driver", "framebuffer_enabled", true);
}

pub fn isHdmiEnabled() bool {
    return desktop_config.getBoolOr("video_driver", "hdmi_enabled", false);
}

pub fn isEdidDetectEnabled() bool {
    return desktop_config.getBoolOr("video_driver", "edid_detect", true);
}

pub fn getDesktopMaxWindows() u64 {
    return desktop_config.getIntOr("window_manager", "max_windows", 128);
}

pub fn isAnimateWindows() bool {
    return desktop_config.getBoolOr("window_manager", "animate_windows", true);
}

pub fn isShadowEnabled() bool {
    return desktop_config.getBoolOr("window_manager", "shadow_enabled", true);
}

pub fn getTaskbarPosition() []const u8 {
    return desktop_config.getOr("taskbar", "position", "bottom");
}

pub fn getTaskbarHeight() u64 {
    return desktop_config.getIntOr("taskbar", "height", 30);
}

pub fn isTaskbarAutoHide() bool {
    return desktop_config.getBoolOr("taskbar", "auto_hide", false);
}

pub fn isShowClock() bool {
    return desktop_config.getBoolOr("taskbar", "show_clock", true);
}

pub fn isShowTray() bool {
    return desktop_config.getBoolOr("taskbar", "show_tray", true);
}

pub fn isWelcomeScreen() bool {
    return desktop_config.getBoolOr("login", "welcome_screen", true);
}

pub fn getScreenSaverTimeout() u64 {
    return desktop_config.getIntOr("login", "screen_saver_timeout", 600);
}

pub fn getDesktopIconSize() u64 {
    return desktop_config.getIntOr("icons", "icon_size", 32);
}

pub fn isShowDesktopIcons() bool {
    return desktop_config.getBoolOr("icons", "show_desktop_icons", true);
}

pub fn getSystemFont() []const u8 {
    return desktop_config.getOr("fonts", "system_font", "Liberation Sans");
}

pub fn getSystemFontSize() u64 {
    return desktop_config.getIntOr("fonts", "system_font_size", 8);
}
