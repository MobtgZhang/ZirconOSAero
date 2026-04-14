// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/root.zig
// Purpose: Root module for Control Panel applets
//
// This is an independent clean-room implementation.

pub const applet_base = @import("applet_base.zig");
pub const AppearanceApplet = @import("appearance.zig").AppearanceApplet;
pub const DisplayApplet = @import("display.zig").DisplayApplet;
pub const SoundsApplet = @import("sounds.zig").SoundsApplet;
pub const MouseApplet = @import("mouse.zig").MouseApplet;
pub const KeyboardApplet = @import("keyboard.zig").KeyboardApplet;
pub const RegionApplet = @import("region.zig").RegionApplet;
pub const DateTimeApplet = @import("date_time.zig").DateTimeApplet;
pub const UserAccountsApplet = @import("user_accounts.zig").UserAccountsApplet;
pub const FirewallApplet = @import("firewall.zig").FirewallApplet;
pub const ProgramsApplet = @import("programs.zig").ProgramsApplet;
pub const DefaultProgramsApplet = @import("default_programs.zig").DefaultProgramsApplet;
pub const NetworkCenterApplet = @import("network_center.zig").NetworkCenterApplet;
pub const DeviceManagerApplet = @import("device_manager.zig").DeviceManagerApplet;
pub const PowerOptionsApplet = @import("power_options.zig").PowerOptionsApplet;
pub const SystemApplet = @import("system.zig").SystemApplet;
pub const EaseOfAccessApplet = @import("ease_of_access.zig");
pub const BackupRestoreApplet = @import("backup_restore.zig");
pub const IndexingOptionsApplet = @import("indexing_options.zig");
pub const ColorManagementApplet = @import("color_management.zig");
