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

//! Desktop icons — kernel framebuffer rendering path.

pub const icons = @import("icons.zig");
pub const IconId = icons.IconId;
pub const ThemeStyle = icons.ThemeStyle;
pub const ICON_PX_SIZE = icons.ICON_PX_SIZE;
pub const IconNameInfo = icons.IconNameInfo;
pub const iconNameInfo = icons.iconNameInfo;
pub const bitmapIconId = icons.bitmapIconId;
pub const drawIcon = icons.drawIcon;
pub const drawThemedIcon = icons.drawThemedIcon;
pub const drawSvgIconBySize = icons.drawSvgIconBySize;
pub const drawStartOrb = icons.drawStartOrb;
pub const getIconTotalSize = icons.getIconTotalSize;
pub const getSvgIconData = icons.getSvgIconData;
