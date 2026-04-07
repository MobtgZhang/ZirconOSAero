# PEB / TEB / TLS — LoongArch64（NT6.1 风格占位）

## 1. 目标

- **原生 LA64 进程**：与 x64 **数值上**兼容的用户 VA 带（见 `MemoryManagement_NT61_LoongArch64_NewWorld.md`）；PEB/TEB 字段布局可复用 `peb_nt61_x64.zig` / `teb_nt61_x64.zig` 的 **子集**，以测试与主机锚点为准。
- **将来 WOW64（x86-32）**：32 位 PEB/TEB 指针与 `ProcessWow64Information` 行为与 x86_64 宿主一致（概念层，见 MS Learn）；实现须独立撰写。

## 2. TLS

- 静态 TLS 目录仍由 `pe.zig` 策略门控；LoongArch 无单独例外。

## 3. 测试

- 新增布局断言时优先 **主机测试** + `builtin.cpu.arch == .loongarch64` 目标内建测试，避免引入闭源头文件。
