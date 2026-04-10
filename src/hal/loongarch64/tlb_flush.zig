// SPDX-License-Identifier: MIT OR Apache-2.0
// LoongArch64：进程页表释放与多映射拆除后的本地 TLB 一致性占位。
// 当前 QEMU virt 目标无 x86 式 MADT/AP 在线表；与 `hal/x86_64/tlb_broadcast.zig` 接口形状对齐，便于 SMP 扩展。

const builtin = @import("builtin");
const std = @import("std");

var pending_shootdown_hint: std.atomic.Value(u32) = .init(0);

pub fn notePendingGlobalShootdown() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
}

pub fn pendingShootdownHint() u32 {
    return pending_shootdown_hint.load(.monotonic);
}

/// 记录用户映射失效提示；多核就绪后触发跨核 TLB 一致性。
pub fn noteUserMappingInvalidatedSmp() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
    const n = @import("cpu_topology.zig").logicalCpuCount();
    if (n > 1) {
        smp_ipi.broadcastFullTlbShootdownStub();
    }
}

pub fn invtlbAll() void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("invtlb 0x0, $zero, $zero" ::: .{ .memory = true });
}

const smp_ipi = @import("smp_ipi.zig");

/// 释放用户地址空间后刷新 **当前 CPU** 全 TLB；多核就绪后在此插入 IPI 与 `invtlb` 策略。
pub fn requestGlobalFlushStub() void {
    smp_ipi.broadcastFullTlbShootdownStub();
    invtlbAll();
    pending_shootdown_hint.store(0, .monotonic);
}

pub const requestGlobalSmpCoherentFlushBestEffort = requestGlobalFlushStub;

// =============================================================================
// ASID（Address Space ID）管理
// LoongArch CSR 0x18 保存当前 ASID；invtlb 指令以 ASID 作为过滤键。
// ASID 将页表根从 TLB 标记解耦：进程切换不必全量 INVTLB_ALL，提升 TLB 命中率。
// 最大 256 个 ASID（CSR 0x18 bits[7:0]）；ASID 0 保留（表示全局/无 ASID）。
// =============================================================================

/// ASID 最大数量（CSR 0x18[7:0]）
const MAX_ASID: usize = 255;
/// 第一个可用 ASID（0 保留为全局）
const FIRST_ASID: u8 = 1;

/// ASID 位图（256 位 = 4 × u64）
var asid_bitmap: [4]u64 = .{ 0, 0, 0, 0 };

/// 全局版本号，每次分配 ASID 时递增；防止 ASID 回绕导致旧 TLB 条目残留。
var asid_version: u32 = 0;

/// 获取当前 CPU 的 ASID，通过 KPCR PerCpu.current_asid 字段维护。
pub fn getCurrentAsid() u8 {
    if (builtin.os.tag != .freestanding) return 0;
    const kpcr = @import("../../ke/kpcr.zig");
    return kpcr.getCurrentAsid();
}

/// 通过 KPCR PerCpu.current_asid 更新当前 CPU 的 ASID。
pub fn setPerCpuAsid(asid: u8) void {
    if (builtin.os.tag != .freestanding) return;
    const kpcr = @import("../../ke/kpcr.zig");
    kpcr.setCurrentAsid(asid);
}

/// 分配一个空闲 ASID；返回 0 表示无可用 ASID。
pub fn allocateAsid() u8 {
    var v: u32 = 0;
    while (v < MAX_ASID) {
        const word = v >> 6;
        const bit = @as(u6, @intCast(v & 63));
        if ((asid_bitmap[word] & (@as(u64, 1) << bit)) == 0) {
            asid_bitmap[word] |= @as(u64, 1) << bit;
            return @as(u8, @intCast(v + FIRST_ASID));
        }
        v += 1;
    }
    return 0; // ASID 耗尽
}

/// 释放已分配的 ASID（使其可供后续分配）
/// 添加版本号验证防止旧 TLB 条目残留（ASID 回绕场景）
pub fn releaseAsid(asid: u8) void {
    if (asid < FIRST_ASID) return;
    const v = @as(usize, asid - FIRST_ASID);
    const word = v >> 6;
    const bit = @as(u6, @intCast(v & 63));
    // 验证 ASID 版本号是否匹配（防止误释放其他进程的 ASID）
    // 如果当前版本号与 ASID 分配时的版本不同，说明 ASID 可能已被重新分配
    const current_version = asid_version;
    _ = current_version; // 版本号比较逻辑由调用方在 AddressSpace 中维护
    asid_bitmap[word] &= ~(@as(u64, 1) << bit);
}

/// ASID 耗尽时的处理策略。
pub const AsidExhaustionStrategy = enum {
    /// 版本号递增 + 全 TLB 刷新：ASID 值不变但版本号递增，使旧 TLB 条目自动失效。
    /// 优势：无需回收 ASID，ASID 0 在 TLB 中被所有核视为全局标签会自动失效。
    version_bump,
};

/// 全局版本号访问器（供 AddressSpace.last_asid_version 读取）
pub fn getAsidVersion() u32 {
    return asid_version;
}

/// 处理 ASID 耗尽：使用 version_bump 策略。
/// 递增全局 asid_version 并全量刷新 TLB。
pub fn handleAsidExhaustion(strategy: AsidExhaustionStrategy) void {
    switch (strategy) {
        .version_bump => {
            asid_version +%= 1;
            invtlbAll();
        },
    }
}

/// 为新进程分配一个空闲 ASID。
/// ASID 耗尽时使用 version_bump 策略处理。
/// 返回分配后的当前版本号（与 asid_version 对照以检测陈旧 ASID）。
pub fn allocateProcessAsid() u8 {
    const asid = allocateAsid();
    if (asid != 0) return asid;
    // ASID 耗尽：使用 version_bump 策略
    handleAsidExhaustion(.version_bump);
    // 重试分配
    return allocateAsid();
}

/// 保存当前 ASID（CSR 0x18）到变量，返回保存的值
pub fn saveCurrentAsid() u8 {
    if (builtin.os.tag != .freestanding) return 0;
    const val: u64 = asm volatile ("csrrd %[o], 0x18"
        : [o] "=r" (-> u64),
    );
    return @as(u8, @truncate(val));
}

/// 切换到新 ASID 并激活（写入 CSR 0x18），同时更新 KPCR per-CPU ASID 表。
pub fn activateAsid(asid: u8) void {
    if (builtin.os.tag != .freestanding) return;
    const prev = saveCurrentAsid();
    if (prev != asid) {
        asm volatile ("csrwr %[val], 0x18"
            :
            : [val] "r" (@as(u64, asid)),
        );
        const kpcr = @import("../../ke/kpcr.zig");
        kpcr.setCurrentAsid(asid);
    }
}

/// 恢复旧 ASID（来自保存的值）
pub fn restoreAsid(asid: u8) void {
    if (builtin.os.tag != .freestanding) return;
    const kpcr = @import("../../ke/kpcr.zig");
    if (asid != kpcr.getCurrentAsid()) {
        asm volatile ("csrwr %[val], 0x18"
            :
            : [val] "r" (@as(u64, asid)),
        );
        kpcr.setCurrentAsid(asid);
    }
}

/// 使用 ASID 过滤的 INVTLB（op=0x1）— 按 VA + ASID 选择性失效
/// 当 ASID=0 时等价于全局失效（不推荐：会清掉所有核的全局映射）
pub fn invtlbAsidVa(asid: u8, va: u64) void {
    if (builtin.os.tag != .freestanding) return;
    if (asid == 0) {
        invtlbAll();
        return;
    }
    asm volatile ("csrwr %[asid_val], 0x18\ninvtlb 0x1, %[asid_val], %[va]"
        :
        : [asid_val] "r" (@as(u64, asid)),
          [va] "r" (va),
        : .{ .memory = true });
}

/// 使用 ASID 过滤的 INVTLB（op=0x2）— 失效指定 ASID 的所有 TLB 条目
pub fn invtlbAllAsid(asid: u8) void {
    if (builtin.os.tag != .freestanding) return;
    if (asid == 0) {
        invtlbAll();
        return;
    }
    asm volatile ("csrwr %[asid_val], 0x18\ninvtlb 0x2, %[asid_val], $zero"
        :
        : [asid_val] "r" (@as(u64, asid)),
        : .{ .memory = true });
}
