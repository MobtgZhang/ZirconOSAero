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

/// H3：多后端块读表（NVMe 与 AHCI 可各填一张，供上层 `vfs`/卷挂载演进）。
pub const BlockDevVTable = struct {
    ctx: *anyopaque,
    read_blocks: ReadBlocksFn,
};
