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
