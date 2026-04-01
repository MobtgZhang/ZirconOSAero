# Syscall ABI（ZirconOSAero）

## x86_64：当前实现

- **主路径（与微软 x64 ntdll 一致）**：**`syscall` / `sysret`** — [`syscall_lstar.s`](../../src/arch/x86_64/syscall_lstar.s) + [`syscall_msr.zig`](../../src/arch/x86_64/syscall_msr.zig)（`IA32_LSTAR` / `IA32_STAR` / `IA32_FMASK`、`SWAPGS`、per-CPU RSP0）。用户态薄封装见 [`ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig)（**勿**在 Linux 主机上执行其中的 `syscall`）。
- **兼容 / 调试入口**：**`int 0x80`（向量 128）** — [`syscall_entry.s`](../../src/arch/x86_64/syscall_entry.s)，**`iretq` 返回**；寄存器约定与上相同（第 1 参 **`R10`**），**不是** Linux `int 0x80` 传参习惯。
- **服务号**（`RAX`）：
  - **NT 6.1 x64 SSDT 子集**：常量见 [`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig)；AMD64 约定第 **1** 参在 **`R10`**，第 2–4 参为 **`RDX`/`R8`/`R9`**，其余在用户栈（第 5 参相对 SYSCALL 时 `RSP` 常为 `+0x28`）。索引与 **Windows 7 SP1 x64** 公开表对齐（参考 `j00ru/windows-syscalls`），本仓库仅实现子集。
  - **节区相关**（与 WOW64 32 位表 **不同号**；仅 x64 原生路径）：`NtCreateSection` 0x47、`NtMapViewOfSection` 0x48、`NtUnmapViewOfSection` 0x2A；分发与 **用户指针 `probe`** 见 [`syscall.zig`](../../src/arch/x86_64/syscall.zig)。
  - **`int 0x80` 与 `syscall` 一致**：均使用上述 NT x64 约定（**不要**再使用已移除的 `0x0010_0000` 内部服务号）。
- **返回值**：`RAX` 承载 `NTSTATUS`（有符号 32 位零扩展）。

## 与 Windows NT 6.1 x64 的差异

| 兼容模式 | 说明 |
|----------|------|
| **A. 本仓库 ntdll + 上表 SSDT 子集** | 用户态可经 `syscall` 使用已列出的服务号；未列出服务返回 `STATUS_INVALID_PARAMETER`。 |
| **B. 加载微软 `ntdll.dll`** | 仍须服务表与 **7600/7601** 构建完全一致及更多 Win32k 项；见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)。 |

## WOW64 / x86（32 位）服务号

原生 **x86** 内核使用的服务号与 x64 SSDT **不同**；公开对照见 [`wow64/ssdt_x86_win7_sp1.zig`](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig)（j00ru `x86/json/nt-per-system.json`，Windows 7 SP1）。真实 SysWOW64 在 64 位内核上仍走 **64 位 SSDT**；`translateSyscall32to64` 演进须同时维护两表。

## 其他架构

`aarch64`、`riscv64`、`loongarch64`、`mips64el`：**不** 声称与 Windows syscall 兼容；陷阱 ABI 在对应 `arch/*/interrupt*` 中单独说明。

## 相关

- [SSDT_Roadmap.md](SSDT_Roadmap.md) — 历史与扩展策略  
- [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)  
- [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md)
