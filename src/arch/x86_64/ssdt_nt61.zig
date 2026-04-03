// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/ssdt_nt61.zig
// Purpose: Windows NT 6.1 x64 (build 7600) **公开 SSDT 服务索引**子集，供 `syscall` 分发与文档对照。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: 公开 syscall 枚举（如社区维护的 NT 构建版本表 j00ru/windows-syscalls）；本文件仅收录本内核已实现或桩实现的服务号。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K7（扩展须双端 ntdll/syscall + probe）。
// SDK 路径锚点（勿在本文件外重复硬编码 syscall 号）： [sdk/nt61_syscall_numbers_x64.zig](../../../sdk/nt61_syscall_numbers_x64.zig)
//
// **WOW64 / x86 命名空间**：Win7 SP1 x86 服务号子集见 [`subsystems/win32/wow64/ssdt_x86_win7_sp1.zig`](../../subsystems/win32/wow64/ssdt_x86_win7_sp1.zig)；同名 API 的 x86→本表索引对照见 [`subsystems/win32/wow64/x64_semantic_alias.zig`](../../subsystems/win32/wow64/x64_semantic_alias.zig)。验收文档：[`docs/cn/PHASE_G_WOW64.md`](../../../docs/cn/PHASE_G_WOW64.md)。

//! x64 `syscall` 调用约定（与 AMD64 长模式一致）：`RAX`=下表索引；第 1 参在 **`R10`**（因 `RCX` 存返回 RIP）；
//! 第 2–4 参为 `RDX`、`R8`、`R9`；更多参数在**用户栈**上（相对于 SYSCALL 时 `RSP`，第 5 参常为 `+0x28`）。
//! `int 0x80`（向量 128）使用同一 `InterruptFrame` 与同一分发器；调用方须遵守 **NT x64 寄存器约定**（第 1 参在 **R10**），而非 Linux `int 0x80` 风格。

pub const NtClose = 0x0C;
pub const NtWaitForSingleObject = 0x04;
pub const NtAllocateVirtualMemory = 0x18;
pub const NtFreeVirtualMemory = 0x1B;
pub const NtQuerySystemInformation = 0x25;
pub const NtCreateFile = 0x2C;
pub const NtYieldExecution = 0x43;
pub const NtTerminateProcess = 0x29;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1 x64（与 `NtProtectVirtualMemory` 0x4D 区分）。
pub const NtCreateThread = 0x4B;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtProtectVirtualMemory = 0x4D;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtDelayExecution = 0x31;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtOpenKey = 0x0F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryValueKey = 0x14;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateKey = 0x1A;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（与 `NtQueryValueKey` 不同索引）。
pub const NtSetValueKey = 0x5D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtEnumerateKey = 0x32;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtEnumerateValueKey = 0x13;
pub const NtWriteFile = 0x08;
pub const NtReadFile = 0x07;
/// Win32k 在真实 Windows 上为独立服务表；本内核将用户消息 syscall 折叠进同一分发器。
/// `NtUserGetMessage`/`NtUserPeekMessage` 所用 **0x58/0x59** 与 j00ru `nt-per-system.json` 中 ntos **0x58=NtQueryAttributesFile** 等不一致，属本仓库有意折叠命名空间。
/// 下列 **0x5A–0x5C** 同理；括号内为 j00ru `win32k-per-syscall.json` Win7 SP1 x64 **win32k** 服务号（对照用，非本内核 `RAX` 商业等价）。
/// 见 [docs/cn/NT61_FULL_API_BACKLOG.md](../../../docs/cn/NT61_FULL_API_BACKLOG.md) §11、[docs/cn/SyscallABI.md](../../../docs/cn/SyscallABI.md)。
pub const NtUserGetMessage = 0x58;
pub const NtUserPeekMessage = 0x59;
/// win32k 服务 **4111**（NtUserPostMessage）。
pub const NtUserPostMessage = 0x5A;
/// win32k 服务 **4132**（NtUserSetWindowPos）。
pub const NtUserSetWindowPos = 0x5B;
/// 公开表无独立 `NtUserSendMessage`；与 `user32.SendMessageA` 当前简化实现等价。
pub const NtUserSendMessage = 0x5C;
/// 本仓库折叠命名空间：`DispatchMessageA` 内核桩（真实 Windows 在 win32k 服务表另有编号）。
pub const NtUserDispatchMessage = 0x5E;

/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64 `NtReadVirtualMemory`。
pub const NtReadVirtualMemory = 0x3D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64 `NtWriteVirtualMemory`。
pub const NtWriteVirtualMemory = 0x3E;

/// Ref: j00ru/windows-syscalls `nt-per-syscall.json` — Windows 7 SP1 x64.
pub const NtRequestWaitReplyPort = 0x1F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64.
pub const NtConnectPort = 0x8F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64.
pub const NtCreatePort = 0x9D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（早期内核调试输出；本内核可作串口跟踪）。
pub const NtDisplayString = 0xB8;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（节对象；本内核 `section.zig` + `ntdll`）。
pub const NtCreateSection = 0x47;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtMapViewOfSection = 0x48;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtUnmapViewOfSection = 0x2A;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1（与 NtCreatePort 0x9D 等同表）。
pub const NtQueryVirtualMemory = 0x20;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1。
pub const NtOpenProcess = 0x23;
/// Ref: 公开 Windows 7 x64 syscall 列表（如 OpenRCE / j00ru 对照表）；与 SP1 构建对齐。
pub const NtDuplicateObject = 0x44;

// ── 扩展子集（VM/进程/同步/IO；分发器暂返回 `STATUS_NOT_IMPLEMENTED`，与 ntdll 桩渐进接线）──
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateMutant = 0x0B;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtOpenMutant = 0x0D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtReleaseMutant = 0x1E;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryMutant = 0x0E;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryInformationProcess = 0x16;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtSetInformationProcess = 0x1C;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryInformationThread = 0x11;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtSetInformationThread = 0x28;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtResumeThread = 0x51;
/// 与 j00ru `nt.csv` 中 **NtTerminateThread** 在 Win7 SP1 x64 列的公开值 **0x51** 冲突（本仓库 **0x51** 已用于 `NtResumeThread`），
/// 故使用未占用槽 **0x55** 作为 ZOA 内核索引；`x64_semantic_alias` 将 x86 `NtTerminateThread` 映射至此。
pub const NtTerminateThread = 0x55;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtSuspendThread = 0x45;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtAlertThread = 0x22;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtTestAlert = 0x42;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateSemaphore = 0x4F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtOpenSemaphore = 0x15;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtReleaseSemaphore = 0x1D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateEvent = 0x4A;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtOpenEvent = 0x3F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtSetEvent = 0x0A;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtResetEvent = 0x50;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtPulseEvent = 0x3C;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtClearEvent = 0x3B;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtOpenThread = 0x36;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryObject = 0x10;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtOpenFile = 0x33;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtFlushBuffersFile = 0x39;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtFsControlFile = 0x09;
/// Ref: j00ru 表常见 **0x07** 与本仓 `NtReadFile` **0x07** 并存冲突；**0x52** 专用于 `NtDeviceIoControlFile`（见 [SyscallABI.md](../../../docs/cn/SyscallABI.md)）。
pub const NtDeviceIoControlFile = 0x52;
/// Ref: 同上折叠策略；**0x53/0x54** 用于 `NtLockVirtualMemory` / `NtUnlockVirtualMemory` 桩。
pub const NtLockVirtualMemory = 0x53;
pub const NtUnlockVirtualMemory = 0x54;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCancelIoFile = 0x35;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCancelIoFileEx = 0xE9;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64 `NtCreateProcess`（与 `NtCreateUserProcess` 0xAA 区分）。
pub const NtCreateProcess = 0x9F;
/// Ref: j00ru Win7 SP1 x64 公开 **0x58**；本仓库 **0x58** 已用于折叠 `NtUserGetMessage`，故 **0x57** 专用于 `NtWaitForMultipleObjects`（见 `docs/cn/SyscallABI.md`）。
pub const NtWaitForMultipleObjects = 0x57;
/// Ref: j00ru Win7 SP1 x64 公开 **0x59**；本仓库 **0x59** 为 `NtUserPeekMessage`，故 **0x56** 专用于 `NtSetInformationObject`。
pub const NtSetInformationObject = 0x56;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64 `NtSignalAndWaitForSingleObject`。
pub const NtSignalAndWaitForSingleObject = 0x176;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。**已实现** ZOA 子集：`syscall_nt_extras.dispatchNtCreateUserProcess`（参数块见 `ZirconCreateUserProcessArgs`）、[docs/cn/PHASE_F_PROCESS_CREATE.md](../../../docs/cn/PHASE_F_PROCESS_CREATE.md)。
pub const NtCreateUserProcess = 0xAA;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateThreadEx = 0xA5;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtAlpcConnectPort = 0x2D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtAlpcCreatePort = 0x6D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtAlpcSendWaitReceivePort = 0x6E;

const std = @import("std");

test "SSDT NT 6.1 x64 public indices (Win7 SP1 reference)" {
    try std.testing.expect(NtAllocateVirtualMemory == 0x18);
    try std.testing.expect(NtTerminateProcess == 0x29);
    try std.testing.expect(NtCreateThread == 0x4B);
    try std.testing.expect(NtProtectVirtualMemory == 0x4D);
    try std.testing.expect(NtDelayExecution == 0x31);
    try std.testing.expect(NtOpenKey == 0x0F);
    try std.testing.expect(NtQueryValueKey == 0x14);
    try std.testing.expect(NtCreateKey == 0x1A);
    try std.testing.expect(NtSetValueKey == 0x5D);
    try std.testing.expect(NtEnumerateKey == 0x32);
    try std.testing.expect(NtEnumerateValueKey == 0x13);
    try std.testing.expect(NtUnmapViewOfSection == 0x2A);
    try std.testing.expect(NtCreatePort == 0x9D);
    try std.testing.expect(NtConnectPort == 0x8F);
    try std.testing.expect(NtDisplayString == 0xB8);
    try std.testing.expect(NtRequestWaitReplyPort == 0x1F);
    try std.testing.expect(NtCreateSection == 0x47);
    try std.testing.expect(NtMapViewOfSection == 0x48);
    try std.testing.expect(NtQuerySystemInformation == 0x25);
    try std.testing.expect(NtQueryVirtualMemory == 0x20);
    try std.testing.expect(NtOpenProcess == 0x23);
    try std.testing.expect(NtDuplicateObject == 0x44);
    try std.testing.expect(NtReadVirtualMemory == 0x3D);
    try std.testing.expect(NtWriteVirtualMemory == 0x3E);
    try std.testing.expect(NtUserDispatchMessage == 0x5E);
    try std.testing.expect(NtCreateMutant == 0x0B);
    try std.testing.expect(NtOpenThread == 0x36);
    try std.testing.expect(NtQueryInformationProcess == 0x16);
    try std.testing.expect(NtAlpcConnectPort == 0x2D);
    try std.testing.expect(NtCreateProcess == 0x9F);
    try std.testing.expect(NtWaitForMultipleObjects == 0x57);
    try std.testing.expect(NtSetInformationObject == 0x56);
    try std.testing.expect(NtSignalAndWaitForSingleObject == 0x176);
    try std.testing.expect(NtDeviceIoControlFile == 0x52);
    try std.testing.expect(NtLockVirtualMemory == 0x53);
    try std.testing.expect(NtUnlockVirtualMemory == 0x54);
    try std.testing.expect(NtResumeThread == 0x51);
    try std.testing.expect(NtTerminateThread == 0x55);
}
