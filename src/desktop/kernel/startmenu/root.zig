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

//! Windows 7-style Start Menu — kernel framebuffer rendering path.

pub const startmenu = @import("startmenu.zig");
pub const MenuItem = startmenu.MenuItem;
pub const MenuStyle = startmenu.MenuStyle;
pub const MenuRect = startmenu.MenuRect;
pub const MenuAction = startmenu.MenuAction;
pub const isVisible = startmenu.isVisible;
pub const isFullyOpen = startmenu.isFullyOpen;
pub const show = startmenu.show;
pub const hide = startmenu.hide;
pub const toggle = startmenu.toggle;
pub const updateAnimation = startmenu.updateAnimation;
pub const updateMousePosition = startmenu.updateMousePosition;
pub const getHoverDisplayIndex = startmenu.getHoverDisplayIndex;
pub const setOrbHover = startmenu.setOrbHover;
pub const setOrbPressed = startmenu.setOrbPressed;
pub const isOrbPressed = startmenu.isOrbPressed;
pub const getOrbHoverProgress = startmenu.getOrbHoverProgress;
pub const getOrbPressProgress = startmenu.getOrbPressProgress;
pub const getAnimProgress = startmenu.getAnimProgress;
pub const getAnimState = startmenu.getAnimState;
pub const isAnimating = startmenu.isAnimating;
pub const navigateUp = startmenu.navigateUp;
pub const navigateDown = startmenu.navigateDown;
pub const navigateLeft = startmenu.navigateLeft;
pub const navigateRight = startmenu.navigateRight;
pub const executeSelectedItem = startmenu.executeSelectedItem;
pub const setHoverIndex = startmenu.setHoverIndex;
pub const pointerHoverIndex = startmenu.pointerHoverIndex;
pub const getMenuRect = startmenu.getMenuRect;
pub const getInteractiveBounds = startmenu.getInteractiveBounds;
pub const getPaintBounds = startmenu.getPaintBounds;
pub const getHoverHighlightRepaintBounds = startmenu.getHoverHighlightRepaintBounds;
pub const updatePointerHover = startmenu.updatePointerHover;
pub const handleMenuClick = startmenu.handleMenuClick;
pub const feedSearchFromKeyboard = startmenu.feedSearchFromKeyboard;
pub const render = startmenu.render;
pub const getLeftMenuItems = startmenu.getLeftMenuItems;
pub const getRightMenuItems = startmenu.getRightMenuItems;
