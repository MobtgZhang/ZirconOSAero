# Win32 / Native API 兼容性矩阵（骨架）

本表用于路线图 **C-T09**：随实现推进在 PR 中更新行，不依赖逆向 Windows 二进制。**与契约矩阵分工**：[DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md)。

**边界**：本表仅声明 **子集** 与 **Partial** 语义；完整能力与延后项以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 及 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) 为准。

**回归**：见 [MVT_NT61.md](MVT_NT61.md)。

**DLL 分层（C4，与 NT 6.1 同向）**：商业栈中大量 **kernel32** 导出转发至 **KernelBase**，再调 **ntdll** Native API。本仓库：`kernelbase.zig` 承载 **`GetLastError`/`SetLastError`** 及 **`NtClose` 等**集中转发；`kernel32.zig` 以 **薄包装 / re-export** 为主（见 `kernel32` 文件尾 `GetLastError` 别名）。扩展 Native 入口时优先加在 `kernelbase`，避免 `kernel32` 与 `ntdll` 重复实现。

| 模块        | 代表 API              | 状态     | 备注 |
|-------------|----------------------|----------|------|
| ntdll       | LdrInitializeThunk / RtlUserThreadStart | Stub | [`ntdll.zig`](../../src/libs/ntdll.zig)；合成导出见 [`pe.zig`](../../src/loader/pe.zig) |
| ntdll       | NtAllocateVirtualMemory | Partial | MEM_RESERVE/COMMIT、`#PF` 惰性提交 |
| ntdll       | NtQuerySystemInformation / NtSetSystemInformation | Partial | 多 `SYSTEM_INFORMATION_CLASS` 子集；**nt61_full_api_backlog_anchors_host** §9 |
| ntdll       | NtDeviceIoControlFile / Lock+Unlock VM | Partial | SSDT **0x52–0x54**；RTC IOCTL 子集；VM 锁定为桩 |
| ntdll       | NtOpenProcess / NtOpenThread / NtDuplicateObject / OpenProcessToken / QueryInformationToken | Partial | `CLIENT_ID`；**非提升令牌** `seProcessOpenAllowed` / `seThreadOpenAllowed`；句柄复制防 **扩大访问掩码**；`ProcessImageFileName`（27）+ `ThreadTimes`（1）子集 |
| ntdll       | NtCreateUserProcess（0xAA）/ NtCreateProcess | Partial | ZOA 参数块 + `NtCreateUserProcessFromPath`；`NtCreateProcess` 仅槽位；见 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) |
| ntdll       | NtUserGetMessage / PeekMessage | Partial | SSDT 0x58/0x59；`PeekMessage` 空队列 `STATUS_NO_MORE_ENTRIES` |
| kernelbase  | GetLastError / SetLastError / NtClose（转发） | Partial | [`kernelbase.zig`](../../src/libs/kernelbase.zig)；`kernel32` 转发；TEB+0x68 为长期目标 |
| kernel32    | CreateFileA          | Partial | 见 VFS |
| user32      | GetMessage / DefWindowProc / DispatchMessage | Partial | SC_MOVE 模态环、DWM 广播；`DispatchMessage`：`registerKernelWndProc` + `wndproc_id` 子集；`NtUser*`/`STATUS_PENDING` 见契约矩阵 §5 |
| user32      | SetWindowPos / 桌面切换 | Partial | `HWND_NOTOPMOST` Learn（非 topmost 无 Z 序效果）；`CreateDesktopA`/`OpenDesktopA`/`SwitchDesktopA` ↔ `subsystem`；扩展 `SWP_*` |
| gdi32       | TextOutA             | Partial | 位图字体；FreeType 为路线图 C-T05 |
| gdi32       | Rectangle / FillRect | Partial | 矩形填充子集；与 Aero 脏区合成见 `SOFTWARE_COMPOSITOR_WDDM.md` |
| gdi32       | BitBlt / AlphaBlend  | Partial | ROP 子集见 `gdi_rop_contract.zig`；`AlphaBlend` 仅 `AC_SRC_OVER` 存根 |
| dwmapi      | Vista/7 公开子集（Attribute / Thumbnail / Extend / Blur / Flush / InvalidateIconic） | Partial | [`dwmapi.zig`](../../src/subsystems/win32/dwmapi.zig) + [`dwm_nt61_api_contract.zig`](../../src/config/dwm_nt61_api_contract.zig)；**ABI 清单** [`dwm_nt61_abi_inventory.zig`](../../src/config/dwm_nt61_abi_inventory.zig)；**PE 策略** [DWMAPI_PE_EXPORT_STRATEGY.md](DWMAPI_PE_EXPORT_STRATEGY.md)；**WOW64 布局** [`dwmapi_wow64.zig`](../../src/subsystems/win32/dwmapi_wow64.zig)；主机 **dwm_nt61_abi_inventory_host**、**dwmapi_wow64_host**、**dwm_nt61_api_contract_host**；**阶段 4**：底层 32 位 **Native** `NtConnectPort` / `NtRequestWaitReplyPort` 在 `wow64SyscallStubReturnsSuccess` 中演示成功（**phase4_host_anchors**） |
| csrss / LPC | `register_dwm_listener` v1 + 旧 4 字节 tid | Partial | [`csr_lpc_policy.zig`](../../src/subsystems/win32/csr_lpc_policy.zig)、[`LPC_NT61_HANDSHAKE.md`](LPC_NT61_HANDSHAKE.md)；**csr_lpc_policy_host**、**dwm_messages_nt61_host** |
| video       | GOP vs VirtIO scanout 呈现后端 | Partial | [`display_backend.zig`](../../src/drivers/video/core/display_backend.zig)、[`display.zig`](../../src/drivers/video/core/display.zig)；串口 `present_backend=` |
| pe / exec   | 子系统 DLL 绑定、PE 策略失败码      | Partial | `pe.zig`：`validatePeLoadPolicy`（TLS/delay/bound 目录非空 → `LoadStatus`）、`loadStatusToNtStatus`；`findExportByOrdinal`；预载 `dwmapi` + **ntdll/kernel32/user32** 合成导出（与 [`nt61_core_dll_abi_inventory.zig`](../../src/config/nt61_core_dll_abi_inventory.zig)、[CORE_DLL_PE_EXPORT_STRATEGY.md](CORE_DLL_PE_EXPORT_STRATEGY.md) 一致）；GUI `exec` 绑定 `dwmapi` |
| ntfs / hive | 小文件写、簇大小（hive 路线图） | Partial | [`ntfs.zig`](../../src/fs/ntfs.zig)；**ntfs_hive_minimum_host** |

**状态含义**：`Stub` 仅符号；`Partial` 有部分语义；`Done` 行为与公开文档一致且含测试；`Verified` 有 CI/回归覆盖。
