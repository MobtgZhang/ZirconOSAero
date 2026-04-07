# Explorer 壳层：VFS 卷快照与 MUI 风格字符串

## 卷与空间

- 挂载枚举与容量来自 [`src/fs/vfs.zig`](../../src/fs/vfs.zig)（`copyDosDriveMountInfos`、`queryMountSpace`）及 [`src/fs/explorer_volume_snapshot.zig`](../../src/fs/explorer_volume_snapshot.zig)。
- Explorer / DiskPart 共用同一快照逻辑，避免与静态 stub 双源。
- `query_space` 未实现或失败时，UI 显示「—」，不伪造数字。

## MUI 兼容策略（clean-room）

- [`src/drivers/video/desktop/shell_mui.zig`](../../src/drivers/video/desktop/shell_mui.zig) 使用稳定数值枚举 `StringId`、`LangId`，以及 `loadString` / `setLangFromConfig()`（读取 `desktop.conf` 的 `explorer_lang`）。
- 首版为 Zig 嵌入的英/中表，零运行时解析；**不**将微软专有 `.mui` 二进制当作规范实现。
- `registerStringTable` 为占位钩子，便于将来挂载自研资源包或 PE 资源子集（需单独文档与许可证评估）。

## 限制

- NTFS/FAT32 空闲统计为内核侧近似值，仅用于壳层展示与 DiskPart 列表叙事。
- 命令栏第二行（属性 / 系统属性 / 视图）为展示与命中占位，未接 Win32 命令路由。
