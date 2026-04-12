//! Kernel desktop modules barrel — kernel framebuffer rendering path.

pub const icons = @import("icons/root.zig");
pub const startmenu = @import("startmenu/root.zig");
pub const taskbar = @import("taskbar/root.zig");
pub const theme = @import("theme/root.zig");
pub const strings = @import("strings/root.zig");
pub const renderer_aero = @import("renderer_aero/root.zig");
pub const material = @import("material/root.zig");
pub const cursor = @import("cursor/root.zig");
pub const wallpaper = @import("wallpaper/root.zig");
pub const shell = @import("shell/root.zig");

// ── renderer_aero ──
pub const initDwm = renderer_aero.initDwm;
pub const render = renderer_aero.render;
pub const renderFrameEx = renderer_aero.renderFrameEx;
pub const renderFrame = renderer_aero.renderFrame;
pub const startMenuRepaintCanPatchWallpaper = renderer_aero.startMenuRepaintCanPatchWallpaper;
pub const redrawStartMenuRegionOnly = renderer_aero.redrawStartMenuRegionOnly;
pub const redrawCaptionBandsOnly = renderer_aero.redrawCaptionBandsOnly;
pub const wallpaper_preset_count = renderer_aero.wallpaper_preset_count;
pub const cycleWallpaperPreset = renderer_aero.cycleWallpaperPreset;
pub const wallpaperPresetIndex = renderer_aero.wallpaperPresetIndex;

// ── material ──
pub const MaterialType = material.MaterialType;
pub const GlassConfig = material.GlassConfig;
pub const AcrylicConfig = material.AcrylicConfig;
pub const MicaConfig = material.MicaConfig;
pub const matInit = material.init;
pub const matConfigureGlass = material.configureGlass;
pub const matConfigureAcrylic = material.configureAcrylic;
pub const matConfigureMica = material.configureMica;
pub const matRenderGlass = material.renderGlass;
pub const matRenderAcrylic = material.renderAcrylic;
pub const matRenderMica = material.renderMica;
pub const matRenderAcrylic2 = material.renderAcrylic2;
pub const matRenderRevealHighlight = material.renderRevealHighlight;
pub const matRenderShadow = material.renderShadow;
pub const matApplyRoundedClipAA = material.applyRoundedClipAA;
pub const matApplyRoundedClip = material.applyRoundedClip;
pub const matIsInitialized = material.isInitialized;
pub const matGetActiveMaterial = material.getActiveMaterial;
pub const matGetGlassConfig = material.getGlassConfig;
pub const matGetAcrylicConfig = material.getAcrylicConfig;
pub const matGetMicaConfig = material.getMicaConfig;

// ── shell (builtin_apps) ──
pub const allProgramsCount = shell.allProgramsCount;
pub const pollKeyboardToFocused = shell.pollKeyboardToFocused;
pub const builtin_apps = shell.builtin_apps;
pub const explorer_state = shell.explorer_state;
pub const explorer_format = shell.explorer_format;
pub const drag_state = shell.drag_state;
pub const classic_shell = shell.classic_shell;
pub const anyWindowOpen = shell.anyWindowOpen;
pub const topDraggedWindowRect = shell.topDraggedWindowRect;
pub const launch = shell.launch;
pub const titleOf = shell.titleOf;
pub const BuiltinAppId = shell.BuiltinAppId;
pub const ShellRect = shell.ShellRect;
pub const RenderMode = shell.RenderMode;
pub const renderShellHostedApps = shell.renderShellHostedApps;
pub const ResizeEdge = shell.ResizeEdge;
pub const hitTestFrameResizeEdge = shell.hitTestFrameResizeEdge;
pub const clampShellFrameToWorkArea = shell.clampShellFrameToWorkArea;
pub const process_table = shell.process_table;
pub const initDesktopProcessTable = shell.initDesktopProcessTable;
pub const registerDesktopProcess = shell.registerDesktopProcess;
pub const getTaskbarAppList = shell.getTaskbarAppList;
pub const getTaskbarAppCount = shell.getTaskbarAppCount;
pub const DesktopProcessEntry = shell.DesktopProcessEntry;
pub const TaskbarAppEntry = shell.TaskbarAppEntry;
pub const minimizeWindow = shell.minimizeWindow;
pub const maximizeWindow = shell.maximizeWindow;
pub const closeWindow = shell.closeWindow;
pub const isWindowMinimized = shell.isWindowMinimized;
pub const getWindowState = shell.getWindowState;
pub const WinState = shell.WinState;
pub const getOpenWindowCount = shell.getOpenWindowCount;
pub const getFocusedSlotIndex = shell.getFocusedSlotIndex;

// ── wallpaper ──
pub const wallpaper_bitmap = wallpaper.wallpaper_bitmap;
pub const drawPreset = wallpaper.drawPreset;
pub const drawPresetRegion = wallpaper.drawPresetRegion;
pub const presetSupportsPartialRedraw = wallpaper.presetSupportsPartialRedraw;

// ── cursor ──
pub const aero_cursor_shape = cursor.aero_cursor_shape;
pub const CursorKind = cursor.CursorKind;
pub const CursorPixelArray = cursor.CursorPixelArray;
pub const cursorPixels = cursor.cursorPixels;

// ── taskbar ──
pub const aero_tray = taskbar.aero_tray;
pub const taskbar_ex = taskbar.taskbar_ex;
