# Syscall ABI（ZirconOSAero）

## x86_64：当前实现

- **入口**：
  - **`int 0x80`（向量 128）**：[`syscall_entry.s`](../../src/arch/x86_64/syscall_entry.s)。
  - **`syscall` 指令**（CPU 支持 `CPUID.80000001H:EDX[11]` 且 GDT 已初始化内核栈时）：[`syscall_lstar.s`](../../src/arch/x86_64/syscall_lstar.s) + [`syscall_msr.zig`](../../src/arch/x86_64/syscall_msr.zig) 配置 `IA32_LSTAR` / `IA32_STAR` / `IA32_FMASK`；与向量 128 **共用** `syscall.dispatch`。
- **约定**：`rax` = 调用号；`rdi, rsi, rdx, r10, r8, r9` = 参数（`syscall` 路径下 **破坏 `rcx`、`r11`**，与 AMD64 syscall 约定一致）；返回值在 `rax`（以 64 位有符号扩展承载 `NTSTATUS`）。
- **编号表**：[`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig) 中 `SYS_*` 常量（0–14）。**不是** Windows 内核 SSDT 编号；服务号映射路线图见 [SSDT_Roadmap.md](SSDT_Roadmap.md)。

## 与 Windows NT 6.1 x64 的差异

在 **真实 Windows 7 x64** 上，用户态通常通过 **`syscall` 指令** 进入内核，且服务号为 **Windows 构建版本对应的 SSDT 索引**。本仓库为独立内核，**默认不包含** 与 Windows 一致的 syscall 号表。

| 兼容模式 | 说明 |
|----------|------|
| **A. 自带 Native API（默认）** | 用户态仅链接本仓库提供的 [`src/libs/ntdll.zig`](../../src/libs/ntdll.zig)（或等价存根），经上述 `SYS_*` 陷入内核。 |
| **B. 二进制兼容（未实现）** | 若需加载 **微软 `ntdll.dll`**，须实现 Windows 7 x64 的 syscall 约定与完整服务表，并配套合法测试镜像；见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 与项目路线图。 |

## 其他架构

`aarch64`、`riscv64`、`loongarch64`、`mips64el`：**不** 声称与 Windows syscall 兼容；各自陷阱 ABI 应在对应 `arch/*/syscall*` 或中断模块中单独文档化（当前部分架构为 stub）。

## 相关

- 计时精度（PIT 以上）：[TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md)
- 服务号长期策略：[SSDT_Roadmap.md](SSDT_Roadmap.md)
