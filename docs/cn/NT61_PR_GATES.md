# NT 6.1 内核 PR 门禁清单（K0，Clean-room）

与 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) **Phase K0**、[mdcs/composer2/content1.3.md](../../mdcs/composer2/content1.3.md) 及计划「NT61 内核与显示待办」一致。合并内核相关 PR 前自查；**不替代**人工代码审查。

## K0.1 契约矩阵

- [ ] 已更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中与本 PR 相关的行（§0–§2、§8–§9 等）状态或说明列。
- [ ] 若新增 **Verified** 能力，矩阵中测试/CI 列指向具体 `zig build test` 名或 CI 步骤。

## K0.2 自动化验证

- [ ] 新逻辑有 `tests/` 或现有主机测试扩展（见 [MVT_NT61.md](MVT_NT61.md)）。
- [ ] 本地 `zig build test` 通过。

## K0.3 文档注释

- [ ] 新增或修改的 syscall、驱动入口、IRP 路径含 **Microsoft Learn / WDK** 或硬件规范链接，并注明与 NT 完整语义的**简化假设**（若有）。

## K0.4 合规

- [ ] `bash scripts/verify-compliance.sh` 通过（与 CI Compliance 步骤一致）。
- [ ] 无 Windows/ReactOS/Wine 源码参照实现。

## 相关索引

| 文档 | 用途 |
|------|------|
| [PROCESS_NT61.md](PROCESS_NT61.md) | 阶段流程 |
| [MVT_NT61.md](MVT_NT61.md) | 可复现测试表 |
| [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) | 非阻塞延后项 |
