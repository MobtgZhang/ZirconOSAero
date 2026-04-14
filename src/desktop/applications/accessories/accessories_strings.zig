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
// Module: src/desktop/applications/accessories/accessories_strings.zig
// Purpose: Accessory application strings
//
// This is an independent clean-room implementation.

pub const AccStrings = struct {
    pub const en = struct {
        pub const calc = "Calculator";
        pub const notepad = "Notepad";
        pub const char_map = "Character Map";
        pub const sysinfo = "System Information";
        pub const new_file = "New";
        pub const open = "Open";
        pub const save = "Save";
        pub const save_as = "Save As...";
        pub const undo = "Undo";
        pub const redo = "Redo";
        pub const cut = "Cut";
        pub const copy = "Copy";
        pub const paste = "Paste";
        pub const select_all = "Select All";
        pub const find = "Find";
        pub const replace = "Replace";
        pub const go_to = "Go to...";
        pub const time_date = "Time/Date";
        pub const word_wrap = "Word Wrap";
        pub const font = "Font";
    };

    pub const zh_cn = struct {
        pub const calc = "计算器";
        pub const notepad = "记事本";
        pub const char_map = "字符映射表";
        pub const sysinfo = "系统信息";
        pub const new_file = "新建";
        pub const open = "打开";
        pub const save = "保存";
        pub const save_as = "另存为...";
        pub const undo = "撤销";
        pub const redo = "重做";
        pub const cut = "剪切";
        pub const copy = "复制";
        pub const paste = "粘贴";
        pub const select_all = "全选";
        pub const find = "查找";
        pub const replace = "替换";
        pub const go_to = "转到...";
        pub const time_date = "时间/日期";
        pub const word_wrap = "自动换行";
        pub const font = "字体";
    };
};

pub var active_lang: enum { en, zh_cn } = .en;

pub fn accString(comptime field: []const u8) []const u8 {
    if (active_lang == .zh_cn) {
        return @field(AccStrings.zh_cn, field);
    }
    return @field(AccStrings.en, field);
}
