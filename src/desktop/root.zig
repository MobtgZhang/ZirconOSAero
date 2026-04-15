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

//! Desktop shared root (cross-stack consolidation entry).
//! 架构分层：
//! - dwm: 新 D3D10 桌面窗口管理器（完整合成器、窗口管理器、Shell应用）
//! - kernel: 内核空间桌面渲染路径（帧缓冲渲染、内核级UI组件、快速响应路径）
//! - 公共组件: strings、icons、dwm、events等跨层共享定义

pub const strings = @import("strings/root.zig");
pub const icons = @import("icons/root.zig");
pub const dwm = @import("dwm/root.zig");
pub const events = @import("events.zig");
pub const applications = @import("applications/root.zig");

// 桥接层：提供旧 Aero API 兼容

pub const kernel_desktop = @import("kernel/root.zig");
