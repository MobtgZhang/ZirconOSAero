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

//! Windows 7-style Start Menu (host Aero library).
//! Two-column layout: left column has pinned programs and all-programs
//! link, right column has libraries and system links.
//! Glass border, search box at bottom, user header.

const std = @import("std");
const theme = @import("theme.zig");

/// 动画状态
const AnimState = enum {
    hidden,
    opening,
    open,
    closing,
};

/// 开始菜单动画状态
var anim_state: AnimState = .hidden;
/// 动画进度：0.0（完全收起）到 1.0（完全展开）
var anim_progress: f32 = 0.0;

/// 动画持续时间（帧数，约 200ms @ 60fps）
const ANIM_FRAMES: u32 = 12;

/// 计算 ease-out 缓动曲线
fn easeOutProgress(t: f32) f32 {
    return 1.0 - (1.0 - t) * (1.0 - t);
}

/// 每帧调用以推进动画状态
pub fn updateAnimation() void {
    switch (anim_state) {
        .hidden => {},
        .opening => {
            anim_progress += 1.0 / @as(f32, @floatFromInt(ANIM_FRAMES));
            if (anim_progress >= 1.0) {
                anim_progress = 1.0;
                anim_state = .open;
                visible = true;
            }
        },
        .open => {
            visible = true;
        },
        .closing => {
            anim_progress -= 1.0 / @as(f32, @floatFromInt(ANIM_FRAMES));
            if (anim_progress <= 0.0) {
                anim_progress = 0.0;
                anim_state = .hidden;
                visible = false;
            }
        },
    }
}

/// 获取动画进度（0.0 到 1.0）
pub fn getAnimProgress() f32 {
    return anim_progress;
}

/// 菜单是否正在执行动画
pub fn isAnimating() bool {
    return anim_state == .opening or anim_state == .closing;
}

/// 菜单是否完全展开（用于交互）
pub fn isFullyOpen() bool {
    return anim_state == .open and anim_progress >= 1.0;
}

const MAX_PINNED_ITEMS: usize = 16;
const MAX_RECENT_PROGRAMS: usize = 12;
const MAX_RECENT_DOCUMENTS: usize = 16;
const MAX_SEARCH_RESULTS: usize = 20;
const MAX_RIGHT_ITEMS: usize = 16;

/// 菜单项类型
const MenuItemType = enum {
    pinned,
    recent_program,
    recent_document,
    system_link,
    search_result,
    separator,
};

/// 菜单项结构
pub const MenuItem = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    icon_id: u16 = 0,
    item_type: MenuItemType = .system_link,
    is_separator: bool = false,
    /// 用于存储目标路径/命令，比如程序路径、文档路径等
    target: [256]u8 = [_]u8{0} ** 256,
    target_len: u16 = 0,
    /// 向后兼容字段
    pub fn is_system_link(self: *const MenuItem) bool {
        return self.item_type == .system_link;
    }
};

/// 固定程序列表
var pinned_items: [MAX_PINNED_ITEMS]MenuItem = [_]MenuItem{.{}} ** MAX_PINNED_ITEMS;
var pinned_count: usize = 0;

/// 最近使用程序列表
var recent_programs: [MAX_RECENT_PROGRAMS]MenuItem = [_]MenuItem{.{}} ** MAX_RECENT_PROGRAMS;
var recent_programs_count: usize = 0;

/// 最近文档列表
var recent_documents: [MAX_RECENT_DOCUMENTS]MenuItem = [_]MenuItem{.{}} ** MAX_RECENT_DOCUMENTS;
var recent_documents_count: usize = 0;

/// 右栏系统链接
var right_items: [MAX_RIGHT_ITEMS]MenuItem = [_]MenuItem{.{}} ** MAX_RIGHT_ITEMS;
var right_count: usize = 0;

/// 搜索结果
var search_results: [MAX_SEARCH_RESULTS]MenuItem = [_]MenuItem{.{}} ** MAX_SEARCH_RESULTS;
var search_results_count: usize = 0;

var visible: bool = false;
var search_text: [128]u8 = [_]u8{0} ** 128;
var search_len: usize = 0;

/// 电源操作类型
pub const PowerAction = enum {
    shutdown,
    restart,
    sleep,
    hibernate,
    logoff,
    lock,
};

pub fn init() void {
    pinned_count = 0;
    recent_programs_count = 0;
    recent_documents_count = 0;
    right_count = 0;
    visible = false;
    search_len = 0;

    addDefaultItems();
}

fn setStr(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

/// 添加固定程序
fn addPinnedProgram(name: []const u8, icon_id: u16, target: []const u8) void {
    if (pinned_count >= MAX_PINNED_ITEMS) return;
    var item = &pinned_items[pinned_count];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.item_type = .pinned;
    item.target_len = setStr(&item.target, target);
    pinned_count += 1;
}

/// 添加系统链接到右栏
fn addRight(name: []const u8, icon_id: u16, target: []const u8) void {
    if (right_count >= MAX_RIGHT_ITEMS) return;
    var item = &right_items[right_count];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.item_type = .system_link;
    item.target_len = setStr(&item.target, target);
    right_count += 1;
}

/// 添加最近使用程序
pub fn addRecentProgram(name: []const u8, icon_id: u16, target: []const u8) void {
    // 如果程序已经存在，移动到最前面
    for (0..recent_programs_count) |i| {
        if (std.mem.eql(u8, recent_programs[i].name[0..recent_programs[i].name_len], name)) {
            // 移动到最前面
            const item = recent_programs[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                recent_programs[j] = recent_programs[j - 1];
            }
            recent_programs[0] = item;
            return;
        }
    }

    // 如果列表已满，移除最后一个
    if (recent_programs_count >= MAX_RECENT_PROGRAMS) {
        var i = MAX_RECENT_PROGRAMS - 1;
        while (i > 0) : (i -= 1) {
            recent_programs[i] = recent_programs[i - 1];
        }
        recent_programs_count -= 1;
    }

    // 插入到最前面
    var item = &recent_programs[0];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.item_type = .recent_program;
    item.target_len = setStr(&item.target, target);
    recent_programs_count += 1;
}

/// 添加最近文档
pub fn addRecentDocument(name: []const u8, icon_id: u16, target: []const u8) void {
    // 如果文档已经存在，移动到最前面
    for (0..recent_documents_count) |i| {
        if (std.mem.eql(u8, recent_documents[i].name[0..recent_documents[i].name_len], name)) {
            const item = recent_documents[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                recent_documents[j] = recent_documents[j - 1];
            }
            recent_documents[0] = item;
            return;
        }
    }

    // 如果列表已满，移除最后一个
    if (recent_documents_count >= MAX_RECENT_DOCUMENTS) {
        var i = MAX_RECENT_DOCUMENTS - 1;
        while (i > 0) : (i -= 1) {
            recent_documents[i] = recent_documents[i - 1];
        }
        recent_documents_count -= 1;
    }

    // 插入到最前面
    var item = &recent_documents[0];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.item_type = .recent_document;
    item.target_len = setStr(&item.target, target);
    recent_documents_count += 1;
}

/// 清除最近使用程序记录
pub fn clearRecentPrograms() void {
    recent_programs_count = 0;
}

/// 清除最近文档记录
pub fn clearRecentDocuments() void {
    recent_documents_count = 0;
}

pub const identity = struct {
    pub const title = "Start Menu";
    pub const search_placeholder = "Search programs and files";
    pub const header_sub = "Standard user";
    pub const shutdown_label = "Shut down";
    pub const logoff_label = "Log off";
    pub const user_name = "User";
    /// Reserved for future build stamp; keep empty so shells do not show marketing text.
    pub const version_tag = "";
    /// Optional zh-CN labels for host shells that localize the start menu
    pub const zh_title = "「开始」菜单";
    pub const zh_search = "搜索程序和文件";
};

pub const identity_zh = struct {
    pub const taskbar_props = "任务栏和「开始」菜单属性";
    pub const tab_taskbar = "任务栏";
    pub const tab_start_menu = "「开始」菜单";
    pub const tab_toolbars = "工具栏";
};

fn addDefaultItems() void {
    // 添加默认固定程序
    addPinnedProgram("Internet Explorer", 6, "C:\\Program Files\\Internet Explorer\\iexplore.exe");
    addPinnedProgram("Zircon Media Player", 11, "C:\\Windows\\System32\\wmplayer.exe");
    addPinnedProgram("Terminal", 4, "C:\\Windows\\System32\\cmd.exe");
    addPinnedProgram(".NET Shell", 4, "C:\\Windows\\System32\\powershell.exe");
    addPinnedProgram("Notepad", 9, "C:\\Windows\\System32\\notepad.exe");
    addPinnedProgram("Calculator", 8, "C:\\Windows\\System32\\calc.exe");
    addPinnedProgram("Paint", 10, "C:\\Windows\\System32\\mspaint.exe");
    addPinnedProgram("Registry Editor", 7, "C:\\Windows\\System32\\regedit.exe");
    // 与内核 `startmenu.zig` / `builtin_apps.zig` 左列顺序对齐；点击行为在帧缓冲 Shell 中实现。

    // 添加右栏系统链接
    addRight("Documents", 2, "shell:Documents");
    addRight("Pictures", 10, "shell:Pictures");
    addRight("Music", 11, "shell:Music");
    addRight("Videos", 12, "shell:Videos");
    addRight("Downloads", 28, "shell:Downloads");
    addRight("Games", 12, "shell:Games");
    addRight("Computer", 1, "shell:MyComputer");
    addRight("Network", 5, "shell:NetworkPlaces");
    addRight("Control Panel", 13, "shell:ControlPanel");
    addRight("Devices and Printers", 22, "shell:Printers");
    addRight("Default Programs", 7, "shell:DefaultPrograms");
    addRight("Help and Support", 7, "shell:Help");
    addRight("Run...", 4, "shell:Run");
}

pub fn toggle() void {
    // 完整状态机：处理所有动画状态，防止任何混乱
    switch (anim_state) {
        .closing => {
            // 正在关闭中，忽略此次 toggle（防止动画混乱）
            return;
        },
        .opening => {
            // 正在展开中，停止展开动画，开始反向关闭
            hide();
            return;
        },
        .open => {
            // 已展开，关闭
            hide();
            return;
        },
        .hidden => {
            // 隐藏状态，打开
            show();
            return;
        },
    }
}

pub fn show() void {
    // 如果正在关闭，立即停止关闭并反向展开
    if (anim_state == .closing) {
        // 反转动画方向：将关闭进度翻转为展开进度
        anim_progress = 1.0 - anim_progress;
        anim_state = .opening;
        visible = true;
        return;
    }
    // 正在展开中或已展开：忽略（防止参数被覆盖导致视觉抖动）
    if (anim_state == .opening or anim_state == .open) {
        return;
    }
    // hidden：从头开始展开
    visible = true;
    anim_state = .opening;
    anim_progress = 0.0;
}

pub fn hide() void {
    // 如果正在展开，立即停止展开并反向关闭
    if (anim_state == .opening) {
        // 反转动画方向：将展开进度翻转为关闭进度
        anim_progress = 1.0 - anim_progress;
        anim_state = .closing;
        return;
    }
    // 如果已展开：启动关闭
    if (anim_state == .open) {
        anim_state = .closing;
        anim_progress = 1.0;
        search_len = 0;
        return;
    }
    // 正在关闭中或已隐藏：忽略
    // 正在关闭中时不做任何操作（保持关闭进度继续）
    // hidden 时不做任何操作
    search_len = 0;
}

pub fn isVisible() bool {
    // 关键修复：只在 hidden 状态返回 false，与内核 kernel/startmenu.zig 保持一致
    // 原错误：使用 visible 变量判断，visible 可能在动画过程中为 false
    // 现在：直接判断状态机状态，opening/closing/open 均视为可见
    return anim_state != .hidden;
}

pub fn contains(screen_h: i32, x: i32, y: i32) bool {
    // 关键修复：只在完全 hidden 时认为菜单不可交互
    // 在 opening/closing/open 状态下，菜单都在视觉上存在，必须正确响应点击
    if (anim_state == .hidden) return false;
    const menu_h = theme.Layout.startmenu_height;
    const menu_w = theme.Layout.startmenu_width;
    const taskbar_h = theme.Layout.taskbar_height;
    const menu_y = screen_h - taskbar_h - menu_h;

    return x >= 0 and x < menu_w and y >= menu_y and y < menu_y + menu_h;
}

/// 获取固定程序列表
pub fn getPinnedItems() []const MenuItem {
    return pinned_items[0..pinned_count];
}

/// 获取最近使用程序列表
pub fn getRecentPrograms() []const MenuItem {
    return recent_programs[0..recent_programs_count];
}

/// 获取最近文档列表
pub fn getRecentDocuments() []const MenuItem {
    return recent_documents[0..recent_documents_count];
}

/// 获取右栏系统链接列表
pub fn getRightItems() []const MenuItem {
    return right_items[0..right_count];
}

/// 获取搜索结果列表
pub fn getSearchResults() []const MenuItem {
    return search_results[0..search_results_count];
}

/// 向后兼容：返回左栏所有项目（固定程序 + 最近程序）
pub fn getLeftItems() []const MenuItem {
    // 合并固定程序和最近程序到临时缓冲区返回，用于向后兼容
    // 实际渲染层应该分别调用getPinnedItems和getRecentPrograms
    var temp: [MAX_PINNED_ITEMS + MAX_RECENT_PROGRAMS]MenuItem = undefined;
    var count: usize = 0;
    for (pinned_items[0..pinned_count]) |item| {
        temp[count] = item;
        count += 1;
    }
    for (recent_programs[0..recent_programs_count]) |item| {
        temp[count] = item;
        count += 1;
    }
    return temp[0..count];
}

pub fn getBackgroundColor() u32 {
    return theme.menu_bg;
}

pub fn getRightPanelColor() u32 {
    return theme.menu_right_bg;
}

pub fn getGlassBorderColor() u32 {
    return theme.menu_glass_border;
}

pub fn getTextColor() u32 {
    return theme.menu_text;
}

pub fn getHoverColor() u32 {
    return theme.menu_hover_bg;
}

pub fn getSeparatorColor() u32 {
    return theme.menu_separator;
}

pub fn getSearchPlaceholder() []const u8 {
    return identity.search_placeholder;
}

pub fn getUserName() []const u8 {
    return identity.user_name;
}

pub fn getUserSubtitle() []const u8 {
    return identity.header_sub;
}

/// 处理搜索键盘输入
pub fn handleSearchInput(c: u8) void {
    if (anim_state != .open) return;

    // 处理退格
    if (c == '\x08') {
        if (search_len > 0) {
            search_len -= 1;
            search_text[search_len] = 0;
            updateSearchResults();
        }
        return;
    }

    // 处理回车
    if (c == '\r' or c == '\n') {
        if (search_results_count > 0) {
            // 默认打开第一个搜索结果
            executeItem(&search_results[0]);
        }
        hide();
        return;
    }

    // 处理ESC退出
    if (c == 0x1B) {
        hide();
        return;
    }

    // 只处理可打印字符
    if (c >= 32 and c <= 126 and search_len < search_text.len - 1) {
        search_text[search_len] = c;
        search_len += 1;
        search_text[search_len] = 0;
        updateSearchResults();
    }
}

/// 更新搜索结果
fn updateSearchResults() void {
    search_results_count = 0;

    // 如果搜索框为空，清空结果
    if (search_len == 0) {
        return;
    }

    const query = search_text[0..search_len];

    // 搜索固定程序
    for (pinned_items[0..pinned_count]) |item| {
        if (matchSearchQuery(item.name[0..item.name_len], query)) {
            addSearchResult(item.name[0..item.name_len], item.icon_id, item.target[0..item.target_len], .search_result);
        }
    }

    // 搜索最近程序
    for (recent_programs[0..recent_programs_count]) |item| {
        if (matchSearchQuery(item.name[0..item.name_len], query)) {
            addSearchResult(item.name[0..item.name_len], item.icon_id, item.target[0..item.target_len], .search_result);
        }
    }

    // 搜索最近文档
    for (recent_documents[0..recent_documents_count]) |item| {
        if (matchSearchQuery(item.name[0..item.name_len], query)) {
            addSearchResult(item.name[0..item.name_len], item.icon_id, item.target[0..item.target_len], .search_result);
        }
    }

    // 搜索右栏系统链接
    for (right_items[0..right_count]) |item| {
        if (matchSearchQuery(item.name[0..item.name_len], query)) {
            addSearchResult(item.name[0..item.name_len], item.icon_id, item.target[0..item.target_len], .search_result);
        }
    }

    // 添加系统命令匹配
    if (matchSearchQuery("Run", query)) {
        addSearchResult("Run", 4, "shell:Run", .system_link);
    }
    if (matchSearchQuery("Cmd", query) or matchSearchQuery("Command Prompt", query)) {
        addSearchResult("Command Prompt", 4, "C:\\Windows\\System32\\cmd.exe", .search_result);
    }
    if (matchSearchQuery("PowerShell", query)) {
        addSearchResult("Windows PowerShell", 4, "C:\\Windows\\System32\\powershell.exe", .search_result);
    }
    if (matchSearchQuery("Regedit", query) or matchSearchQuery("Registry Editor", query)) {
        addSearchResult("Registry Editor", 7, "C:\\Windows\\System32\\regedit.exe", .search_result);
    }
    if (matchSearchQuery("Calc", query) or matchSearchQuery("Calculator", query)) {
        addSearchResult("Calculator", 8, "C:\\Windows\\System32\\calc.exe", .search_result);
    }
    if (matchSearchQuery("Notepad", query)) {
        addSearchResult("Notepad", 9, "C:\\Windows\\System32\\notepad.exe", .search_result);
    }
    if (matchSearchQuery("Paint", query) or matchSearchQuery("Mspaint", query)) {
        addSearchResult("Paint", 10, "C:\\Windows\\System32\\mspaint.exe", .search_result);
    }
}

/// 搜索匹配逻辑：不区分大小写，支持前缀匹配和包含匹配
fn matchSearchQuery(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return false;
    if (text.len < query.len) return false;

    var i: usize = 0;
    while (i <= text.len - query.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < query.len) : (j += 1) {
            const c1 = toLower(text[i + j]);
            const c2 = toLower(query[j]);
            if (c1 != c2) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }

    return false;
}

/// 字符转小写
fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') {
        return c + ('a' - 'A');
    }
    return c;
}

/// 添加搜索结果
fn addSearchResult(name: []const u8, icon_id: u16, target: []const u8, item_type: MenuItemType) void {
    if (search_results_count >= MAX_SEARCH_RESULTS) return;

    // 避免重复结果
    for (0..search_results_count) |i| {
        if (std.mem.eql(u8, search_results[i].name[0..search_results[i].name_len], name)) {
            return;
        }
    }

    var item = &search_results[search_results_count];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.item_type = item_type;
    item.target_len = setStr(&item.target, target);
    search_results_count += 1;
}

/// 执行菜单项对应的操作
pub fn executeItem(item: *const MenuItem) void {
    if (item.target_len == 0) return;

    const target = item.target[0..item.target_len];

    // 处理电源操作
    if (std.mem.eql(u8, target, "power:shutdown")) {
        executePowerAction(.shutdown);
        return;
    }
    if (std.mem.eql(u8, target, "power:restart")) {
        executePowerAction(.restart);
        return;
    }
    if (std.mem.eql(u8, target, "power:sleep")) {
        executePowerAction(.sleep);
        return;
    }
    if (std.mem.eql(u8, target, "power:hibernate")) {
        executePowerAction(.hibernate);
        return;
    }
    if (std.mem.eql(u8, target, "power:logoff")) {
        executePowerAction(.logoff);
        return;
    }
    if (std.mem.eql(u8, target, "power:lock")) {
        executePowerAction(.lock);
        return;
    }

    // 其他目标交给上层shell处理执行
    // 这里可以添加扩展逻辑，比如shell:协议处理、程序启动等
}

/// 执行电源操作
fn executePowerAction(action: PowerAction) void {
    // 上层shell需要注册电源操作回调来处理实际电源控制
    // 这里只做通知，实际实现由系统层完成
    switch (action) {
        .shutdown => {
            // 发送关机信号到内核
        },
        .restart => {
            // 发送重启信号到内核
        },
        .sleep => {
            // 发送睡眠信号到内核
        },
        .hibernate => {
            // 发送休眠信号到内核
        },
        .logoff => {
            // 注销当前用户
        },
        .lock => {
            // 锁定工作站
        },
    }

    hide();
}

/// 获取电源操作列表，用于渲染电源按钮和子菜单
pub fn getPowerActions() []const struct { name: []const u8, icon_id: u16, action: PowerAction } {
    const power_actions = [_]struct { name: []const u8, icon_id: u16, action: PowerAction }{
        .{ .name = "Shut down", .icon_id = 17, .action = .shutdown },
        .{ .name = "Restart", .icon_id = 17, .action = .restart },
        .{ .name = "Sleep", .icon_id = 17, .action = .sleep },
        .{ .name = "Hibernate", .icon_id = 17, .action = .hibernate },
        .{ .name = "Log off", .icon_id = 16, .action = .logoff },
        .{ .name = "Lock", .icon_id = 16, .action = .lock },
    };
    return &power_actions;
}
