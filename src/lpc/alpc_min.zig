// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/lpc/alpc_min.zig
// Purpose: **ALPC** 最小类型占位（阶段四；由经典 LPC 端口演进，见 MS Learn ALPC 行为描述）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/alpc

/// ALPC 端口对象类别占位（与 `lpc/port.zig` 的 `PortKind` 并行演进）。
pub const AlpcPortKind = enum { server, client };

/// 将来：`NtAlpcCreatePort` / `NtAlpcConnectPort` 与内核对象管理器接线。
pub const AlpcPortRef = struct {
    kind: AlpcPortKind = .server,
};
