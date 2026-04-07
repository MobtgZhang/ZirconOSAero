# LoongArch「旧世界」引导 — 占位规格

## 范围

非标准 UEFI / PMON 环境不在当前主线；本文件仅占位 **路线图**：

- 独立 pre-kernel loader（ELF 或原始入口）；
- 串口诊断与固定设备表（HT/LIOINTC 等）；
- 与 `run-loongarch64` UEFI 路径互斥的 Makefile 目标。

实现前须单独安全审计与真机矩阵。
