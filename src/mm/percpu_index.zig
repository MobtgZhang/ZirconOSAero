// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/percpu_index.zig
// Purpose: 当前处理器下标存根（置于 `mm/` 以便 `pool`/`lookaside` 单测可导入）；SMP 后由 `KPCR` 接线。
//
// This is an independent clean-room implementation.
// Ref: WDK — per-processor data (behavioral only).

/// 当前 CPU 索引；BSP 单核恒为 0。
pub fn currentCpuIndex() u32 {
    return 0;
}
