# `tests/host/`

此处为 **需与 `src/` 同包路径 `@import`** 的宿主测试 **真源**；`build.zig` 使用 `src/<name>.zig` 符号链接指向这些文件，以满足 Zig 0.15 模块根目录规则（见 [`CONTRIBUTING.md`](../../CONTRIBUTING.md)）。

不依赖内核树导入的宿主测试仍可直接放在 [`tests/`](../) 或 [`tests/nt61/`](../nt61/)。
