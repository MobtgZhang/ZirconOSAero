// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/favorites.zig
// Purpose: Favorites management for IE browser
//
// This is an independent clean-room implementation.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");

pub const MaxFavorites = 200;
pub const MaxFolderDepth = 5;
pub const MaxFavNameLen = 128;

pub const FavoriteItem = struct {
    name: [MaxFavNameLen]u8,
    name_len: usize,
    url: [2048]u8,
    url_len: usize,
    favicon: ?u16,
    created: u64,
    visited: u64,
    folder_id: i32,
    sort_order: usize,
};

pub const FavoritesManager = struct {
    items: [MaxFavorites]FavoriteItem,
    item_count: usize,
    folders: [50]FavoritesFolder,
    folder_count: usize,
    current_sort: FavoritesSort,

    pub const FavoritesSort = enum { name, date_added, date_visited };
    pub const FavoritesFolder = struct {
        id: i32,
        name: [MaxFavNameLen]u8,
        name_len: usize,
        parent_id: i32,
        expanded: bool,
    };

    pub fn create() FavoritesManager {
        var fm = FavoritesManager{
            .items = undefined,
            .item_count = 0,
            .folders = undefined,
            .folder_count = 0,
            .current_sort = .name,
        };
        fm.initDefaultFavorites();
        return fm;
    }

    fn initDefaultFavorites(fm: *FavoritesManager) void {
        fm.addItem("ZirconOSAero Home", "zircon://home", -1);
        fm.addItem("Documentation", "zircon://docs", -1);
        fm.addItem("Settings", "zircon://settings", -1);
        fm.addFolder("Games", -1);
        fm.addItem("Minesweeper", "zircon://app/minesweeper", 0);
        fm.addItem("Solitaire", "zircon://app/solitaire", 0);
        fm.addItem("Hearts", "zircon://app/hearts", 0);
    }

    pub fn addItem(fm: *FavoritesManager, name: []const u8, url: []const u8, folder_id: i32) bool {
        if (fm.item_count >= MaxFavorites) return false;

        var item = &fm.items[fm.item_count];
        item.name_len = @min(name.len, MaxFavNameLen - 1);
        @memcpy(&item.name, name[0..item.name_len]);
        item.name[item.name_len] = 0;

        item.url_len = @min(url.len, item.url.len - 1);
        @memcpy(&item.url, url[0..item.url_len]);
        item.url[item.url_len] = 0;

        item.folder_id = folder_id;
        item.favicon = null;
        item.created = 0;
        item.visited = 0;
        item.sort_order = fm.item_count;

        fm.item_count += 1;
        return true;
    }

    pub fn removeItem(fm: *FavoritesManager, index: usize) bool {
        if (index >= fm.item_count) return false;
        fm.item_count -= 1;
        var i: usize = index;
        while (i < fm.item_count) : (i += 1) {
            fm.items[i] = fm.items[i + 1];
        }
        return true;
    }

    pub fn addFolder(fm: *FavoritesManager, name: []const u8, parent_id: i32) i32 {
        if (fm.folder_count >= fm.folders.len) return -1;
        const folder_id = @as(i32, @intCast(fm.folder_count));

        var folder = &fm.folders[fm.folder_count];
        folder.id = folder_id;
        folder.name_len = @min(name.len, MaxFavNameLen - 1);
        @memcpy(&folder.name, name[0..folder.name_len]);
        folder.name[folder.name_len] = 0;
        folder.parent_id = parent_id;
        folder.expanded = false;

        fm.folder_count += 1;
        return folder_id;
    }

    pub fn getItemsInFolder(fm: *const FavoritesManager, folder_id: i32) []const FavoriteItem {
        var count: usize = 0;
        for (fm.items[0..fm.item_count]) |*item| {
            if (item.folder_id == folder_id) count += 1;
        }

        var result: [MaxFavorites]FavoriteItem = undefined;
        var idx: usize = 0;
        for (fm.items[0..fm.item_count]) |*item| {
            if (item.folder_id == folder_id) {
                result[idx] = item.*;
                idx += 1;
            }
        }

        return result[0..idx];
    }

    pub fn findByUrl(fm: *const FavoritesManager, url: []const u8) ?*const FavoriteItem {
        for (fm.items[0..fm.item_count]) |*item| {
            if (std.mem.startsWith(u8, item.url[0..item.url_len], url)) {
                return item;
            }
        }
        return null;
    }

    pub fn renameItem(fm: *FavoritesManager, index: usize, new_name: []const u8) bool {
        if (index >= fm.item_count) return false;
        fm.items[index].name_len = @min(new_name.len, MaxFavNameLen - 1);
        @memcpy(&fm.items[index].name, new_name[0..fm.items[index].name_len]);
        fm.items[index].name[fm.items[index].name_len] = 0;
        return true;
    }

    pub fn getAllItems(fm: *const FavoritesManager) []const FavoriteItem {
        return fm.items[0..fm.item_count];
    }

    pub fn getAllFolders(fm: *const FavoritesManager) []const FavoritesFolder {
        return fm.folders[0..fm.folder_count];
    }
};
