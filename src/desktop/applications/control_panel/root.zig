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
// Module: src/desktop/applications/control_panel/root.zig
// Purpose: Control Panel with Win7 category and classic view
//
// This is an independent clean-room implementation.

pub const cp_main = @import("cp_main.zig");
pub const cp_strings = @import("cp_strings.zig");
pub const cp_applets = @import("cp_applets.zig");
pub const applets_detail = @import("applets_detail.zig");

// Re-export types
pub const ControlPanel = cp_main.ControlPanel;
pub const ControlPanelView = cp_main.ControlPanelView;
pub const CPApplet = cp_applets.CPApplet;
pub const CPAppletId = cp_applets.CPAppletId;
pub const CPAppletRegistry = cp_applets.CPAppletRegistry;

// Re-export detailed applets
pub const AppearanceApplet = applets_detail.AppearanceApplet;
pub const DisplayApplet = applets_detail.DisplayApplet;
pub const SoundApplet = applets_detail.SoundApplet;
pub const MouseApplet = applets_detail.MouseApplet;
pub const DateTimeApplet = applets_detail.DateTimeApplet;
pub const UserAccountsApplet = applets_detail.UserAccountsApplet;
pub const SystemApplet = applets_detail.SystemApplet;
pub const PowerApplet = applets_detail.PowerApplet;
pub const FirewallApplet = applets_detail.FirewallApplet;
