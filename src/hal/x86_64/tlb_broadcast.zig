// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/tlb_broadcast.zig
// Purpose: TLB shootdown 占位（BSP 本地刷新 + 未来 IPI 向量扩展）。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM — INVLPG / TLB; MS Learn — multiprocessor TLB invalidation (conceptual).

const paging = @import("../../arch/x86_64/paging.zig");

pub fn flushLocal() void {
    paging.flushTlb();
}

/// 当前无在线 AP 时等价于 `flushLocal`；未来在修改共享页表后向其它 CPU 发 IPI。
pub fn requestGlobalFlushStub() void {
    flushLocal();
}
