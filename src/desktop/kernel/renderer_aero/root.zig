// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! DWM renderer — kernel framebuffer rendering path.
//! 继承自旧的 Aero 渲染器，现在映射到新的 D3D10 DWM 系统。

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
