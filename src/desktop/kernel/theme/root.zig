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

//! NT 6.1 Aero theme — kernel framebuffer rendering path.

pub const theme = @import("theme.zig");
pub const ThemeColors = theme.ThemeColors;
pub const ThemeId = theme.ThemeId;
pub const THEME_AERO = theme.THEME_AERO;
pub const rgb = theme.rgb;
pub const setTheme = theme.setTheme;
pub const getActiveTheme = theme.getActiveTheme;
pub const getActiveThemeId = theme.getActiveThemeId;
pub const getThemeName = theme.getThemeName;
pub const getTaskbarHeight = theme.getTaskbarHeight;
