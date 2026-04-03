# 文档职责划分（避免重复维护）

以下说明 **哪份文档维护什么**；其它文档应单句引用此处或三件套，避免复制长表。

| 文档 | 维护内容 |
|------|----------|
| [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) | 子系统/能力 **承诺边界**、状态列（Stub / Partial / Done / Verified）、与实现对齐的叙事 |
| [cn/MVT_NT61.md](cn/MVT_NT61.md) | **可复现验证**：命令、`zig build test` 步骤名、源码/测试路径映射 |
| [cn/NT61_KERNEL_TODO.md](cn/NT61_KERNEL_TODO.md) | 内核模式 **K0–K8** 落地任务与主要源码路径 |
| [cn/NT61_FULL_API_BACKLOG.md](cn/NT61_FULL_API_BACKLOG.md) | **长期**全量 NT API 面；不表示已实现；分节 CI 锚点见文内 |
| [cn/API_COMPAT_MATRIX.md](cn/API_COMPAT_MATRIX.md) | **Win32/Native API** 骨架一行表；随 PR 更新；细节以契约矩阵为准 |
| [cn/NT61_PR_GATES.md](cn/NT61_PR_GATES.md) | 合并前人类勾选；含文档链接检查命令 |
| [docs/REPRODUCE_BUILD.md](REPRODUCE_BUILD.md) | Zig/QEMU 版本、Release、与 CI 对齐的构建命令 |
| [`scripts/check-docs-links.sh`](../scripts/check-docs-links.sh) | `docs/` 相对链接完整性（`bash scripts/check-docs-links.sh`） |

**交叉引用规则**：非 Hub 页底部「相关链接」宜 ≤5 条，优先指向契约矩阵、MVT、KERNEL_TODO 之一。
