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

//!
//! NDIS 6.20 模块导出

pub const types = @import("ndis_types.zig");
pub const buffer = @import("ndis_buffer.zig");
pub const protocol = @import("ndis_protocol.zig");

// 常用类型已通过pub const导出，使用时可直接通过import访问
// 例如：const ndis = @import("ndis/mod.zig"); 使用ndis.types.NDIS_*
