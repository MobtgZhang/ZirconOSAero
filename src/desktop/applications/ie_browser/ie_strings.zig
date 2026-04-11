// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/ie_strings.zig
// Purpose: Internet Explorer UI strings
//
// This is an independent clean-room implementation.

const shell_mui = @import("../../kernel/strings/shell_mui.zig");

pub const LangId = shell_mui.LangId;
pub var active_lang = shell_mui.active_lang;

pub const IEVersion = struct {
    pub const name = "Internet Explorer";
    pub const version = "9.0";
    pub const build = "Build 7601";
    pub const mode = "64-bit";
};

pub const IEUIString = struct {
    pub const en = struct {
        pub const window_title = "Internet Explorer";
        pub const home_button = "Home";
        pub const back_button = "Back";
        pub const forward_button = "Forward";
        pub const stop_button = "Stop";
        pub const refresh_button = "Refresh";
        pub const search_button = "Search";
        pub const favorites_button = "Favorites";
        pub const tools_button = "Tools";
        pub const help_button = "Help";
        pub const new_tab = "New tab";
        pub const close_tab = "Close tab";
        pub const address_placeholder = "Enter web address";
        pub const go_button = "Go";
        pub const loading = "Loading...";
        pub const done = "Done";
        pub const error_page = "Cannot display this webpage";
        pub const security_https = "Security: HTTPS Connection";
        pub const security_http = "Non-secure connection";
        pub const favorites = "Favorites";
        pub const add_to_favorites = "Add to Favorites";
        pub const organize_favorites = "Organize Favorites";
        pub const feed = "Feeds";
        pub const history = "History";
        pub const menu_file = "File";
        pub const menu_edit = "Edit";
        pub const menu_view = "View";
        pub const menu_favorites = "Favorites";
        pub const menu_tools = "Tools";
        pub const menu_help = "Help";
        pub const menu_new_window = "New Window";
        pub const menu_new_tab = "New Tab";
        pub const menu_save_as = "Save As...";
        pub const menu_print = "Print";
        pub const menu_exit = "Exit";
        pub const menu_undo = "Undo";
        pub const menu_redo = "Redo";
        pub const menu_cut = "Cut";
        pub const menu_copy = "Copy";
        pub const menu_paste = "Paste";
        pub const menu_select_all = "Select All";
        pub const menu_encoding = "Encoding";
        pub const menu_zoom = "Zoom";
        pub const menu_status_bar = "Status Bar";
        pub const menu_full_screen = "Full Screen";
        pub const menu_internet_options = "Internet Options";
        pub const menu_about = "About Internet Explorer";
    };

    pub const zh_cn = struct {
        pub const window_title = "Windows Internet Explorer";
        pub const home_button = "主页";
        pub const back_button = "后退";
        pub const forward_button = "前进";
        pub const stop_button = "停止";
        pub const refresh_button = "刷新";
        pub const search_button = "搜索";
        pub const favorites_button = "收藏夹";
        pub const tools_button = "工具";
        pub const help_button = "帮助";
        pub const new_tab = "新建标签页";
        pub const close_tab = "关闭标签页";
        pub const address_placeholder = "输入网址";
        pub const go_button = "转到";
        pub const loading = "正在加载...";
        pub const done = "完成";
        pub const error_page = "无法显示此网页";
        pub const security_https = "安全: HTTPS 连接";
        pub const security_http = "非安全连接";
        pub const favorites = "收藏夹";
        pub const add_to_favorites = "添加到收藏夹";
        pub const organize_favorites = "整理收藏夹";
        pub const feed = "源";
        pub const history = "历史记录";
        pub const menu_file = "文件";
        pub const menu_edit = "编辑";
        pub const menu_view = "查看";
        pub const menu_favorites = "收藏夹";
        pub const menu_tools = "工具";
        pub const menu_help = "帮助";
        pub const menu_new_window = "新建窗口";
        pub const menu_new_tab = "新建标签页";
        pub const menu_save_as = "另存为...";
        pub const menu_print = "打印";
        pub const menu_exit = "退出";
        pub const menu_undo = "撤销";
        pub const menu_redo = "重做";
        pub const menu_cut = "剪切";
        pub const menu_copy = "复制";
        pub const menu_paste = "粘贴";
        pub const menu_select_all = "全选";
        pub const menu_encoding = "编码";
        pub const menu_zoom = "缩放";
        pub const menu_status_bar = "状态栏";
        pub const menu_full_screen = "全屏";
        pub const menu_internet_options = "Internet 选项";
        pub const menu_help_about = "关于 Internet Explorer";
    };
};

pub fn ieString(comptime field: []const u8) []const u8 {
    if (active_lang == .zh_cn) {
        return @field(IEUIString.zh_cn, field);
    }
    return @field(IEUIString.en, field);
}

pub fn setIELang(id: LangId) void {
    active_lang = id;
}
