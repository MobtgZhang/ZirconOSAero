# Tier 2 架构说明（非 x86_64）

**主线**：NT 6.1 公开 ABI 契约、SSDT 子集与用户态 Win32 桩的 **回归与兼容测试以 x86_64 为唯一 Tier 1**。

| 架构 | 级别 | 说明 |
|------|------|------|
| `x86_64` | Tier 1 | 完整引导、IDT、`syscall`/SSDT、Aero 桌面、VFS/注册表运行时 |
| `aarch64` | Tier 2 | 陷阱与定时器路径独立；**不**声称与 Windows syscall 表一致 |
| `riscv64` | Tier 2 | 同 aarch64；QEMU `virt` 验证为主 |
| `loongarch64` | Tier 2 | UEFI/GOP 与桌面 bring-up；WinNT ABI 非目标 |
| `mips64el` | Tier 2 | 实验性 |

将 Tier 2 平台提升到 Tier 1 前，须单独定义陷阱 ABI 文档并完成与 `tests/nt61/` 对等的架构内测试集。
