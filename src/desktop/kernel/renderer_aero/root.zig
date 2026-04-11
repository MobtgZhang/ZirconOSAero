//! Aero renderer — kernel framebuffer rendering path.

pub const renderer_aero = @import("renderer_aero.zig");

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
