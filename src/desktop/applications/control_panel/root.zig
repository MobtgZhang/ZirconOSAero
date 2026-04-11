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
