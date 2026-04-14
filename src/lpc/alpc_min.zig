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
// Module: src/lpc/alpc_min.zig
// Purpose: **ALPC** 最小类型占位（阶段四；由经典 LPC 端口演进，见 MS Learn ALPC 行为描述）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/alpc

/// ALPC 端口对象类别占位（与 `lpc/port.zig` 的 `PortKind` 并行演进）。
pub const AlpcPortKind = enum { server, client };

/// 将来：`NtAlpcCreatePort` / `NtAlpcConnectPort` 与内核对象管理器接线。
pub const AlpcPortRef = struct {
    kind: AlpcPortKind = .server,
};
