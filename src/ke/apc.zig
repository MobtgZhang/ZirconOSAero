// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/apc.zig
// Purpose: **APC（异步过程调用）** 分阶段路线图与占位；与 `DPC` 配套后用于用户态可告警等待、I/O 完成回调等（公开文档行为）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Microsoft Learn — Asynchronous Procedure Calls (APCs)

//! 当前里程碑：**未实现** 内核 APC 队列与 `KiInsertQueueApc` 等价路径。
//! 建议顺序：（1）线程 `KTHREAD` 挂 APC 队列头；（2）`APC_LEVEL` 以下 `KiDeliverApc` 式排空；
//! （3）用户态 APC 仅在 `PASSIVE_LEVEL` 且 `alertable wait` 时交付。见 `docs/cn/NT61_CONTRACT_MATRIX.md`。

pub fn init() void {}
