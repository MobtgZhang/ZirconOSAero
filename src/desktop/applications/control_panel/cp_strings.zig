// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/cp_strings.zig
// Purpose: Control Panel UI strings
//
// This is an independent clean-room implementation.

pub const CPStrings = struct {
    pub const en = struct {
        pub const window_title = "Control Panel";
        pub const category_view = "Category";
        pub const classic_view = "Large Icons";
        pub const search_placeholder = "Search control panel";
        pub const system_and_security = "System and Security";
        pub const network = "Network and Internet";
        pub const hardware = "Hardware and Sound";
        pub const programs = "Programs";
        pub const user_accounts = "User Accounts";
        pub const appearance = "Appearance and Personalization";
        pub const clock = "Clock, Language, and Region";
        pub const ease_of_access = "Ease of Access";
        pub const additional_options = "Additional Options";

        pub const desc_system = "Review computer status";
        pub const desc_network = "View network status and settings";
        pub const desc_hardware = "Configure hardware";
        pub const desc_programs = "Uninstall programs";
        pub const desc_accounts = "Add or remove user accounts";
        pub const desc_appearance = "Customize desktop background";
        pub const desc_clock = "Set time and date";
        pub const desc_ease = "Optimize computer display";
    };

    pub const zh_cn = struct {
        pub const window_title = "控制面板";
        pub const category_view = "类别";
        pub const classic_view = "大图标";
        pub const search_placeholder = "搜索控制面板";
        pub const system_and_security = "系统和安全";
        pub const network = "网络和 Internet";
        pub const hardware = "硬件和声音";
        pub const programs = "程序";
        pub const user_accounts = "用户账户";
        pub const appearance = "外观和个性化";
        pub const clock = "时钟、语言和区域";
        pub const ease_of_access = "轻松访问";
        pub const additional_options = "其他选项";

        pub const desc_system = "查看计算机状态";
        pub const desc_network = "查看网络状态和设置";
        pub const desc_hardware = "配置硬件设备";
        pub const desc_programs = "卸载程序";
        pub const desc_accounts = "添加或删除用户账户";
        pub const desc_appearance = "自定义桌面背景";
        pub const desc_clock = "设置时间和日期";
        pub const desc_ease = "优化计算机显示";
    };
};

pub var active_lang: enum { en, zh_cn } = .en;

pub fn cpString(comptime field: []const u8) []const u8 {
    if (active_lang == .zh_cn) {
        return @field(CPStrings.zh_cn, field);
    }
    return @field(CPStrings.en, field);
}
