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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/root.zig
// Purpose: Internet Explorer 9 style browser with modern Chromium内核
//
// This is an independent clean-room implementation.

pub const ie_main = @import("ie_main.zig");
pub const ie_strings = @import("ie_strings.zig");
pub const browser_engine = @import("browser_engine.zig");
pub const tab_manager = @import("tab_manager.zig");
pub const favorites = @import("favorites.zig");
pub const download_manager = @import("download_manager.zig");

// Re-export types
pub const IEBrowser = ie_main.IEBrowser;
pub const IETab = ie_main.IETab;
pub const IEToolbar = ie_main.IEToolbar;
pub const IEAddressBar = ie_main.IEAddressBar;
pub const IEFavoritesBar = ie_main.IEFavoritesBar;
pub const IETabBar = ie_main.IETabBar;
pub const IEStatusBar = ie_main.IEStatusBar;

pub const BrowserEngine = browser_engine.BrowserEngine;
pub const TabManager = tab_manager.TabManager;
pub const FavoritesManager = favorites.FavoritesManager;
pub const DownloadManager = download_manager.DownloadManager;

pub const IEVersion = ie_strings.IEVersion;
pub const IEUIString = ie_strings.IEUIString;
