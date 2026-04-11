//! Wallpaper rendering — kernel framebuffer rendering path.

pub const wallpaper_bitmap = @import("wallpaper_bitmap.zig");
pub const drawPreset = wallpaper_bitmap.drawPreset;
pub const drawPresetRegion = wallpaper_bitmap.drawPresetRegion;
pub const presetSupportsPartialRedraw = wallpaper_bitmap.presetSupportsPartialRedraw;
pub const wallpaper_preset_count = wallpaper_bitmap.wallpaper_preset_count;
