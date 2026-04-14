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
// Module: src/drivers/storage/block_dev_common.zig
// Purpose: AHCI / NVMe 等块设备共享的 **薄抽象**（读扇区回调表）；H3 与 VFS 接线共用锚点。
//
// This is an independent clean-room implementation.
// Reference: OS 教材块设备队列概念；AHCI/NVMe 规范为各驱动私有。

const io = @import("../../io/io.zig");

/// 同步读 `lba` 起连续扇区入 `buf`（扇区大小由实现约定，常为 512）。
pub const ReadBlocksFn = *const fn (ctx: *anyopaque, lba: u64, buf: []u8) io.NTSTATUS;

/// 同步写 `buf` 内容至 `lba` 起连续扇区（扇区数 = `buf.len / 512`）。
pub const WriteBlocksFn = *const fn (ctx: *anyopaque, lba: u64, buf: []const u8) io.NTSTATUS;

/// 强制将设备写缓存中的数据刷新到非易失性介质（相当于 ATA FLUSH CACHE / NVMe Flush）。
pub const FlushBlocksFn = *const fn (ctx: *anyopaque) io.NTSTATUS;

/// H3：多后端块读写刷新表（NVMe 与 AHCI 可各填一张，供上层 `vfs`/卷挂载演进）。
pub const BlockDevVTable = struct {
    ctx: *anyopaque,
    read_blocks: ReadBlocksFn,
    write_blocks: ?WriteBlocksFn = null,
    flush_blocks: ?FlushBlocksFn = null,
};
