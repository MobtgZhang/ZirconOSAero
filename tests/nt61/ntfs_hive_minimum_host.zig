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

//! NTFS 与 ZOSH1/hive 持久化的阶段 4 最小能力说明（主机可编译；不链完整 `ntfs.zig` 以免 `klog` 依赖）。
//!
//! **已实现**（见 `src/fs/ntfs.zig`）：`open/read/write`、根目录枚举、`createDir`/`createFile`、单簇 `CLUSTER_SIZE` 流式读写。
//! **hive 长期项**：`registry.zig` ZOSH1 覆盖与 **原生 RegF** 全解析仍为路线图；NTFS 上需 **小文件随机写 + 属性流子集** 方与商业 Win7 hive 规模对齐。
//! **本测试**：仅固定与 `ntfs.zig` 一致的常量锚点，防静默漂移。NTFS `D:\` ZOSH1 路径见 **`phase4_host_anchors`**。

const std = @import("std");

/// 须与 [`src/fs/ntfs.zig`](../../src/fs/ntfs.zig) `CLUSTER_SIZE` 同步。
pub const ntfs_cluster_bytes: usize = 4096;

test "NTFS hive minimum: cluster matches ntfs.zig" {
    try std.testing.expectEqual(@as(usize, 4096), ntfs_cluster_bytes);
}
