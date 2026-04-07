# 结构重组基线（记录用）

在较大规模移动/拆分源码前后对照用。环境：仓库根目录，`zig version` 以 CI（`build.zig.zon`）为准。

## 命令与耗时（本地一次采样）

| 命令 | 结果 | 耗时（约） |
|------|------|------------|
| `zig build` | 通过 | ~37 s |
| `zig build test` | 通过 | ~43 s |
| `zig build -Darch=loongarch64` | 通过 | ~0.1 s（增量/缓存） |

## 需与内核同包 `@import` 的宿主测试（真源 + 符号链接）

真源在 `tests/host/`；`src/<name>.zig` 为指向该真源的符号链接，供 Zig 将模块根视为 `src/`：

- `tests/host/zircon_host_ob_test.zig` ← `src/zircon_host_ob_test.zig`
- `tests/host/syscall_numbers_lock_nt61_host.zig` ← `src/syscall_numbers_lock_nt61_host.zig`
- （其余 7 个同名 `*_host*.zig` / `zircon_host_phase_b_exec_test.zig` 同理）

其余宿主测试在 `tests/` 或 `tests/nt61/`。
