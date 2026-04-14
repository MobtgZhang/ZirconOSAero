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
// Module: src/mm/percpu_index.zig
// Purpose: 当前处理器下标存根（置于 `mm/` 以便 `pool`/`lookaside` 单测可导入）；SMP 后由 `KPCR` 接线。
//
// This is an independent clean-room implementation.
// Ref: WDK — per-processor data (behavioral only).

/// 当前 CPU 索引；BSP 单核恒为 0。
pub fn currentCpuIndex() u32 {
    return 0;
}
