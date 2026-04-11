// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/cp_applets.zig
// Purpose: Control Panel applet base class and registry
//
// This is an independent clean-room implementation.

const icons_mod = @import("../../kernel/icons/root.zig");

pub const CPAppletId = enum(u16) {
    appearance = 0,
    display = 1,
    sounds = 2,
    mouse = 3,
    keyboard = 4,
    region = 5,
    date_time = 6,
    user_accounts = 7,
    firewall = 8,
    programs = 9,
    default_programs = 10,
    network_center = 11,
    device_manager = 12,
    power_options = 13,
    system = 14,
    _,
};

pub const CPApplet = struct {
    id: CPAppletId,
    name: []const u8,
    description: []const u8,
    icon: icons_mod.IconId,
    category: CPAppletCategory,
};

pub const CPAppletCategory = enum(u8) {
    system_security,
    network_internet,
    hardware_sound,
    programs,
    user_accounts,
    appearance,
    clock_region,
    ease_of_access,
    _,
};

pub const CPAppletRegistry = struct {
    applets: [32]?CPApplet,
    count: usize,

    pub fn init() CPAppletRegistry {
        var reg = CPAppletRegistry{
            .applets = [_]?CPApplet{null} ** 32,
            .count = 0,
        };
        reg.registerDefaultApplets();
        return reg;
    }

    pub fn register(reg: *CPAppletRegistry, applet: CPApplet) void {
        if (reg.count >= reg.applets.len) return;
        reg.applets[reg.count] = applet;
        reg.count += 1;
    }

    pub fn getApplet(reg: *const CPAppletRegistry, id: CPAppletId) ?*const CPApplet {
        for (reg.applets) |applet| {
            if (applet) |a| {
                if (a.id == id) return a;
            }
        }
        return null;
    }

    pub fn getByCategory(reg: *const CPAppletRegistry, cat: CPAppletCategory) []const ?CPApplet {
        _ = reg;
        _ = cat;
        return &[_]?CPApplet{};
    }

    fn registerDefaultApplets(reg: *CPAppletRegistry) void {
        reg.register(.{ .id = .appearance, .name = "Appearance and Personalization", .description = "Customize desktop background, colors, and theme", .icon = .settings, .category = .appearance });
        reg.register(.{ .id = .display, .name = "Display", .description = "Change screen resolution", .icon = .settings, .category = .appearance });
        reg.register(.{ .id = .sounds, .name = "Sound", .description = "Configure audio devices", .icon = .music, .category = .hardware_sound });
        reg.register(.{ .id = .mouse, .name = "Mouse", .description = "Configure mouse settings", .icon = .settings, .category = .hardware_sound });
        reg.register(.{ .id = .keyboard, .name = "Keyboard", .description = "Configure keyboard settings", .icon = .settings, .category = .hardware_sound });
        reg.register(.{ .id = .region, .name = "Region and Language", .description = "Set regional formats", .icon = .settings, .category = .clock_region });
        reg.register(.{ .id = .date_time, .name = "Date and Time", .description = "Set date, time, and timezone", .icon = .settings, .category = .clock_region });
        reg.register(.{ .id = .user_accounts, .name = "User Accounts", .description = "Manage user accounts and passwords", .icon = .user, .category = .user_accounts });
        reg.register(.{ .id = .firewall, .name = "Windows Firewall", .description = "Configure firewall settings", .icon = .settings, .category = .system_security });
        reg.register(.{ .id = .programs, .name = "Programs and Features", .description = "Uninstall or change programs", .icon = .settings, .category = .programs });
        reg.register(.{ .id = .default_programs, .name = "Default Programs", .description = "Set default programs", .icon = .settings, .category = .programs });
        reg.register(.{ .id = .network_center, .name = "Network and Sharing Center", .description = "View network status", .icon = .network, .category = .network_internet });
        reg.register(.{ .id = .device_manager, .name = "Device Manager", .description = "Manage hardware devices", .icon = .settings, .category = .hardware_sound });
        reg.register(.{ .id = .power_options, .name = "Power Options", .description = "Configure power settings", .icon = .settings, .category = .system_security });
        reg.register(.{ .id = .system, .name = "System", .description = "View computer information", .icon = .computer, .category = .system_security });
    }
};

var global_registry: CPAppletRegistry = undefined;
var registry_inited: bool = false;

pub fn getRegistry() *CPAppletRegistry {
    if (!registry_inited) {
        global_registry = CPAppletRegistry.init();
        registry_inited = true;
    }
    return &global_registry;
}

pub fn getAllApplets() []const CPAppletInfo {
    const reg = getRegistry();
    var infos: [32]CPAppletInfo = undefined;
    var count: usize = 0;
    for (reg.applets) |applet| {
        if (applet) |a| {
            infos[count] = .{ .name = a.name, .id = a.id };
            count += 1;
        }
    }
    return infos[0..count];
}

pub fn getSystemApplets() []const CPAppletInfo {
    return &[_]CPAppletInfo{
        .{ .id = .system, .name = "System" },
        .{ .id = .firewall, .name = "Windows Firewall" },
        .{ .id = .power_options, .name = "Power Options" },
        .{ .id = .backup_restore, .name = "Backup and Restore" },
    };
}

pub const CPAppletInfo = struct {
    id: CPAppletId,
    name: []const u8,
};

pub const backup_restore = CPAppletId.system;
