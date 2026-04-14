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

//! Shell UI strings — English default.

const shell_mui = @import("shell_mui.zig");

pub const LangId = shell_mui.LangId;
pub var active_lang = shell_mui.active_lang;
pub fn setActiveLang(id: LangId) void {
    shell_mui.setLangFromConfig();
    _ = id;
}
pub const en = struct {
    pub const w2k_title_c_drive = "Local Disk (C:)";
    pub const w2k_addr_c_drive = "Local Disk (C:)";

    pub const explorer_menu = [_][]const u8{
        "File(F)", "Edit(E)", "View(V)", "Favorites(A)", "Tools(T)", "Help(H)",
    };
    pub const explorer_tools = [_][]const u8{
        "Back", "Forward", "Up", "Search", "Folders", "History",
    };
    pub const address_label = "Address(D)";
    pub const go = "Go";

    pub const file_viewer_title = "ZirconOS File Viewer";
    pub const file_label = "File:";
    pub const location_label = "Location:";
    pub const file_page_note = "(Kernel shell preview — NT-compatible binaries)";
    pub const file_page_hint = "Use the toolbar Back / Up or the link below to return.";
    pub const back_to_list = "<< Back to folder list";

    pub const folder_pane_title = "Folders";
    pub const tree_desktop = "Desktop";
    pub const tree_my_documents = "My Documents";
    pub const tree_my_computer = "My Computer";
    pub const tree_local_disk_c = "Local Disk (C:)";

    pub const col_name = "Name";
    pub const col_size = "Size";
    pub const col_type = "Type";

    pub const status_c_drive = "3 objects (2 hidden) (Free space: 21.9 GB)";
    pub const status_zero_bytes = "0 bytes";
    pub const status_my_computer = "My Computer";
    pub const status_file_props = "File properties preview";

    pub const ex_lib_title = "Libraries";
    pub const ex_lib_subtitle = "Use this folder to access your libraries.";
    pub const ex_lib_search = "Search Libraries";
    pub const ex_lib_organize = "Organize";
    pub const ex_lib_new_lib = "New library";
    pub const ex_lib_nav_fav = "Favorites";
    pub const ex_lib_nav_lib = "Libraries";
    pub const ex_lib_nav_comp = "Computer";
    pub const ex_lib_nav_net = "Network";
    pub const ex_lib_desktop = "Desktop";
    pub const ex_lib_downloads = "Downloads";
    pub const ex_lib_recent = "Recent places";
    pub const ex_lib_documents = "Documents";
    pub const ex_lib_music = "Music";
    pub const ex_lib_pictures = "Pictures";
    pub const ex_lib_videos = "Videos";
    pub const ex_lib_status = "4 items";
    pub const ex_lib_disk_c = "Local Disk (C:)";
    pub const ex_lib_dvd = "DVD Drive (G:)";

    pub const ex_addr_computer = "Computer";
    pub const ex_grp_hard_disks = "Hard disk drives";
    pub const ex_grp_removable = "Devices with removable storage";
    pub const ex_cmp_address = "Address";
    pub const ex_cmp_go = "Go";
    pub const ex_cmp_organize = "Organize";
    pub const ex_cmp_open = "Open";
    pub const ex_cmp_more = "▼";
    pub const ex_cmp_include_lib = "Include in library";
    pub const ex_cmp_share_with = "Share with";
    pub const ex_col_date_modified = "Date modified";
    pub const ex_pc_dvd_fmt = "DVD RW Drive ({c}:)";
    pub const ex_pc_free_fmt = "{d} GB free of {d} GB";
    pub const ex_expl_empty_list = "Choose a drive in the navigation pane.";
    pub const ex_status_brand = "Aero DWM";
    pub const ex_status_items_fmt = "{d} items | {s} | {s}";
};

pub const zh_cn_explorer = struct {
    pub const col_name = "名称";
    pub const col_size = "大小";
    pub const ex_lib_title = "库";
    pub const ex_lib_subtitle = "使用此文件夹访问您的库。";
    pub const ex_lib_search = "搜索库";
    pub const ex_lib_organize = "组织";
    pub const ex_lib_new_lib = "新建库";
    pub const ex_lib_nav_fav = "收藏夹";
    pub const ex_lib_nav_lib = "库";
    pub const ex_lib_nav_comp = "计算机";
    pub const ex_lib_nav_net = "网络";
    pub const ex_lib_desktop = "桌面";
    pub const ex_lib_downloads = "下载";
    pub const ex_lib_recent = "最近访问的位置";
    pub const ex_lib_documents = "文档";
    pub const ex_lib_music = "音乐";
    pub const ex_lib_pictures = "图片";
    pub const ex_lib_videos = "视频";
    pub const ex_lib_status = "4 个对象";
    pub const ex_lib_disk_c = "本地磁盘 (C:)";
    pub const ex_lib_dvd = "DVD 驱动器 (G:)";

    pub const ex_addr_computer = "计算机";
    pub const ex_grp_hard_disks = "硬盘驱动器";
    pub const ex_grp_removable = "有可移动存储的设备";
    pub const ex_cmp_address = "地址";
    pub const ex_cmp_go = "转到";
    pub const ex_cmp_organize = "组织";
    pub const ex_cmp_open = "打开";
    pub const ex_cmp_more = "▼";
    pub const ex_cmp_include_lib = "包含到库中";
    pub const ex_cmp_share_with = "共享给";
    pub const ex_col_date_modified = "修改日期";
    pub const ex_pc_dvd_fmt = "DVD RW 驱动器 ({c}:)";
    pub const ex_pc_free_fmt = "可用 {d} GB，共 {d} GB";
    pub const ex_expl_empty_list = "请在导航窗格中选择一个驱动器。";
    pub const ex_status_brand = "Aero DWM";
    pub const ex_status_items_fmt = "{d} 个项目 | {s} | {s}";
};

pub const en_startmenu = struct {
    pub const user_name = "User";
    pub const account_subtitle = "Standard user";
    pub const search_placeholder = "Search programs and files";
    pub const all_programs = "All Programs";
    pub const foot_log_off = "Log off";
    pub const foot_sleep = "Sleep";
    pub const foot_restart = "Restart";
    pub const foot_shut_down = "Shut down";
    pub const fly_switch_user = "Switch user";
    pub const fly_log_off = "Log off";
    pub const fly_lock = "Lock";
    pub const fly_restart = "Restart";
    pub const fly_sleep = "Sleep";
    pub const fly_hibernate = "Hibernate";
    pub const fly_shut_down = "Shut down";
    pub const all_prog_stub_accessories = "Accessories";
    pub const all_prog_stub_games = "Games";
    pub const all_prog_stub_system = "System Tools";
    pub const all_prog_stub_startup = "Startup";
    pub const all_prog_stub_note = "(Full list not installed)";
    pub const back = "Back";
};

pub const zh_cn_startmenu = struct {
    pub const user_name = "用户";
    pub const account_subtitle = "标准用户";
    pub const search_placeholder = "搜索程序和文件";
    pub const all_programs = "所有程序";
    pub const foot_log_off = "注销";
    pub const foot_sleep = "睡眠";
    pub const foot_restart = "重新启动";
    pub const foot_shut_down = "关机";
    pub const fly_switch_user = "切换用户";
    pub const fly_log_off = "注销";
    pub const fly_lock = "锁定";
    pub const fly_restart = "重新启动";
    pub const fly_sleep = "睡眠";
    pub const fly_hibernate = "休眠";
    pub const fly_shut_down = "关机";
    pub const all_prog_stub_accessories = "附件";
    pub const all_prog_stub_games = "游戏";
    pub const all_prog_stub_system = "系统工具";
    pub const all_prog_stub_startup = "启动";
    pub const all_prog_stub_note = "（完整列表尚未提供）";
    pub const back = "返回";
};

pub var explorer_use_zh: bool = false;

pub fn startmenuLine(comptime field: []const u8) []const u8 {
    if (explorer_use_zh) {
        return @field(zh_cn_startmenu, field);
    }
    return @field(en_startmenu, field);
}

pub fn powerFlyoutLabels() [7][]const u8 {
    if (explorer_use_zh) {
        return .{
            zh_cn_startmenu.fly_switch_user,
            zh_cn_startmenu.fly_log_off,
            zh_cn_startmenu.fly_lock,
            zh_cn_startmenu.fly_restart,
            zh_cn_startmenu.fly_sleep,
            zh_cn_startmenu.fly_hibernate,
            zh_cn_startmenu.fly_shut_down,
        };
    }
    return .{
        en_startmenu.fly_switch_user,
        en_startmenu.fly_log_off,
        en_startmenu.fly_lock,
        en_startmenu.fly_restart,
        en_startmenu.fly_sleep,
        en_startmenu.fly_hibernate,
        en_startmenu.fly_shut_down,
    };
}

pub fn explorerLine(comptime field: []const u8) []const u8 {
    if (explorer_use_zh) {
        return @field(zh_cn_explorer, field);
    }
    return @field(en, field);
}

pub fn formatFooterObjects(buf: []u8, n: u32, path: []const u8) []const u8 {
    const std = @import("std");
    return std.fmt.bufPrint(buf, "{d} objects | {s}", .{ n, path }) catch "objects";
}

pub const active = en;
