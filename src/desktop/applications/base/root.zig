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
// Module: src/desktop/applications/base/root.zig
// Purpose: Base application framework barrel export
//
// This is an independent clean-room implementation.

pub const window_framework = @import("window_framework.zig");
pub const controls = @import("controls.zig");
pub const layout = @import("layout.zig");
pub const app_manager = @import("app_manager.zig");

// Re-export commonly used items
pub const AppWindow = window_framework.AppWindow;
pub const AppEvent = window_framework.AppEvent;
pub const AppId = window_framework.AppId;
pub const Rect = window_framework.Rect;
pub const Point = window_framework.Point;
pub const Size = window_framework.Size;
pub const WindowStyle = window_framework.WindowStyle;

pub const Control = controls.Control;
pub const Button = controls.Button;
pub const TextField = controls.TextField;
pub const ListView = controls.ListView;
pub const ScrollBar = controls.ScrollBar;

pub const Layout = layout.Layout;
pub const BoxLayout = layout.BoxLayout;
pub const GridLayout = layout.GridLayout;
pub const BorderLayout = layout.BorderLayout;

pub const AppRegistry = app_manager.AppRegistry;
pub const registerApp = app_manager.registerApp;
pub const launchApp = app_manager.launchApp;
