# 问题 #42：HAL 架构抽象泄漏

## 1. 问题编号

`42`

## 2. 问题位置

- 文件路径：`src/ps/process.zig`、`src/ke/percpu_sched.zig`、`src/ke/timekeeping.zig`、`src/hal.zig`
- 函数/模块：进程地址空间创建、调度 CPU 选择、时间源、统一 HAL
- 行号或代码片段：原代码直接在非 `arch/`、`hal/` 层判断 `.x86_64`、`.loongarch64` 等目标并导入具体 HAL 文件。

## 3. 问题描述

进程创建、CPU 拓扑和时间源等上层代码直接分支到具体架构。新增架构时必须同步修改这些内核/应用路径，违背了“平台细节只留在 HAL/arch”的目标。

## 4. 复现路径

新增目标架构或检查非允许目录时，可见多处 `builtin.cpu.arch`、`.loongarch64`、`.x86_64` 判断和直接导入 `hal/<arch>/...` 的代码。

## 5. 影响范围

影响多架构可维护性、后续 mips64el/sw64 移植成本，以及内核/进程/调度/时间模块的可读性。

## 6. 严重程度

High

## 7. 可能原因

早期实现按目标架构逐处硬编码，缺少统一的进程地址空间、拓扑和时间源接口。

## 8. 权威参考依据

- Windows NT 6.1 的 HAL/Executive 分层概念要求平台相关实现隔离在 HAL 层。
- 本仓库目标约束：应用层与普通内核路径不得出现架构标识；平台差异通过 `src/hal.zig` 或 `src/arch.zig` 统一暴露。

## 9. 建议修复方案

在 `src/hal.zig` 增加统一接口：进程地址空间内核半区链接、KUSER_SHARED 支持、ASID 类标记、逻辑 CPU 数、高分辨率时间源。上层只调用抽象接口。

## 10. 验证方法

1. `zig build kernel -Darch=x86_64 ...` 通过。
2. aarch64、riscv64、mips64el 交叉编译通过。
3. 检查已修复文件中不再出现具体架构分支；剩余架构相关代码按允许边界集中到 `src/hal/`、`src/arch/`、`src/drivers/video/`。

## 11. 状态

Fixed
