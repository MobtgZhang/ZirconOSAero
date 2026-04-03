// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/probe.zig
// Purpose: 用户态指针探测（MmProbeUserMemory 语义子集），供 syscall 与 I/O 路径校验。
//
// This is an independent clean-room implementation.
// Reference: MS Learn — kernel buffer validation concepts (behavioral only); Intel SDM — U/S and #PF。
// 全 syscall 覆盖须与 docs/cn/NT61_CONTRACT_MATRIX.md、MVT 中「用户指针探测」行同步审计。
// 里程碑（K1.5）：新增 Native API 时须在 `arch/*/syscall*.zig` 入口对用户指针做 `probeUserMemory` / `probeUserUnicodeString`；审计清单见 [NT61_CONTRACT_MATRIX.md](../../docs/cn/NT61_CONTRACT_MATRIX.md)（与 P5 门禁一致）。

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;
const vm = @import("vm.zig");

/// 校验 `[va, va+len)` 是否落在用户 canonical 区且每页已映射；`writable` 时检查 PTE/PDE 可写位。
/// 等价于公开文档中 **ProbeForRead** 子集：仅校验映射与 U/S，不修改页状态。
pub fn probeForRead(space: *vm.AddressSpace, va: u64, len: u64) bool {
    return probeUserMemory(space, va, len, false);
}

/// 等价于 **ProbeForWrite** 子集：要求 PTE 可写（若架构提供 `isPageWritable`）。
pub fn probeForWrite(space: *vm.AddressSpace, va: u64, len: u64) bool {
    return probeUserMemory(space, va, len, true);
}

pub fn probeUserMemory(space: *vm.AddressSpace, va: u64, len: u64, writable: bool) bool {
    if (len == 0) return true;
    if (va +% len < va) return false;
    if (builtin.cpu.arch == .x86_64) {
        const last = va +% len -% 1;
        if (va > vm.USER_VA_MAX_HINT_X86_64 or last > vm.USER_VA_MAX_HINT_X86_64)
            return false;
    }
    const ps: u64 = @intCast(paging.page_size);
    var page = va & ~@as(u64, ps - 1);
    const end_incl = va +% len -% 1;
    const last_page = end_incl & ~@as(u64, ps - 1);
    while (true) {
        if (space.getPhysical(page) == null) return false;
        if (writable and @hasDecl(paging, "isPageWritable")) {
            if (!paging.isPageWritable(space.pml4_phys, page)) return false;
        }
        if (page == last_page) break;
        page +%= ps;
    }
    return true;
}

/// 等价于对 `UNICODE_STRING` 头 + buffer 范围的探测（Length 为字节数）。
pub fn probeUserUnicodeString(space: *vm.AddressSpace, unicode_str_va: u64, writable: bool) bool {
    if (unicode_str_va == 0) return false;
    // x86_64 UNICODE_STRING：Length + MaximumLength + 对齐 + Buffer 指针 = 16 字节。
    if (!probeUserMemory(space, unicode_str_va, 16, false)) return false;
    // SAFETY: probeUserMemory 已确认 8 字节可读。
    const us = @as(*const volatile extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: u64,
    }, @ptrFromInt(unicode_str_va));
    const byte_len = us.Length;
    if (byte_len == 0 or byte_len > 4094) return false;
    if (us.Buffer == 0) return false;
    if (!probeUserMemory(space, us.Buffer, byte_len, writable)) return false;
    return true;
}
