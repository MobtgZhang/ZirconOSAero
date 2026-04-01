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

/// 当前无在线 AP 时等价于 `flushLocal`。SMP 就绪后：在修改**内核共享**页表项后应经 IPI 触发各核 `INVLPG`/全 TLB 刷新（见 Intel SDM TLB 一致性；本函数暂为 BSP 占位）。
/// `vm.releaseProcessAddressSpace` 在释放他进程页表后调用本函数，避免当前核残留陈旧 global 项（与 PCID/INVPCID 策略见契约矩阵）。
pub fn requestGlobalFlushStub() void {
    flushLocal();
}
