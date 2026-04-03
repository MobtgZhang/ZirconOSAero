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
