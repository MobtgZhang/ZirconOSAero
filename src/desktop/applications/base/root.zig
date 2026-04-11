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
