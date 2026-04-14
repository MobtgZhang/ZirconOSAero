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
// Module: sdk/nt61_syscall_numbers_x64.zig
// Purpose: 标明 **NT 6.1 x64 系统调用 SSDT 索引** 的单一真源路径（避免与内核副本漂移）。
//
// This is an independent clean-room implementation.
// Ref: 数值定义见 `src/arch/x86_64/ssdt_nt61.zig`；公开 per-build 表参见 j00ru/windows-syscalls 等社区维护资源。

/// 相对仓库根：内核与用户态工具应 import 该 Zig 翻译单元以获取 `Nt*` 索引常量。
pub const nt61_x64_ssdt_zig_path_from_repo_root = "src/arch/x86_64/ssdt_nt61.zig";

// 注意：不可在本文件中 `@import` 上述路径 — Zig 模块树要求 `ssdt_nt61.zig` 仅归属一个编译单元。
// 主机/工具请在 `build.zig` 中并列添加 `ssdt_nt61` 模块，或从以 `src/` 为根的测试（如 `syscall_numbers_lock_nt61_host`）直接 import。
