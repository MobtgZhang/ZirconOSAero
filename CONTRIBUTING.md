# 贡献指南（摘要）

- **版权**：清洁室实现；禁止 Windows NT / ReactOS / Wine 源码抄袭；ABI 名称与常量可对照 [Microsoft Learn](https://learn.microsoft.com/) 与 Intel/AMD 手册。
- **测试**：`zig build test`（堆与 SSDT 布局）；内核 `zig build kernel -Darch=x86_64`。
- **完成度**：提交时请标明变更属于 `Stub` / `Partial` / `Done` / `Verified` 哪一档，并更新 [docs/cn/API_COMPAT_MATRIX.md](docs/cn/API_COMPAT_MATRIX.md) 或 [docs/cn/NT61_CONTRACT_MATRIX.md](docs/cn/NT61_CONTRACT_MATRIX.md) 中的相关行。
