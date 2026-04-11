// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/tab_manager.zig
// Purpose: Multi-tab management for IE browser
//
// This is an independent clean-room implementation.

const std = @import("std");
const browser_engine = @import("browser_engine.zig");

pub const MaxTabs = 20;
pub const MaxTabTitleLen = 64;

pub const IETab = struct {
    id: u32,
    title: [MaxTabTitleLen]u8,
    title_len: usize,
    url: [2048]u8,
    url_len: usize,
    favicon: ?u16,
    is_loading: bool,
    is_active: bool,
    can_go_back: bool,
    can_go_forward: bool,
    progress: i32,
    engine: browser_engine.BrowserEngine,
    dirty: bool,

    pub fn create(tab_id: u32, vx: i32, vy: i32, vw: i32, vh: i32) IETab {
        return .{
            .id = tab_id,
            .title = undefined,
            .title_len = 0,
            .url = undefined,
            .url_len = 0,
            .favicon = null,
            .is_loading = false,
            .is_active = false,
            .can_go_back = false,
            .can_go_forward = false,
            .progress = 100,
            .engine = browser_engine.BrowserEngine.create(vx, vy, vw, vh),
            .dirty = false,
        };
    }

    pub fn setUrl(tab: *IETab, new_url: []const u8) void {
        tab.url_len = @min(new_url.len, tab.url.len - 1);
        @memcpy(&tab.url, new_url[0..tab.url_len]);
        tab.url[tab.url_len] = 0;
        tab.engine.loadUrl(new_url[0..tab.url_len]);
    }

    pub fn setTitle(tab: *IETab, new_title: []const u8) void {
        tab.title_len = @min(new_title.len, tab.title.len - 1);
        @memcpy(&tab.title, new_title[0..tab.title_len]);
        tab.title[tab.title_len] = 0;
        tab.dirty = true;
    }

    pub fn getTitle(tab: *const IETab) []const u8 {
        if (tab.title_len > 0) {
            return tab.title[0..tab.title_len];
        }
        if (tab.url_len > 0) {
            return tab.url[0..tab.url_len];
        }
        return "New Tab";
    }
};

pub const TabManager = struct {
    tabs: [MaxTabs]?IETab,
    tab_count: usize,
    active_tab_index: usize,
    next_tab_id: u32,
    scroll_offset: i32,
    hover_tab_index: isize,
    max_visible_tabs: usize,

    pub fn create() TabManager {
        return .{
            .tabs = [_]?IETab{null} ** MaxTabs,
            .tab_count = 0,
            .active_tab_index = 0,
            .next_tab_id = 1,
            .scroll_offset = 0,
            .hover_tab_index = -1,
            .max_visible_tabs = 10,
        };
    }

    pub fn createTab(tm: *TabManager, url: []const u8, vx: i32, vy: i32, vw: i32, vh: i32) ?*IETab {
        if (tm.tab_count >= MaxTabs) return null;

        const new_tab = IETab.create(tm.next_tab_id, vx, vy, vw, vh);
        tm.tabs[tm.tab_count] = new_tab;
        tm.tab_count += 1;
        tm.next_tab_id += 1;
        tm.active_tab_index = tm.tab_count - 1;

        const tab_ptr = &tm.tabs[tm.tab_count - 1].?;
        if (url.len > 0) {
            tab_ptr.setUrl(url);
        } else {
            tab_ptr.setTitle("New Tab");
        }

        return tab_ptr;
    }

    pub fn closeTab(tm: *TabManager, index: usize) bool {
        if (index >= tm.tab_count) return false;
        if (tm.tab_count == 1) return false; // Keep at least one tab

        tm.tabs[index] = null;

        // Compact tabs
        var i: usize = index;
        while (i < MaxTabs - 1) : (i += 1) {
            tm.tabs[i] = tm.tabs[i + 1];
            if (tm.tabs[i] == null) break;
        }
        tm.tabs[MaxTabs - 1] = null;
        tm.tab_count -= 1;

        // Adjust active index
        if (tm.active_tab_index >= tm.tab_count) {
            tm.active_tab_index = if (tm.tab_count > 0) tm.tab_count - 1 else 0;
        }

        return true;
    }

    pub fn setActiveTab(tm: *TabManager, index: usize) void {
        if (index >= tm.tab_count) return;

        // Deactivate current
        if (tm.active_tab_index < tm.tab_count) {
            if (tm.tabs[tm.active_tab_index]) |*tab| {
                tab.is_active = false;
            }
        }

        tm.active_tab_index = index;

        // Activate new
        if (tm.tabs[index]) |*tab| {
            tab.is_active = true;
        }
    }

    pub fn getActiveTab(tm: *TabManager) ?*IETab {
        if (tm.active_tab_index >= tm.tab_count) return null;
        return &tm.tabs[tm.active_tab_index].?;
    }

    pub fn moveTab(tm: *TabManager, from_index: usize, to_index: usize) void {
        if (from_index >= tm.tab_count or to_index >= tm.tab_count or from_index == to_index) return;

        const temp = tm.tabs[from_index];
        tm.tabs[from_index] = tm.tabs[to_index];
        tm.tabs[to_index] = temp;

        if (tm.active_tab_index == from_index) {
            tm.active_tab_index = to_index;
        } else if (tm.active_tab_index == to_index) {
            tm.active_tab_index = from_index;
        }
    }

    pub fn scrollLeft(tm: *TabManager, amount: i32) void {
        tm.scroll_offset = @max(0, tm.scroll_offset - amount);
    }

    pub fn scrollRight(tm: *TabManager, amount: i32) void {
        tm.scroll_offset += amount;
    }

    pub fn getTabAt(tm: *const TabManager, screen_x: i32, bar_x: i32, tab_width: i32) ?usize {
        const rel_x = screen_x - bar_x + tm.scroll_offset;
        if (rel_x < 0) return null;
        const tab_index = @as(usize, @intCast(@divTrunc(rel_x, tab_width + 2)));
        if (tab_index >= tm.tab_count) return null;
        return tab_index;
    }

    pub fn canScrollLeft(tm: *const TabManager, bar_width: i32, tab_width: i32) bool {
        _ = bar_width;
        _ = tab_width;
        return tm.scroll_offset > 0;
    }

    pub fn canScrollRight(tm: *const TabManager, bar_width: i32, tab_width: i32) bool {
        const total_tabs_width = @as(i32, @intCast(tm.tab_count)) * (tab_width + 2);
        const visible_end = tm.scroll_offset + bar_width;
        return visible_end < total_tabs_width;
    }

    pub fn allTabsCloseable(tm: *const TabManager) bool {
        return tm.tab_count > 1;
    }
};
