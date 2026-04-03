# NT 6.1 内核 PR 门禁清单（K0，Clean-room）

与 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) **Phase K0**、[AeroDesktopRuntime.md](AeroDesktopRuntime.md)（QEMU/显示路径）及「NT61 内核与显示待办」一致。合并内核相关 PR 前自查；**不替代**人工代码审查。

## K0.1 契约矩阵

- [ ] 已更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中与本 PR 相关的行（§0–§2、§8–§9 等）状态或说明列。
- [ ] 若新增 **Verified** 能力，矩阵中测试/CI 列指向具体 `zig build test` 名或 CI 步骤。

## K0.2 自动化验证

- [ ] 新逻辑有 `tests/` 或现有主机测试扩展（见 [MVT_NT61.md](MVT_NT61.md)）。
- [ ] 本地 `zig build test` 通过。
- [ ] 若修改了 `docs/` 下 Markdown：`bash scripts/check-docs-links.sh`（仓库根目录）通过。

## K0.3 文档注释

- [ ] 新增或修改的 syscall、驱动入口、IRP 路径含 **Microsoft Learn / WDK** 或硬件规范链接，并注明与 NT 完整语义的**简化假设**（若有）。

## K0.4 合规

- [ ] `bash scripts/verify-compliance.sh` 通过（与 CI Compliance 步骤一致）。
- [ ] 无 Windows/ReactOS/Wine 源码参照实现。

## K0.5 Win32 / 子系统表述与矩阵（任意 PR 若触及下列内容）

- [ ] 若 README、[docs/en/Subsystems.md](../en/Subsystems.md)、[docs/cn/Subsystems.md](Subsystems.md) 或营销性「功能列表」中**扩大** Win32、WOW64、ntdll、csrss、user32、gdi32 的完成度表述，须**同一 PR** 更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 与（如适用）[API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md)，并在 [MVT_NT61.md](MVT_NT61.md) 或 `tests/` 增加可复现验证，或明确保持 `Stub`/`Partial`。
- [ ] 实现与文档引用仅限 **Microsoft Learn、WDK、硬件规范、公开发表的 ABI 对照**；行为细节不足时以实验 + 文档迭代，不依赖非白名单逆向代码库。

**分阶段路线图**：[DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md)。

## 相关链接

| 文档 | 用途 |
|------|------|
| [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) | 契约与状态 |
| [MVT_NT61.md](MVT_NT61.md) | 验证映射 |
| [PROCESS_NT61.md](PROCESS_NT61.md) | 阶段流程 |
| [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) | 延后项 |
