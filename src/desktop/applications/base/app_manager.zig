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
// Module: src/desktop/applications/base/app_manager.zig
// Purpose: Application registry and launcher
//
// This is an independent clean-room implementation.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const builtin_apps = @import("../../kernel/shell/builtin_apps.zig");

pub const AppId = enum(u16) {
    unknown = 0,
    ie_browser = 1,
    control_panel = 2,
    notepad = 3,
    calculator = 4,
    paint = 5,
    minesweeper = 6,
    solitaire = 7,
    hearts = 8,
    chess_titans = 9,
    snipping_tool = 10,
    wordpad = 11,
    task_manager = 12,
    command_prompt = 13,
    powershell = 14,
    explorer = 15,
    settings = 16,
    char_map = 17,
    on_screen_keyboard = 18,
    magnifier = 19,
    sound_recorder = 20,
    media_player = 21,
    games_folder = 22,
    system_info = 23,
    device_manager = 24,
    disk_cleanup = 25,
    disk_defrag = 26,
    event_viewer = 27,
    local_group_policy = 28,
    services = 29,
    component_services = 30,
    computer_management = 31,
    system_restore = 32,
    task_scheduler = 33,
    performance_monitor = 34,
    resource_monitor = 35,
    registry_editor = 36,
    windows_update = 37,
    firewall = 38,
    security_center = 39,
    backup_restore = 40,
    spider_solitaire = 41,
    freecell = 42,
    mahjong_titans = 43,
    purble_place = 44,
    sticky_notes = 45,
    inkball = 46,
    photo_gallery = 47,
    psr = 48,
    _,
};

pub const AppInfo = struct {
    id: AppId,
    name: [:0]const u8,
    description: [:0]const u8,
    icon_id: u16,
    category: AppCategory,
    shortcut_path: [:0]const u8,
    executable_path: [:0]const u8,
    arguments: [:0]const u8,
    launched: bool,
};

pub const AppCategory = enum(u8) {
    internet,
    system,
    accessories,
    games,
    entertainment,
    maintenance,
    security,
    _,
};

/// Map AppId to builtin_apps.BuiltinAppId for actual execution
fn toBuiltinId(id: AppId) builtin_apps.BuiltinAppId {
    return switch (id) {
        .notepad => .notepad,
        .wordpad => .wordpad,
        .paint => .paint,
        .calculator => .calculator,
        .snipping_tool => .snipping_tool,
        .magnifier => .magnifier,
        .osk => .osk,
        .char_map => .charmap,
        .sound_recorder => .sound_recorder,
        .media_player => .wmp,
        .ie_browser => .ie8,
        .control_panel => .control_panel,
        .minesweeper => .minesweeper,
        .solitaire => .solitaire,
        .spider_solitaire => .spider_solitaire,
        .freecell => .freecell,
        .hearts => .hearts,
        .chess_titans => .chess_titans,
        .mahjong_titans => .mahjong_titans,
        .purble_place => .purble_place,
        .cmd_shell => .cmd_shell,
        .sticky_notes => .sticky_notes_window,
        .inkball => .inkball,
        .photo_gallery => .photo_gallery,
        .psr => .psr,
        .registry_editor => .regedit,
        .disk_cleanup => .disk_cleanup,
        .disk_defrag => .defrag,
        .backup_restore => .backup_restore,
        .system_restore => .system_restore,
        .event_viewer => .eventvwr,
        .device_manager => .devmgmt,
        .computer_management => .compmgmt,
        .resource_monitor => .resmon,
        .performance_monitor => .perfmon,
        .task_scheduler => .taskschd,
        .services => .dotnet_shell_host,
        .firewall => .firewall,
        .windows_update => .windows_update,
        .defender => .defender,
        .games_folder => .games_folder,
        .explorer => .shell_documents,
        .shell_documents => .shell_documents,
        .shell_pictures => .shell_pictures,
        .shell_music => .shell_music,
        .shell_videos => .shell_videos,
        .shell_downloads => .shell_downloads,
        .shell_computer => .shell_computer,
        .shell_network => .shell_network,
        .shell_devices_printers => .shell_devices_printers,
        .shell_default_programs => .shell_default_programs,
        .shell_help => .shell_help,
        .run_dialog => .shell_run,
        else => .generic_stub,
    };
}

pub const AppWindowHandle = struct {
    app_id: AppId,
    slot_index: usize,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
};

pub const AppRegistry = struct {
    apps: [64]?AppInfo,
    app_count: usize,
    launched_apps: [16]AppId,
    launched_count: usize,
    category_cache: [8][]const AppId,
    cache_valid: bool,

    pub fn init() AppRegistry {
        var registry = AppRegistry{
            .apps = [_]?AppInfo{null} ** 64,
            .app_count = 0,
            .launched_apps = [_]AppId{.unknown} ** 16,
            .launched_count = 0,
            .category_cache = undefined,
            .cache_valid = false,
        };
        registry.registerDefaultApps();
        return registry;
    }

    pub fn registerApp(r: *AppRegistry, info: AppInfo) void {
        if (r.app_count >= r.apps.len) return;
        r.apps[r.app_count] = info;
        r.app_count += 1;
        r.cache_valid = false;
    }

    pub fn getApp(r: *const AppRegistry, id: AppId) ?*const AppInfo {
        for (r.apps[0..r.app_count]) |app| {
            if (app) |a| {
                if (a.id == id) return a;
            }
        }
        return null;
    }

    pub fn getAppsByCategory(r: *AppRegistry, category: AppCategory) []const AppId {
        r.buildCategoryCache();
        return switch (category) {
            .internet => r.category_cache[0],
            .system => r.category_cache[1],
            .accessories => r.category_cache[2],
            .games => r.category_cache[3],
            .entertainment => r.category_cache[4],
            .maintenance => r.category_cache[5],
            .security => r.category_cache[6],
            else => &.{},
        };
    }

    fn buildCategoryCache(r: *AppRegistry) void {
        if (r.cache_valid) return;
        r.cache_valid = true;

        var internet_count: usize = 0;
        var system_count: usize = 0;
        var accessories_count: usize = 0;
        var games_count: usize = 0;
        var entertainment_count: usize = 0;
        var maintenance_count: usize = 0;
        var security_count: usize = 0;

        for (r.apps[0..r.app_count]) |app_opt| {
            if (app_opt) |app| {
                switch (app.category) {
                    .internet => internet_count += 1,
                    .system => system_count += 1,
                    .accessories => accessories_count += 1,
                    .games => games_count += 1,
                    .entertainment => entertainment_count += 1,
                    .maintenance => maintenance_count += 1,
                    .security => security_count += 1,
                    else => {},
                }
            }
        }

        var internet_buf: [32]AppId = undefined;
        var system_buf: [32]AppId = undefined;
        var accessories_buf: [32]AppId = undefined;
        var games_buf: [32]AppId = undefined;
        var entertainment_buf: [32]AppId = undefined;
        var maintenance_buf: [32]AppId = undefined;
        var security_buf: [32]AppId = undefined;

        var internet_idx: usize = 0;
        var system_idx: usize = 0;
        var accessories_idx: usize = 0;
        var games_idx: usize = 0;
        var entertainment_idx: usize = 0;
        var maintenance_idx: usize = 0;
        var security_idx: usize = 0;

        for (r.apps[0..r.app_count]) |app_opt| {
            if (app_opt) |app| {
                switch (app.category) {
                    .internet => {
                        if (internet_idx < internet_buf.len) {
                            internet_buf[internet_idx] = app.id;
                            internet_idx += 1;
                        }
                    },
                    .system => {
                        if (system_idx < system_buf.len) {
                            system_buf[system_idx] = app.id;
                            system_idx += 1;
                        }
                    },
                    .accessories => {
                        if (accessories_idx < accessories_buf.len) {
                            accessories_buf[accessories_idx] = app.id;
                            accessories_idx += 1;
                        }
                    },
                    .games => {
                        if (games_idx < games_buf.len) {
                            games_buf[games_idx] = app.id;
                            games_idx += 1;
                        }
                    },
                    .entertainment => {
                        if (entertainment_idx < entertainment_buf.len) {
                            entertainment_buf[entertainment_idx] = app.id;
                            entertainment_idx += 1;
                        }
                    },
                    .maintenance => {
                        if (maintenance_idx < maintenance_buf.len) {
                            maintenance_buf[maintenance_idx] = app.id;
                            maintenance_idx += 1;
                        }
                    },
                    .security => {
                        if (security_idx < security_buf.len) {
                            security_buf[security_idx] = app.id;
                            security_idx += 1;
                        }
                    },
                    else => {},
                }
            }
        }

        r.category_cache[0] = internet_buf[0..internet_idx];
        r.category_cache[1] = system_buf[0..system_idx];
        r.category_cache[2] = accessories_buf[0..accessories_idx];
        r.category_cache[3] = games_buf[0..games_idx];
        r.category_cache[4] = entertainment_buf[0..entertainment_idx];
        r.category_cache[5] = maintenance_buf[0..maintenance_idx];
        r.category_cache[6] = security_buf[0..security_idx];
    }

    pub fn launch(r: *AppRegistry, id: AppId) void {
        // Shift launched apps if at capacity
        if (r.launched_count >= r.launched_apps.len) {
            var s: usize = 0;
            while (s < r.launched_count - 1) : (s += 1) {
                r.launched_apps[s] = r.launched_apps[s + 1];
            }
            r.launched_count -= 1;
        }
        r.launched_apps[r.launched_count] = id;
        r.launched_count += 1;

        // Mark app as launched in registry
        if (r.getApp(id)) |app| {
            const mut_app = @constCast(app);
            mut_app.launched = true;
            klog.info("app_manager: launching '%s' (id={d})", .{ app.name, @intFromEnum(id) });
        } else {
            klog.info("app_manager: unknown app id={d}", .{@intFromEnum(id)});
        }

        // Execute via builtin_apps.launch()
        const builtin_id = toBuiltinId(id);
        builtin_apps.launch(builtin_id);
    }

    pub fn launchWithArgs(r: *AppRegistry, id: AppId, args: []const u8) void {
        if (r.getApp(id)) |app| {
            klog.info("app_manager: launching '%s' with args '%s'", .{ app.name, args });
        }
        builtin_apps.launch(toBuiltinId(id));
    }

    pub fn isRunning(r: *const AppRegistry, id: AppId) bool {
        for (r.launched_apps[0..r.launched_count]) |app_id| {
            if (app_id == id) return true;
        }
        return false;
    }

    pub fn getRunningApps(r: *const AppRegistry) []const AppId {
        return r.launched_apps[0..r.launched_count];
    }

    pub fn close(r: *AppRegistry, id: AppId) void {
        var i: usize = 0;
        while (i < r.launched_count) {
            if (r.launched_apps[i] == id) {
                var s: usize = i;
                while (s < r.launched_count - 1) : (s += 1) {
                    r.launched_apps[s] = r.launched_apps[s + 1];
                }
                r.launched_count -= 1;

                // Mark app as not launched
                if (r.getApp(id)) |app| {
                    const mut_app = @constCast(app);
                    mut_app.launched = false;
                }

                klog.info("app_manager: closed app id={d}", .{@intFromEnum(id)});
                return;
            }
            i += 1;
        }
    }

    pub fn bringToFront(r: *AppRegistry, id: AppId) void {
        // Move the specified app to the end of the launched list (top of z-order)
        var i: usize = 0;
        while (i < r.launched_count) {
            if (r.launched_apps[i] == id) {
                const app_id = r.launched_apps[i];
                var s: usize = i;
                while (s < r.launched_count - 1) : (s += 1) {
                    r.launched_apps[s] = r.launched_apps[s + 1];
                }
                r.launched_apps[r.launched_count - 1] = app_id;
                klog.info("app_manager: bring to front id={d}", .{@intFromEnum(id)});
                return;
            }
            i += 1;
        }
    }

    fn registerDefaultApps(r: *AppRegistry) void {
        r.registerApp(.{ .id = .ie_browser, .name = "Internet Explorer", .description = "Browse the web", .icon_id = 6, .category = .internet, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .control_panel, .name = "Control Panel", .description = "System settings", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .notepad, .name = "Notepad", .description = "Text editor", .icon_id = 9, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .calculator, .name = "Calculator", .description = "Perform calculations", .icon_id = 8, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .paint, .name = "Paint", .description = "Image editor", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .minesweeper, .name = "Minesweeper", .description = "Clear the minefield", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .solitaire, .name = "Solitaire", .description = "Classic card game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .spider_solitaire, .name = "Spider Solitaire", .description = "Spider card game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .freecell, .name = "FreeCell", .description = "FreeCell card game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .hearts, .name = "Hearts", .description = "Card game for 4 players", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .chess_titans, .name = "Chess Titans", .description = "3D chess game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .mahjong_titans, .name = "Mahjong Titans", .description = "Mahjong tile game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .purble_place, .name = "Purble Place", .description = "Kids puzzle game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .snipping_tool, .name = "Snipping Tool", .description = "Capture screen shots", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .wordpad, .name = "WordPad", .description = "Rich text editor", .icon_id = 9, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .task_manager, .name = "Task Manager", .description = "Manage running applications", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .command_prompt, .name = "Command Prompt", .description = "Command line interface", .icon_id = 4, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .explorer, .name = "Windows Explorer", .description = "File manager", .icon_id = 2, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .char_map, .name = "Character Map", .description = "Special character picker", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .on_screen_keyboard, .name = "On-Screen Keyboard", .description = "Virtual keyboard", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .magnifier, .name = "Magnifier", .description = "Screen magnification", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .sound_recorder, .name = "Sound Recorder", .description = "Audio recording", .icon_id = 1, .category = .entertainment, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .media_player, .name = "Windows Media Player", .description = "Media playback", .icon_id = 1, .category = .entertainment, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .games_folder, .name = "Games", .description = "Game explorer", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .system_info, .name = "System Information", .description = "System details", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .device_manager, .name = "Device Manager", .description = "Hardware management", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .disk_cleanup, .name = "Disk Cleanup", .description = "Free disk space", .icon_id = 7, .category = .maintenance, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .disk_defrag, .name = "Disk Defragmenter", .description = "Optimize disk", .icon_id = 7, .category = .maintenance, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .event_viewer, .name = "Event Viewer", .description = "System events log", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .computer_management, .name = "Computer Management", .description = "System administration", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .registry_editor, .name = "Registry Editor", .description = "Registry configuration", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .firewall, .name = "Windows Firewall", .description = "Firewall settings", .icon_id = 7, .category = .security, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .services, .name = "Services", .description = "Service management", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .performance_monitor, .name = "Performance Monitor", .description = "System performance", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .resource_monitor, .name = "Resource Monitor", .description = "Resource usage", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .task_scheduler, .name = "Task Scheduler", .description = "Scheduled tasks", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .system_restore, .name = "System Restore", .description = "Restore system", .icon_id = 7, .category = .maintenance, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .backup_restore, .name = "Backup and Restore", .description = "Backup management", .icon_id = 7, .category = .maintenance, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .windows_update, .name = "Windows Update", .description = "Update system", .icon_id = 7, .category = .system, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .security_center, .name = "Security Center", .description = "Security settings", .icon_id = 7, .category = .security, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .sticky_notes, .name = "Sticky Notes", .description = "Post-it notes on desktop", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .inkball, .name = "InkBall", .description = "Path drawing game", .icon_id = 1, .category = .games, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .photo_gallery, .name = "Photo Gallery", .description = "Browse and manage photos", .icon_id = 10, .category = .entertainment, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
        r.registerApp(.{ .id = .psr, .name = "Problem Steps Recorder", .description = "Record screen steps", .icon_id = 1, .category = .accessories, .shortcut_path = "", .executable_path = "", .arguments = "", .launched = false });
    }
};

var global_registry: AppRegistry = undefined;
var registry_initialized: bool = false;

pub fn getRegistry() *AppRegistry {
    if (!registry_initialized) {
        global_registry = AppRegistry.init();
        registry_initialized = true;
    }
    return &global_registry;
}

pub fn registerApp(info: AppInfo) void {
    getRegistry().registerApp(info);
}

pub fn launchApp(id: AppId) void {
    getRegistry().launch(id);
}

pub fn launchAppWithArgs(id: AppId, args: []const u8) void {
    getRegistry().launchWithArgs(id, args);
}

pub fn isAppRunning(id: AppId) bool {
    return getRegistry().isRunning(id);
}

pub fn closeApp(id: AppId) void {
    getRegistry().close(id);
}

pub fn bringAppToFront(id: AppId) void {
    getRegistry().bringToFront(id);
}

pub fn getAppInfo(id: AppId) ?*const AppInfo {
    return getRegistry().getApp(id);
}

pub fn getAppsByCategory(category: AppCategory) []const AppId {
    return getRegistry().getAppsByCategory(category);
}

pub fn getRunningApps() []const AppId {
    return getRegistry().getRunningApps();
}
