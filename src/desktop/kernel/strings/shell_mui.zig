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

//! MUI 风格壳层字符串

const std = @import("std");
const config = @import("../../../config/config.zig");

pub const LangId = enum(u8) {
    en_us = 0,
    zh_cn = 1,
};

pub var active_lang: LangId = .en_us;

pub fn setLangFromConfig() void {
    active_lang = if (config.isExplorerShellLangZh()) .zh_cn else .en_us;
}

pub fn registerStringTable(_: LangId, _: *const anyopaque) void {}

pub const StringId = enum(u32) {
    col_name = 0x1000,
    col_size = 0x1001,
    ex_col_date_modified = 0x1002,

    ex_lib_title = 0x1010,
    ex_lib_subtitle = 0x1011,
    ex_lib_search = 0x1012,
    ex_lib_organize = 0x1013,
    ex_lib_new_lib = 0x1014,
    ex_lib_nav_fav = 0x1015,
    ex_lib_nav_lib = 0x1016,
    ex_lib_nav_comp = 0x1017,
    ex_lib_nav_net = 0x1018,
    ex_lib_desktop = 0x1019,
    ex_lib_downloads = 0x101A,
    ex_lib_recent = 0x101B,
    ex_lib_documents = 0x101C,
    ex_lib_music = 0x101D,
    ex_lib_pictures = 0x101E,
    ex_lib_videos = 0x101F,
    ex_lib_status = 0x1020,

    ex_addr_computer = 0x1030,
    ex_grp_hard_disks = 0x1031,
    ex_grp_removable = 0x1032,

    ex_cmp_address = 0x1040,
    ex_cmp_go = 0x1041,
    ex_cmp_organize = 0x1042,
    ex_cmp_open = 0x1043,
    ex_cmp_more = 0x1044,
    ex_cmp_include_lib = 0x1045,
    ex_cmp_share_with = 0x1046,

    ex_cmd_properties = 0x1050,
    ex_cmd_system_properties = 0x1051,
    ex_cmd_view = 0x1052,

    ex_expl_empty_list = 0x1060,
    ex_status_brand = 0x1061,

    ex_space_unknown = 0x1070,
    ex_detail_fs_label = 0x1071,
    ex_detail_free_label = 0x1072,
    ex_detail_total_label = 0x1073,

    ex_fs_fat32 = 0x1080,
    ex_fs_ntfs = 0x1081,
    ex_fs_unknown = 0x1082,
    ex_fs_devfs = 0x1083,

    ex_ctx_open = 0x1090,
    ex_ctx_open_with = 0x1091,
    ex_ctx_cut = 0x1092,
    ex_ctx_copy = 0x1093,
    ex_ctx_paste = 0x1094,
    ex_ctx_delete = 0x1095,
    ex_ctx_rename = 0x1096,
    ex_ctx_properties = 0x1097,
    ex_ctx_new_folder = 0x1098,
    ex_ctx_copy_path = 0x1099,
    ex_ctx_open_cmd_here = 0x109A,

    ex_view_large_icon = 0x10A0,
    ex_view_small_icon = 0x10A1,
    ex_view_list = 0x10A2,
    ex_view_details = 0x10A3,

    ex_sort_by_name = 0x10B0,
    ex_sort_by_date = 0x10B1,
    ex_sort_by_size = 0x10B2,
    ex_sort_by_type = 0x10B3,
};

fn s(_: StringId, comptime en: []const u8, comptime zh: []const u8) []const u8 {
    return switch (active_lang) {
        .en_us => en,
        .zh_cn => zh,
    };
}

pub fn loadString(id: StringId, _: []u8) []const u8 {
    return switch (id) {
        .col_name => s(id, "Name", "名称"),
        .col_size => s(id, "Size", "大小"),
        .ex_col_date_modified => s(id, "Date modified", "修改日期"),

        .ex_lib_title => s(id, "Libraries", "库"),
        .ex_lib_subtitle => s(id, "Use this folder to access your libraries.", "使用此文件夹访问您的库。"),
        .ex_lib_search => s(id, "Search Libraries", "搜索库"),
        .ex_lib_organize => s(id, "Organize", "组织"),
        .ex_lib_new_lib => s(id, "New library", "新建库"),
        .ex_lib_nav_fav => s(id, "Favorites", "收藏夹"),
        .ex_lib_nav_lib => s(id, "Libraries", "库"),
        .ex_lib_nav_comp => s(id, "Computer", "计算机"),
        .ex_lib_nav_net => s(id, "Network", "网络"),
        .ex_lib_desktop => s(id, "Desktop", "桌面"),
        .ex_lib_downloads => s(id, "Downloads", "下载"),
        .ex_lib_recent => s(id, "Recent places", "最近访问的位置"),
        .ex_lib_documents => s(id, "Documents", "文档"),
        .ex_lib_music => s(id, "Music", "音乐"),
        .ex_lib_pictures => s(id, "Pictures", "图片"),
        .ex_lib_videos => s(id, "Videos", "视频"),
        .ex_lib_status => s(id, "4 items", "4 个对象"),

        .ex_addr_computer => s(id, "Computer", "计算机"),
        .ex_grp_hard_disks => s(id, "Hard disk drives", "硬盘驱动器"),
        .ex_grp_removable => s(id, "Devices with removable storage", "有可移动存储的设备"),

        .ex_cmp_address => s(id, "Address", "地址"),
        .ex_cmp_go => s(id, "Go", "转到"),
        .ex_cmp_organize => s(id, "Organize", "组织"),
        .ex_cmp_open => s(id, "Open", "打开"),
        .ex_cmp_more => s(id, "▼", "▼"),
        .ex_cmp_include_lib => s(id, "Include in library", "包含到库中"),
        .ex_cmp_share_with => s(id, "Share with", "共享给"),

        .ex_cmd_properties => s(id, "Properties", "属性"),
        .ex_cmd_system_properties => s(id, "System properties", "系统属性"),
        .ex_cmd_view => s(id, "View", "视图"),

        .ex_expl_empty_list => s(id, "Choose a drive in the navigation pane.", "请在导航窗格中选择一个驱动器。"),
        .ex_status_brand => s(id, "Aero DWM", "Aero DWM"),

        .ex_space_unknown => s(id, "—", "—"),
        .ex_detail_fs_label => s(id, "File system:", "文件系统："),
        .ex_detail_free_label => s(id, "Free space:", "可用空间："),
        .ex_detail_total_label => s(id, "Total size:", "总容量："),

        .ex_fs_fat32 => s(id, "FAT32", "FAT32"),
        .ex_fs_ntfs => s(id, "NTFS", "NTFS"),
        .ex_fs_unknown => s(id, "Unknown", "未知"),
        .ex_fs_devfs => s(id, "DEVFS", "DEVFS"),

        .ex_ctx_open => s(id, "Open", "打开"),
        .ex_ctx_open_with => s(id, "Open with...", "打开方式..."),
        .ex_ctx_cut => s(id, "Cut", "剪切"),
        .ex_ctx_copy => s(id, "Copy", "复制"),
        .ex_ctx_paste => s(id, "Paste", "粘贴"),
        .ex_ctx_delete => s(id, "Delete", "删除"),
        .ex_ctx_rename => s(id, "Rename", "重命名"),
        .ex_ctx_properties => s(id, "Properties", "属性"),
        .ex_ctx_new_folder => s(id, "New folder", "新建文件夹"),
        .ex_ctx_copy_path => s(id, "Copy as path", "复制路径"),
        .ex_ctx_open_cmd_here => s(id, "Open command window here", "在此处打开命令窗口"),

        .ex_view_large_icon => s(id, "Large icons", "大图标"),
        .ex_view_small_icon => s(id, "Small icons", "小图标"),
        .ex_view_list => s(id, "List", "列表"),
        .ex_view_details => s(id, "Details", "详细信息"),

        .ex_sort_by_name => s(id, "Name", "名称"),
        .ex_sort_by_date => s(id, "Date modified", "修改日期"),
        .ex_sort_by_size => s(id, "Size", "大小"),
        .ex_sort_by_type => s(id, "Type", "类型"),
    };
}

pub fn formatExplorerStatusBar(buf: []u8, item_count: usize, place_line: []const u8, brand: []const u8) []const u8 {
    return switch (active_lang) {
        .en_us => std.fmt.bufPrint(buf, "{d} items | {s} | {s}", .{ item_count, place_line, brand }) catch brand,
        .zh_cn => std.fmt.bufPrint(buf, "{d} 个项目 | {s} | {s}", .{ item_count, place_line, brand }) catch brand,
    };
}

pub fn fsTypeLabel(fs: @import("../../../fs/vfs.zig").FsType, scratch: []u8) []const u8 {
    return switch (fs) {
        .fat12, .fat16, .fat32 => loadString(.ex_fs_fat32, scratch),
        .ntfs => loadString(.ex_fs_ntfs, scratch),
        .exfat => loadString(.ex_fs_ntfs, scratch),
        .devfs => loadString(.ex_fs_devfs, scratch),
        .initfs => loadString(.ex_fs_devfs, scratch),
        .iso9660, .udf, .refs, .unknown => loadString(.ex_fs_unknown, scratch),
    };
}
