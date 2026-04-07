# WOW64 语义 — LoongArch64 宿主（Clean Room）

本文件描述 **ZirconOSAero** 在 **LoongArch64** 上承载 32 位子系统的**可观测行为边界**，不复制 Windows DDK/SDK 声明块。

## 1. 术语

- **x86 WOW64**：在 LA64 上运行 **x86-32** 映像须 **二进制翻译**（解释器、DBT，或可选第三方引擎如 LATX）；内核仍只接受 **原生 LA64** syscall；翻译层负责将 x86 `int 0x2E` / `sysenter` 等转为对本仓库 `wow64/thunk.zig` 与 x86 SSDT 子集的调用。
- **LoongArch32**：独立 ABI，**不得**复用 x86 thunk 表；须单独的 PE/ELF 机器类型、VA 与用户 syscall 约定（见 `la32_policy.zig` 占位）。

## 2. NTSTATUS 矩阵（当前）

| 场景 | 行为 |
| --- | --- |
| 宿主 LA64 原生 PE（0x6264） | 走 `pe.zig` / 进程创建既有路径 |
| x86-32 映像执行 | 引擎未接线前：`STATUS_NOT_IMPLEMENTED`（或进程创建拒绝） |
| LBT | `lbt_hw.zig` 探测为假时忽略；真探测须仅基于公开手册 |

## 3. 与微软 CHPE/ARM64EC

本项目 **不**实现、不声称兼容 CHPE/ARM64EC。
