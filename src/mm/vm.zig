//! Virtual Memory Manager
//! NT style: provides address space, map/unmap, permissions
//! Kernel provides mechanism; policy is in user-space services

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../rtl/klog.zig");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;
pub const FrameAllocator = @import("frame.zig").FrameAllocator;
const heap = @import("heap.zig");
const vad_mod = @import("vad.zig");

/// 惰性提交后从文件视图填页（避免 `vm` ↔ `section` 循环依赖；由 `main` 注册）。
var section_lazy_commit_fill_hook: ?*const fn (*AddressSpace, u64) bool = null;

pub fn setSectionLazyCommitFillHook(h: ?*const fn (*AddressSpace, u64) bool) void {
    section_lazy_commit_fill_hook = h;
}

/// 在 `kernel_space.activate()` 之前：`memsetPhysicalPage` 仍走固件/引导 CR3 的恒等映射。
/// 页表 walk 用物理地址指针，但 **清零新帧** 须用固件已映射可写的低 GPA；上限内优先 `allocZeroedBelowMaxPhys`。
var g_paging_alloc_phys_ceiling_exclusive: ?u64 = null;
var g_paging_alloc_low_mem_logged: bool = false;

pub fn setPagingAllocPhysCeilingExclusive(ceiling_exclusive: ?u64) void {
    g_paging_alloc_phys_ceiling_exclusive = ceiling_exclusive;
    if (ceiling_exclusive == null) g_paging_alloc_low_mem_logged = false;
}

/// `mapIdentityByteRange` 统计：x86_64 填 `x86_huge_2m`，LoongArch 填 `la_blocks_32m`，其余为 `leaf_pages`。
pub const IdentityMapStats = struct {
    x86_huge_2m: usize = 0,
    la_blocks_32m: usize = 0,
    leaf_pages: usize = 0,
};

/// 按架构快速建立 **identity** 映射 `[range_start, range_start+range_len)`（`virt==phys`）。
/// - x86_64：优先 2MiB 大页，头尾不足 2MiB 用 4KiB（`mapPage` 遇大页会按需拆分）。
/// - LoongArch：优先 32MiB 整块填第三级表（2048×16KiB），余量逐 `mapPage`。
/// - 其它架构：逐叶映射。
pub fn mapIdentityByteRange(space: *AddressSpace, range_start: u64, range_len: u64, flags: MapFlags) ?IdentityMapStats {
    if (range_len == 0) return IdentityMapStats{};
    if (range_start > std.math.maxInt(u64) - range_len) return null;
    if (klog.DEBUG_MODE and builtin.os.tag == .freestanding)
        klog.debug("VM: identity map begin start=0x%x len=0x%x", .{ range_start, range_len });
    const ps: u64 = @intCast(paging.page_size);
    var va = range_start & ~(ps - 1);
    const range_end = range_start + range_len;
    var st = IdentityMapStats{};
    const pflags = flags.toPagingFlags();
    var progress: usize = 0;

    while (va < range_end) {
        if (build_options.debug and builtin.mode == .Debug) {
            progress +%= 1;
            if ((progress & 0x3FFF) == 0) {
                klog.info("VM: identity map progress va=0x%x / end=0x%x", .{ va, range_end });
            }
        }
        if ((builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) and @hasDecl(paging, "map2MiBPage") and @hasDecl(paging, "HUGE_PAGE_SIZE")) {
            const huge: u64 = paging.HUGE_PAGE_SIZE;
            if ((va % huge) == 0 and va <= std.math.maxInt(u64) - huge and va + huge <= range_end) {
                if (paging.map2MiBPage(space.pml4_phys, va, va, pflags, allocFrameCb, space.allocator)) {
                    st.x86_huge_2m += 1;
                    va += huge;
                    continue;
                }
            }
        }
        if ((builtin.cpu.arch == .loongarch64 or builtin.cpu.arch == .mips64el) and
            @hasDecl(paging, "mapIdentity32MiBlock") and
            @hasDecl(paging, "identity_bulk_bytes"))
        {
            const blk: u64 = paging.identity_bulk_bytes;
            if ((va % blk) == 0 and va <= std.math.maxInt(u64) - blk and va + blk <= range_end) {
                if (paging.mapIdentity32MiBlock(space.pml4_phys, va, pflags, allocFrameCb, space.allocator)) {
                    st.la_blocks_32m += 1;
                    va += blk;
                    continue;
                }
            }
        }
        if (!space.mapPage(va, va, flags)) return null;
        st.leaf_pages += 1;
        if (va > std.math.maxInt(u64) - ps) return null;
        va += ps;
    }
    return st;
}

pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    executable: bool = true,
    no_cache: bool = false,

    pub fn toPagingFlags(self: MapFlags) u64 {
        var f: u64 = paging.Present | paging.Accessed;
        if (self.writable) f |= paging.Write;
        if (self.user) f |= paging.User;
        if (!self.executable) f |= paging.NoExecute;
        if (self.no_cache) f |= paging.CacheDisable;
        return f;
    }
};

const user_va_policy = @import("vm_user_va_policy.zig");
pub const USER_VA_MAX_HINT_X86_64 = user_va_policy.USER_VA_MAX_HINT_X86_64;
pub const USER_VA_MIN_X64_NT = user_va_policy.USER_VA_MIN_X64_NT;
pub const USER_VA_MAX_X64_NT = user_va_policy.USER_VA_MAX_X64_NT;
pub const USER_VA_MIN_LA_NT = user_va_policy.USER_VA_MIN_LA_NT;
pub const USER_VA_MAX_LA_NT = user_va_policy.USER_VA_MAX_LA_NT;
pub const USER_VA_MIN_NT61 = user_va_policy.USER_VA_MIN_NT61;
pub const USER_VA_MAX_NT61 = user_va_policy.USER_VA_MAX_NT61;
pub const userVaRangeAllowedX64 = user_va_policy.userVaRangeAllowedX64;
pub const userVaRangeAllowedLa64 = user_va_policy.userVaRangeAllowedLa64;
pub const userVaRangeAllowedMips64 = user_va_policy.userVaRangeAllowedMips64;
pub const userVaRangeAllowedNt61 = user_va_policy.userVaRangeAllowedNt61;
pub const USER_VA_MIN_MIPS64_NT = user_va_policy.USER_VA_MIN_MIPS64_NT;
pub const USER_VA_MAX_MIPS64_NT = user_va_policy.USER_VA_MAX_MIPS64_NT;

/// NT 6.1 虚拟分配阶段（公开文档：`ZwAllocateVirtualMemory` / `VirtualAlloc` 的 MEM_RESERVE vs MEM_COMMIT）。
/// - **Reserved**：VA 区间计入地址空间，无页表 Present / 无物理页。
/// - **Committed**：页表项有效并具备后备（匿名页或段视图）。
/// 当前内核中 `mapPage` / `mapPageAlloc` / `mapRange` 表示已提交映射；独占式 VAD + 先 reserve 再按需 commit 为后续里程碑。
/// 矩阵与惰性提交：`tryLazyCommitFault` / `fork_cow_share_nt61_host`；见 `docs/cn/MVT_NT61.md`。
pub const VirtualCommitPhase = enum(u8) {
    reserved = 0,
    committed = 1,
};

/// 与 `NtAllocateVirtualMemory` 常见失败分类的语义对应（返回值仍用 `NtStatus` 在 syscall 层映射）。
pub const VirtualAllocFailureKind = enum(u8) {
    none = 0,
    invalid_parameter = 1,
    no_memory = 2,
    conflicting_addresses = 3,
    access_denied = 4,
    not_committed = 5,
};

/// 当前内核地址空间（供 PCI MMIO / VirtIO 等在驱动层做 identity map）
var g_kernel_space: ?*AddressSpace = null;

pub fn bindKernelAddressSpace(space: *AddressSpace) void {
    g_kernel_space = space;
}

pub fn kernelAddressSpace() ?*AddressSpace {
    return g_kernel_space;
}

/// 将内核 `AddressSpace` 的 PML4 槽 **256..512**（canonical 高半区入口）复制到进程页表，使 `CR3` 切换后仍可达内核映射。
/// 与 `paging.releaseUserHalfAddressSpace` 仅回收 **0..256** 一致；子进程 PML4 与内核 **共享** 高半区所指 PDPT/PD/PT 物理帧（不复制整棵子树）。
/// Ref: Intel SDM — 4-level paging；行为描述见 `docs/cn/VM_ISOLATION.md`。
/// LoongArch64：复制 PGD **[kernel_linked_l0_begin, 2048)**（见 `docs/specs/MemoryManagement_NT61_LoongArch64_NewWorld.md`）。
pub fn linkKernelHalfMappings(dst: *AddressSpace) bool {
    const ks = kernelAddressSpace() orelse return false;
    if (builtin.cpu.arch == .x86_64) {
        // 恒等映射下 PML4 物理页可解引用（与 `unmapPage` / `translateVirtualToPhysical` 路径一致）。
        const dst_pml4: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
        const src_pml4: *paging.PageTable = @ptrFromInt(ks.pml4_phys);
        var i: usize = 256;
        while (i < 512) : (i += 1) {
            dst_pml4.entries[i] = src_pml4.entries[i];
        }
        return true;
    }
    if (builtin.cpu.arch == .loongarch64) {
        const dst_pgd: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
        const src_pgd: *paging.PageTable = @ptrFromInt(ks.pml4_phys);
        var i: usize = paging.kernel_linked_l0_begin;
        while (i < 2048) : (i += 1) {
            dst_pgd.entries[i] = src_pgd.entries[i];
        }
        return true;
    }
    if (builtin.cpu.arch == .aarch64) {
        const dst_pgd: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
        const src_pgd: *paging.PageTable = @ptrFromInt(ks.pml4_phys);
        var i: usize = paging.kernel_linked_l0_begin;
        while (i < 512) : (i += 1) {
            dst_pgd.entries[i] = src_pgd.entries[i];
        }
        return true;
    }
    if (builtin.cpu.arch == .mips64el) {
        const dst_pgd: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
        const src_pgd: *paging.PageTable = @ptrFromInt(ks.pml4_phys);
        var i: usize = paging.kernel_linked_l0_begin;
        while (i < 512) : (i += 1) {
            dst_pgd.entries[i] = src_pgd.entries[i];
        }
        return true;
    }
    return true;
}

fn freeFrameForRelease(ctx: ?*anyopaque, phys: u64) void {
    const a = ctx orelse return;
    const fa: *FrameAllocator = @ptrCast(@alignCast(a));
    fa.free(phys);
}

/// 释放进程 **用户半区** 页表子树与叶帧，并 `free` 顶层 PML4；调用方须将 `AddressSpace` 置为不再使用且 **不得** 再以该 CR3 运行。
/// 调用方还须保证 **无** 仍在运行的线程持有该 `pml4_phys` 作为当前 CR3（见 `ps/process.zig` `terminateProcess` 与调度器配合）。
pub fn releaseProcessAddressSpace(space: *AddressSpace) void {
    // 多核：拆除整棵用户子树前记录 shootdown 提示；`releaseUserHalf` 内部逐页路径亦会在 `unmapRange` 中递增（K1.4/K2.5）。
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        const tlb = @import("../hal/x86_64/tlb_broadcast.zig");
        tlb.notePendingGlobalShootdown();
        tlb.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding) {
        const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
        tlb_la.notePendingGlobalShootdown();
        tlb_la.noteUserMappingInvalidatedSmp();
        // 进程销毁时回收 ASID（仅在 ASID 已分配且版本仍有效时回收）。
        if (space.asid != 0 and space.last_asid_version == tlb_la.getAsidVersion()) {
            tlb_la.releaseAsid(space.asid);
            space.asid = 0;
        }
    }
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .freestanding) {
        const tlb_a64 = @import("../hal/aarch64/tlb_flush.zig");
        tlb_a64.notePendingGlobalShootdown();
        tlb_a64.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .mips64el and builtin.os.tag == .freestanding) {
        const tlb_mips = @import("../hal/mips64el/tlb_flush.zig");
        tlb_mips.notePendingGlobalShootdown();
        tlb_mips.noteUserMappingInvalidatedSmp(0);
    }
    if (@hasDecl(paging, "releaseUserHalfAddressSpace")) {
        paging.releaseUserHalfAddressSpace(space.pml4_phys, freeFrameForRelease, @ptrCast(space.allocator));
    }
    space.vad.clear();
    space.reserved_count = 0;
    @memset(&space.reserved_base, 0);
    @memset(&space.reserved_pages, 0);
    space.section_view_count = 0;
    @memset(&space.section_view_base, 0);
    @memset(&space.section_view_pages, 0);
    @memset(&space.section_view_obj, 0);
    @memset(&space.section_view_file_off, 0);
    @memset(&space.section_view_token, 0);
    @memset(&space.section_view_is_image, false);
    @memset(&space.section_view_protect, 0);
    space.vma_len = 0;
    @memset(&space.vma_base, 0);
    @memset(&space.vma_pages, 0);
    @memset(&space.vma_user, false);
    @memset(&space.vma_writable, false);
    space.allocator.free(space.pml4_phys);
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        const tlb = @import("../hal/x86_64/tlb_broadcast.zig");
        tlb.requestGlobalFlushStub();
    }
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding) {
        const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
        tlb_la.requestGlobalFlushStub();
    }
    if (builtin.cpu.arch == .mips64el and builtin.os.tag == .freestanding) {
        const tlb_mips = @import("../hal/mips64el/tlb_flush.zig");
        tlb_mips.requestGlobalFlushStub();
    }
}

fn vmaRangeEnd(base: u64, num_pages: u32) u64 {
    return base + @as(u64, num_pages) * @as(u64, @intCast(paging.page_size));
}

fn vmaOverlaps(a0: u64, a1: u64, b0: u64, b1: u64) bool {
    return !(a1 <= b0 or b1 <= a0);
}

/// Win32 `PAGE_*` → 当前 `arch.impl.paging` 叶 PTE 标志（用户页；x86 与 LoongArch 符号名对齐）。未覆盖的组合返回 `null`。
fn ntProtectToPteFlags(prot: u32) ?u64 {
    const base = paging.Present | paging.User | paging.Accessed;
    return switch (prot) {
        0x02 => base | paging.NoExecute,
        0x04, 0x08 => base | paging.Write | paging.NoExecute,
        0x10, 0x20 => base,
        // PAGE_EXECUTE_READWRITE：W^X 下降为可执行可读、不可写。
        0x40 => base,
        // PAGE_EXECUTE_WRITECOPY（0x80）：与 0x40 相同处理。
        0x80 => base,
        else => null,
    };
}

/// Win32 `PAGE_*` → `MapFlags`（用户区）。
pub fn mapFlagsFromNtProtect(prot: u32) MapFlags {
    var writable = (prot & 0xCC) != 0;
    // 可执行：`PAGE_EXECUTE*` 占位 0x10–0x80（含 `PAGE_EXECUTE_WRITECOPY`=0x80，不在 0x70 掩码内）。
    const executable = ((prot & 0xF0) >= 0x10);
    // W^X：用户叶不允许同时可写且可执行（缓解 shellcode）；需自修改代码时用先 RW 再 RX 切换。
    if (writable and executable) writable = false;
    return .{ .writable = writable, .user = true, .executable = executable };
}

/// NT6.1 风格的虚拟内存分配（MEM_RESERVE / MEM_COMMIT 路径）。
/// 测试存根：验证 API 存在性；实际实现在 syscall 层。
/// 参数：
/// - `space`：目标地址空间
/// - `base_hint`：建议基址（0 表示由系统选择）
/// - `size`：分配大小（页对齐）
/// - `alloc_type`：MEM_RESERVE(0x00002000) | MEM_COMMIT(0x00001000) | MEM_TOP_DOWN(0x00100000)
/// - `protect`：PAGE_READWRITE(0x04) 等
/// 返回：实际分配的基址（失败时为 0）
pub fn NtAllocateVirtualMemory(
    space: *AddressSpace,
    base_hint: u64,
    size: u64,
    alloc_type: u32,
    protect: u32,
) u64 {
    _ = space;
    _ = base_hint;
    _ = size;
    _ = alloc_type;
    _ = protect;
    return 0;
}

/// 通用 VMA 槽位（与 `MEM_RESERVE` 记录互补；供 `NtAllocateVirtualMemory` 等逐步接线）。
pub const max_vma: usize = 48;

pub const VmAreaDesc = struct {
    user: bool,
    writable: bool,
    from_reserved_record: bool,
};

pub fn vmaInsert(space: *AddressSpace, base: u64, num_pages: u32, user: bool, writable: bool) bool {
    if (num_pages == 0 or space.vma_len >= max_vma) return false;
    if (user) {
        const ps: u64 = @intCast(paging.page_size);
        if (ps != 0 and @as(u64, num_pages) > std.math.maxInt(u64) / ps) return false;
        const span = @as(u64, num_pages) * ps;
        if (!userVaRangeAllowedNt61(base, span)) return false;
    }
    const end = vmaRangeEnd(base, num_pages);
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (vmaOverlaps(base, end, b, e)) return false;
    }
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const e = vmaRangeEnd(b, space.reserved_pages[ri]);
        if (vmaOverlaps(base, end, b, e)) return false;
    }
    const slot = space.vma_len;
    space.vma_base[slot] = base;
    space.vma_pages[slot] = num_pages;
    space.vma_user[slot] = user;
    space.vma_writable[slot] = writable;
    space.vma_len += 1;
    return true;
}

pub fn vmaRemove(space: *AddressSpace, base: u64, num_pages: u32) bool {
    if (num_pages == 0) return false;
    const end = vmaRangeEnd(base, num_pages);
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (b == base and e == end) {
            const last = space.vma_len - 1;
            space.vma_base[i] = space.vma_base[last];
            space.vma_pages[i] = space.vma_pages[last];
            space.vma_user[i] = space.vma_user[last];
            space.vma_writable[i] = space.vma_writable[last];
            space.vma_len -= 1;
            return true;
        }
    }
    return false;
}

pub fn vmaFind(space: *const AddressSpace, va: u64) ?VmAreaDesc {
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (va >= b and va < e) {
            return .{
                .user = space.vma_user[i],
                .writable = space.vma_writable[i],
                .from_reserved_record = false,
            };
        }
    }
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const e = vmaRangeEnd(b, space.reserved_pages[ri]);
        if (va >= b and va < e) {
            return .{
                .user = true,
                .writable = true,
                .from_reserved_record = true,
            };
        }
    }
    return null;
}

/// 将 `[phys_base, phys_base+size)` 按页做 identity 映射（MMIO：可写、不可执行、uncached）
/// Intel 核显 BAR、VirtIO PCI 等均须经此路径或 `remapIdentityVirtPageUncached`，避免 WB 缓存导致 MMIO 读写异常。
pub fn mapDeviceMmioIdentity(phys_base: u64, size: u64) bool {
    // 尚无内核页表时（如仍沿用 UEFI 映射）：假定固件已映射 MMIO，跳过以免阻塞 VirtIO attach
    const space = g_kernel_space orelse return true;
    if (size == 0) return true;
    const page_size_u: u64 = @intCast(paging.page_size);
    if (phys_base > std.math.maxInt(u64) - size) return false;
    const sum = phys_base + size;
    if (sum > std.math.maxInt(u64) - (page_size_u - 1)) return false;
    const page_size = paging.page_size;
    const start = phys_base & ~@as(u64, page_size - 1);
    const end = (sum + page_size_u - 1) & ~@as(u64, page_size_u - 1);
    var addr = start;
    const flags = MapFlags{ .writable = true, .executable = false, .no_cache = true };
    while (addr < end) {
        var advanced = false;
        if (space.mapPage(addr, addr, flags)) {
            advanced = true;
        } else if (space.getPhysical(addr)) |p| {
            if (p == addr) {
                // LoongArch 等：启动时整段 identity 映射已为 WB/CC，须改为非缓存才能可靠访问 PCI BAR / VirtIO MMIO
                _ = space.unmapPage(addr);
                if (!space.mapPage(addr, addr, flags)) return false;
                advanced = true;
            }
        }
        if (!advanced) return false;
        if (addr > std.math.maxInt(u64) - page_size_u) return false;
        addr += page_size_u;
    }
    return true;
}

/// 当前内核页表下虚址对应的物理地址（VirtIO 环须用 GPA）；无绑定页表时假定 identity。
pub fn kernelVirtToPhys(virt: usize) usize {
    const space = g_kernel_space orelse return virt;
    return space.getPhysical(virt) orelse virt;
}

/// 将已 identity 映射的内核页改为非缓存，使 PCI DMA 与 CPU 对同一 GPA 的观测一致（见 H7：VA≠PA 时仅修正 GPA 仍不足）。
/// VirtIO-Input 事件环页在 LoongArch 上经 `virtio_input_pci.remapInstQueueDmaUncached` 整页调用本函数。
pub fn remapIdentityVirtPageUncached(virt: usize) bool {
    const space = g_kernel_space orelse return true;
    const page_size = paging.page_size;
    const va = virt & ~@as(usize, page_size - 1);
    const phys = space.getPhysical(va) orelse return false;
    _ = space.unmapPage(va);
    return space.mapPage(va, phys, .{ .writable = true, .executable = false, .no_cache = true });
}

/// 将 `[virt_base, virt_base+size)` 覆盖到的各页改为 **identity、可写、非缓存**（LoongArch：MAT_WUC）。
/// UEFI GOP / ramfb 扫描输出通常不经 CPU cache 一致性；若整段 identity 映射为 CC，桌面写入可能留在 cache，QEMU 仍显示固件画面。
pub fn remapIdentityRangeUncached(virt_base: usize, size: usize) bool {
    const space = g_kernel_space orelse return true;
    if (size == 0) return true;
    const ps = paging.page_size;
    if (virt_base > std.math.maxInt(usize) - size) return false;
    const end = virt_base + size;
    const va0 = virt_base & ~@as(usize, ps - 1);
    const ps_u: usize = ps;
    if (end > std.math.maxInt(usize) - (ps_u - 1)) return false;
    const va1 = (end + ps_u - 1) & ~@as(usize, ps_u - 1);
    var va = va0;
    while (va < va1) {
        const phys = space.getPhysical(va) orelse return false;
        _ = space.unmapPage(va);
        if (!space.mapPage(va, phys, .{ .writable = true, .executable = false, .no_cache = true }))
            return false;
        if (va > std.math.maxInt(usize) - ps_u) return false;
        va += ps_u;
    }
    if (@hasDecl(paging, "loadCr3")) {
        paging.loadCr3(space.pml4_phys);
    }
    return true;
}

pub const max_reserved_regions: usize = 32;
pub const max_section_views: usize = 32;

/// `NtMapViewOfSection` 登记时分配的单调 token（与句柄无关；见 `LPC_NT61_HANDSHAKE.md` section_view 绑定）。
var g_section_view_token_seq: std.atomic.Value(u32) = .init(1);

pub fn sectionViewTokenSeqNextValue() u32 {
    return g_section_view_token_seq.load(.monotonic);
}

/// Win32 内存保护常量子集（`AddressSpace` 方法引用）。
pub const PAGE_NOACCESS: u32 = 0x01;
pub const PAGE_READONLY: u32 = 0x02;
pub const PAGE_READWRITE: u32 = 0x04;
/// Ref: https://learn.microsoft.com/windows/win32/memory/memory-protection-constants
pub const PAGE_GUARD: u32 = 0x100;
pub const MEM_PRIVATE: u32 = 0x20000;
/// Ref: Learn — memory types for `MEMORY_BASIC_INFORMATION`.
pub const MEM_MAPPED: u32 = 0x40000;
pub const MEM_IMAGE: u32 = 0x1000000;

pub const AddressSpace = struct {
    pml4_phys: u64,
    /// LoongArch64 ASID（CSR 0x5）；0 表示未分配；仅在 freestanding + loongarch64 时有效。
    asid: u8 = 0,
    /// 记录 ASID 分配时的全局版本号，用于检测版本回绕导致 ASID 陈旧。
    last_asid_version: u32 = 0,
    allocator: *FrameAllocator,
    /// VAD 有序表（Reserve/Commit 元数据；与 `reserved_*` 同步维护）。
    vad: vad_mod.VadTable = .{},
    /// `MEM_RESERVE` 未提交区间（无 Present PTE）；与 `#PF` 惰性提交配合。
    reserved_count: u8 = 0,
    reserved_base: [max_reserved_regions]u64 = @splat(0),
    reserved_pages: [max_reserved_regions]u32 = @splat(0),
    /// `NtMapViewOfSection` 登记的区间，供 `NtUnmapViewOfSection` 成组解除映射。
    section_view_count: u8 = 0,
    section_view_base: [max_section_views]u64 = @splat(0),
    section_view_pages: [max_section_views]u32 = @splat(0),
    section_view_obj: [max_section_views]u64 = @splat(0),
    section_view_token: [max_section_views]u32 = @splat(0),
    /// `NtMapViewOfSection` 时文件视图的起始字节偏移（惰性填页用）。
    section_view_file_off: [max_section_views]u64 = @splat(0),
    /// 与 `section_view_*` 行对齐：`SEC_IMAGE` 视图在 `MEMORY_BASIC_INFORMATION.Type` 中报告 `MEM_IMAGE`。
    section_view_is_image: [max_section_views]bool = @splat(false),
    /// 映射时的 Win32 `PAGE_*`（供 `NtQueryVirtualMemory`）。
    section_view_protect: [max_section_views]u32 = @splat(0),
    /// 显式 VMA 记录（与 `reserved_*` 不重复登记：reserve 仅走 `reserved_*`；`vmaInsert` 用于已映射或其它视图）。
    vma_len: u8 = 0,
    vma_base: [max_vma]u64 = @splat(0),
    vma_pages: [max_vma]u32 = @splat(0),
    vma_user: [max_vma]bool = @splat(false),
    vma_writable: [max_vma]bool = @splat(false),

    pub fn reserveVirtualRange(self: *AddressSpace, virt_base: u64, num_pages: u32, nt_protect: u32) bool {
        if (self.reserved_count >= max_reserved_regions) return false;
        if (num_pages == 0) return false;
        const ps: u64 = @intCast(paging.page_size);
        const span = @as(u64, num_pages) * ps;
        if (!userVaRangeAllowedNt61(virt_base, span)) return false;
        const end_excl = virt_base + span;
        const is_guard = (nt_protect & PAGE_GUARD) != 0;
        if (!self.vad.insert(virt_base, end_excl, .reserved, nt_protect, is_guard)) return false;
        const i = self.reserved_count;
        self.reserved_base[i] = virt_base;
        self.reserved_pages[i] = num_pages;
        self.reserved_count += 1;
        return true;
    }

    fn removeReservedCovering(self: *AddressSpace, virt_base: u64, num_pages: u64) void {
        if (num_pages == 0) return;
        const ps: u64 = @intCast(paging.page_size);
        if (num_pages > std.math.maxInt(u64) / ps) return;
        const span = num_pages * ps;
        if (virt_base > std.math.maxInt(u64) - span) return;
        const end = virt_base + span;
        var i: u8 = 0;
        while (i < self.reserved_count) {
            const b = self.reserved_base[i];
            const rp = @as(u64, self.reserved_pages[i]);
            if (ps != 0 and rp > std.math.maxInt(u64) / ps) {
                i += 1;
                continue;
            }
            const n = rp * ps;
            if (b > std.math.maxInt(u64) - n) {
                i += 1;
                continue;
            }
            const e = b + n;
            if (b == virt_base and e == end) {
                const last = self.reserved_count - 1;
                self.reserved_base[i] = self.reserved_base[last];
                self.reserved_pages[i] = self.reserved_pages[last];
                self.reserved_count -= 1;
                _ = self.vad.removeExact(virt_base, @intCast(num_pages));
                continue;
            }
            i += 1;
        }
    }

    /// 若 `fault_va` 落在某 `MEM_RESERVE` 区间内且尚无 PTE，则提交一页匿名映射。
    /// `is_write`：为 false 时 **不** 提交 `PAGE_GUARD` 保护页（栈增长写时提交）。
    pub fn tryLazyCommitFault(self: *AddressSpace, fault_va: u64, is_write: bool) bool {
        const page_size = paging.page_size;
        const page = fault_va & ~@as(u64, page_size - 1);
        if (self.getPhysical(page)) |_| return false;

        if (self.vad.findReservedContaining(fault_va)) |ve| {
            if (ve.is_guard and !is_write) return false;
            const flags = mapFlagsFromNtProtect(ve.protect);
            if (self.mapPageAlloc(page, flags)) |_| {
                self.vad.upgradeReservedContaining(fault_va);
                if (section_lazy_commit_fill_hook) |h| _ = h(self, page);
                return true;
            }
            return false;
        }

        const psz: u64 = @intCast(page_size);
        var ri: u8 = 0;
        while (ri < self.reserved_count) : (ri += 1) {
            const b = self.reserved_base[ri];
            const rp = @as(u64, self.reserved_pages[ri]);
            if (psz != 0 and rp > std.math.maxInt(u64) / psz) continue;
            const span = rp * psz;
            if (b > std.math.maxInt(u64) - span) continue;
            const e = b + span;
            if (fault_va >= b and fault_va < e) {
                const flags = MapFlags{ .writable = true, .user = true, .executable = false };
                if (self.mapPageAlloc(page, flags)) |_| {
                    self.vad.upgradeReservedContaining(fault_va);
                    if (section_lazy_commit_fill_hook) |h| _ = h(self, page);
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    pub fn mapPage(self: *AddressSpace, virt: u64, phys: u64, flags: MapFlags) bool {
        if (flags.user) {
            const ps: u64 = @intCast(paging.page_size);
            if (!userVaRangeAllowedNt61(virt, ps)) return false;
        }
        return paging.mapPage(
            self.pml4_phys,
            virt,
            phys,
            flags.toPagingFlags(),
            allocFrameCb,
            self.allocator,
        );
    }

    pub fn mapPageAlloc(self: *AddressSpace, virt: u64, flags: MapFlags) ?u64 {
        if (flags.user) {
            const ps: u64 = @intCast(paging.page_size);
            if (!userVaRangeAllowedNt61(virt, ps)) return null;
        }
        const panic_ctx = @import("../rtl/panic_context.zig");
        panic_ctx.setPhase(0x0005_0130);
        const phys = self.allocator.allocZeroed() orelse {
            panic_ctx.setPhase(0);
            return null;
        };
        panic_ctx.setPhase(0x0005_0131);
        if (!self.mapPage(virt, phys, flags)) {
            panic_ctx.setPhase(0x0005_0132);
            self.allocator.free(phys);
            panic_ctx.setPhase(0);
            return null;
        }
        // 成功：保持非零 phase 直至调用方（如 kuser）推进到 0122+，避免 panic 窗口内 getPhase()==0。
        panic_ctx.setPhase(0x0005_0133);
        return phys;
    }

    /// `NtProtectVirtualMemory` 路径：按 Win32 `PAGE_*` 更新已映射叶项。未映射页返回 `false`。
    /// Ref: https://learn.microsoft.com/windows/win32/memory/memory-protection-constants
    pub fn protectVirtualRange(self: *AddressSpace, base: u64, size_bytes: u64, new_protect: u32) bool {
        if (size_bytes == 0) return false;
        if (!userVaRangeAllowedNt61(base, size_bytes)) return false;
        if (!@hasDecl(paging, "protectLeafPage")) return false;
        const pte_flags = ntProtectToPteFlags(new_protect) orelse return false;
        const ps: u64 = @intCast(paging.page_size);
        var va = base & ~(ps - 1);
        if (base > std.math.maxInt(u64) - size_bytes) return false;
        const end = base + size_bytes;
        while (va < end) {
            if (!paging.protectLeafPage(
                self.pml4_phys,
                va,
                pte_flags,
                allocFrameCb,
                @ptrCast(self.allocator),
            )) return false;
            if (va > std.math.maxInt(u64) - ps) return false;
            va += ps;
        }
        return true;
    }

    pub fn unmapPage(self: *AddressSpace, virt: u64) ?u64 {
        const phys = self.getPhysical(virt) orelse return null;
        _ = paging.unmapPage(self.pml4_phys, virt, allocFrameCb, @ptrCast(self.allocator));
        return phys;
    }

    pub fn unmapAndFree(self: *AddressSpace, virt: u64) bool {
        const phys = self.unmapPage(virt) orelse return false;
        self.allocator.free(phys);
        return true;
    }

    pub fn getPhysical(self: *AddressSpace, virt: u64) ?u64 {
        if (@hasDecl(paging, "translateVirtualToPhysical")) {
            return paging.translateVirtualToPhysical(self.pml4_phys, virt);
        }
        const v = paging.VirtAddr{ .value = virt };
        const pml4 = @as(*paging.PageTable, @ptrFromInt(self.pml4_phys));
        const pml4e = &pml4.entries[v.pml4Index()];
        if (!pml4e.isPresent()) return null;
        const pdpt = @as(*paging.PageTable, @ptrFromInt(pml4e.toFrame()));
        const pdpte = &pdpt.entries[v.pdptIndex()];
        if (!pdpte.isPresent()) return null;
        const pd = @as(*paging.PageTable, @ptrFromInt(pdpte.toFrame()));
        const pde = &pd.entries[v.pdIndex()];
        if (!pde.isPresent()) return null;
        const pt = @as(*paging.PageTable, @ptrFromInt(pde.toFrame()));
        const pte = &pt.entries[v.ptIndex()];
        if (!pte.isPresent()) return null;
        return pte.toFrame() | (virt & paging.page_mask);
    }

    pub fn activate(self: *AddressSpace) void {
        paging.loadCr3(self.pml4_phys);
        // LoongArch64：进程用户半区切换时激活其 ASID，使 TLB 选择性刷新生效。
        // 内核空间 asid=0，跳过激活（ASID 0 保留）。
        // 其他架构无 ASID 概念，activateAsid 为空操作。
        if (builtin.cpu.arch == .loongarch64 and self.asid != 0) {
            const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
            // 版本检查：若全局 asid_version 已递增，说明当前 ASID 的 TLB 条目已被全局刷新失效。
            // 降级为全 TLB 刷新以确保正确性（性能损失但正确性优先）。
            if (self.last_asid_version != tlb_la.getAsidVersion()) {
                tlb_la.invtlbAll();
            }
            tlb_la.activateAsid(self.asid);
        }
    }

    pub fn recordSectionView(self: *AddressSpace, base: u64, pages: u32, sec_ptr: u64, file_start_off: u64, is_image_section: bool, nt_page_protect: u32) bool {
        if (self.section_view_count >= max_section_views) return false;
        const i = self.section_view_count;
        self.section_view_base[i] = base;
        self.section_view_pages[i] = pages;
        self.section_view_obj[i] = sec_ptr;
        self.section_view_file_off[i] = file_start_off;
        self.section_view_is_image[i] = is_image_section;
        self.section_view_protect[i] = nt_page_protect;
        self.section_view_token[i] = g_section_view_token_seq.fetchAdd(1, .monotonic);
        self.section_view_count += 1;
        return true;
    }

    pub fn sectionViewTokenAt(self: *const AddressSpace, base: u64) ?u32 {
        var i: u8 = 0;
        while (i < self.section_view_count) : (i += 1) {
            if (self.section_view_base[i] == base) return self.section_view_token[i];
        }
        return null;
    }

    /// 按视图基址查找并移除记录，返回页数。
    pub fn takeSectionView(self: *AddressSpace, base: u64) ?u32 {
        var i: u8 = 0;
        while (i < self.section_view_count) : (i += 1) {
            if (self.section_view_base[i] == base) {
                const pages = self.section_view_pages[i];
                const last = self.section_view_count - 1;
                self.section_view_base[i] = self.section_view_base[last];
                self.section_view_pages[i] = self.section_view_pages[last];
                self.section_view_obj[i] = self.section_view_obj[last];
                self.section_view_file_off[i] = self.section_view_file_off[last];
                self.section_view_is_image[i] = self.section_view_is_image[last];
                self.section_view_protect[i] = self.section_view_protect[last];
                self.section_view_token[i] = self.section_view_token[last];
                self.section_view_count -= 1;
                return pages;
            }
        }
        return null;
    }
};

fn allocFrameCb(ctx: ?*anyopaque) ?u64 {
    const fa: *FrameAllocator = @ptrCast(@alignCast(ctx orelse return null));
    if (g_paging_alloc_phys_ceiling_exclusive) |ceil| {
        if (fa.allocZeroedBelowMaxPhys(ceil)) |p| return p;
        if (!g_paging_alloc_low_mem_logged) {
            g_paging_alloc_low_mem_logged = true;
            klog.err("VM: paging frame alloc below GPA 0x{x} exhausted (pre-activate); need more free frames under firmware identity map", .{ceil});
        }
        return null;
    }
    return fa.allocZeroed();
}

/// 记录已映射的提交区（`MEM_COMMIT`），供 `NtQueryVirtualMemory`。
pub fn recordCommittedVadRange(space: *AddressSpace, virt_base: u64, num_pages: u32, nt_protect: u32) void {
    if (num_pages == 0) return;
    const ps: u64 = @intCast(paging.page_size);
    const end_excl = virt_base + @as(u64, num_pages) * ps;
    _ = space.vad.insert(virt_base, end_excl, .committed, nt_protect, false);
}

/// 与 `MEMORY_BASIC_INFORMATION` x64 布局对齐（Learn / WDK 公开结构；尾填充至 48 字节）。
pub const MemoryBasicInformation = extern struct {
    BaseAddress: u64 = 0,
    AllocationBase: u64 = 0,
    AllocationProtect: u32 = 0,
    _pad_align: u32 = 0,
    RegionSize: u64 = 0,
    State: u32 = 0,
    Protect: u32 = 0,
    Type: u32 = 0,
    _reserved_tail: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(MemoryBasicInformation) == 48);
}

/// `MemoryBasicInformation`（class 0）子集；无 VAD 时按单页推断。
pub fn fillMemoryBasicInformation(space: *AddressSpace, query_va: u64, out: *MemoryBasicInformation) void {
    const ps: u64 = @intCast(paging.page_size);
    const page = query_va & ~(ps - 1);
    out.* = .{};

    var svi: u8 = 0;
    while (svi < space.section_view_count) : (svi += 1) {
        const vb = space.section_view_base[svi];
        const np = space.section_view_pages[svi];
        if (np == 0) continue;
        if (@as(u64, np) > std.math.maxInt(u64) / ps) continue;
        const span = @as(u64, np) * ps;
        if (query_va < vb or query_va >= vb + span) continue;
        const prot = space.section_view_protect[svi];
        out.BaseAddress = vb;
        out.AllocationBase = vb;
        out.AllocationProtect = prot;
        out.RegionSize = span;
        out.Type = if (space.section_view_is_image[svi]) MEM_IMAGE else MEM_MAPPED;
        const qpg = query_va & ~(ps - 1);
        if (space.getPhysical(qpg)) |_| {
            out.State = vad_mod.MEM_COMMIT;
            out.Protect = prot;
        } else {
            out.State = vad_mod.MEM_RESERVE;
            out.Protect = PAGE_NOACCESS;
        }
        return;
    }

    if (space.vad.findContaining(query_va)) |e| {
        out.BaseAddress = e.start;
        out.AllocationBase = e.start;
        out.AllocationProtect = e.protect;
        out.RegionSize = e.end_exclusive - e.start;
        out.Type = MEM_PRIVATE;
        switch (e.state) {
            .reserved => {
                out.State = vad_mod.MEM_RESERVE;
                out.Protect = PAGE_NOACCESS;
            },
            .committed => {
                out.State = vad_mod.MEM_COMMIT;
                out.Protect = e.protect;
            },
            // `.partially_committed` 不会出现——`upgradeReservedContaining` 拆分后仅产生 reserved/committed 子 VAD。
            // 保留此分支以防未来扩展中出现该状态。
            .partially_committed => {
                out.State = vad_mod.MEM_COMMIT;
                out.Protect = e.protect;
            },
        }
        return;
    }

    if (space.getPhysical(page)) |_| {
        const vd = vmaFind(space, query_va);
        const prot: u32 = if (vd) |d|
            (if (d.writable) PAGE_READWRITE else PAGE_READONLY)
        else
            PAGE_READWRITE;
        out.BaseAddress = page;
        out.AllocationBase = page;
        out.AllocationProtect = prot;
        out.RegionSize = ps;
        out.State = vad_mod.MEM_COMMIT;
        out.Protect = prot;
        out.Type = MEM_PRIVATE;
        return;
    }

    out.BaseAddress = page;
    out.AllocationBase = page;
    out.RegionSize = ps;
    out.State = vad_mod.MEM_FREE;
}

const mdl_mod = @import("mdl.zig");

/// MDL：自页表解析 PFN（K1.7）；`mdl.zig` 保持仅依赖 `std` 以便主机单测。
pub fn mdlPopulateFromAddressSpace(mdl: *mdl_mod.Mdl, space: *AddressSpace) bool {
    mdl.pfn_count = 0;
    mdl.flags.pages_populated = false;
    if (mdl.byte_count == 0) return true;
    const ps: u64 = @intCast(paging.page_size);
    const pages_needed: u32 = (mdl.byte_count + @as(u32, @truncate(ps)) - 1) / @as(u32, @truncate(ps));
    if (pages_needed > mdl_mod.max_mdl_pfns) return false;
    var i: u32 = 0;
    while (i < pages_needed) : (i += 1) {
        const va = mdl.start_va + @as(u64, i) * ps;
        const pa = space.getPhysical(va) orelse return false;
        mdl.pfns[mdl.pfn_count] = pa >> 12;
        mdl.pfn_count += 1;
    }
    mdl.flags.pages_populated = true;
    return true;
}

pub fn mdlLockPagesInFrameAllocator(mdl: *mdl_mod.Mdl, fa: *FrameAllocator) void {
    if (!mdl.flags.pages_populated or mdl.flags.pages_locked) return;
    var i: u8 = 0;
    while (i < mdl.pfn_count) : (i += 1) {
        fa.lockPfnPhys(mdl.pfns[i] << 12);
    }
    mdl.flags.pages_locked = true;
}

pub fn mdlUnlockPagesInFrameAllocator(mdl: *mdl_mod.Mdl, fa: *FrameAllocator) void {
    if (!mdl.flags.pages_locked) return;
    var i: u8 = 0;
    while (i < mdl.pfn_count) : (i += 1) {
        // 与 `frame.free` 配对：全部 unlock 后 PFN 才可经 VM unmap 归还分配器。
        fa.unlockPfnPhys(mdl.pfns[i] << 12);
    }
    mdl.flags.pages_locked = false;
}

/// WDK `IoAllocateMdl` / `IoFreeMdl` 语义子集：变长 PFN 表在 **内核堆** 上；与 `frame.lockPfnPhys` 联动。
pub const IoMdlBuffer = struct {
    start_va: u64,
    byte_count: u32,
    pfn_slice: []u64,
    pages_locked: bool,

    pub fn release(self: *IoMdlBuffer, fa: *FrameAllocator) void {
        if (self.pages_locked) {
            for (self.pfn_slice) |pfn| fa.unlockPfnPhys(pfn << 12);
            self.pages_locked = false;
        }
        if (self.pfn_slice.len > 0) {
            heap.free(@ptrCast(self.pfn_slice.ptr), @sizeOf(u64) * self.pfn_slice.len, @alignOf(u64));
            self.pfn_slice = &[_]u64{};
        }
    }
};

/// 自 `AddressSpace` 解析 PFN；任一页未映射则失败并释放已分配堆块。
pub fn ioAllocateMdl(space: *AddressSpace, start_va: u64, byte_count: u32, lock_pages: bool, fa: *FrameAllocator) ?IoMdlBuffer {
    const ps_u64: u64 = @intCast(paging.page_size);
    const ps_u32: u32 = @truncate(ps_u64);
    if (byte_count == 0) {
        return IoMdlBuffer{
            .start_va = start_va,
            .byte_count = 0,
            .pfn_slice = &[_]u64{},
            .pages_locked = false,
        };
    }
    const npages: u32 = (byte_count + ps_u32 - 1) / ps_u32;
    const pfn_slice = heap.allocSlice(u64, npages) orelse return null;
    var i: u32 = 0;
    while (i < npages) : (i += 1) {
        const va = start_va + @as(u64, i) * ps_u64;
        const pa = space.getPhysical(va) orelse {
            heap.free(@ptrCast(pfn_slice.ptr), @sizeOf(u64) * npages, @alignOf(u64));
            return null;
        };
        pfn_slice[i] = pa >> 12;
    }
    if (lock_pages) {
        for (pfn_slice) |pfn| fa.lockPfnPhys(pfn << 12);
    }
    return IoMdlBuffer{
        .start_va = start_va,
        .byte_count = byte_count,
        .pfn_slice = pfn_slice,
        .pages_locked = lock_pages,
    };
}

/// 显式初始化各字段并分配 PML4；**避免**对整块 `AddressSpace` `@memset`（含巨型 `VadTable.nodes`，启动期可阻塞串口观感「卡住」）。
pub fn initAddressSpaceInPlace(space: *AddressSpace, allocator: *FrameAllocator) bool {
    // 与 `main.zig` identity 下限对齐：在自有页表启用前，`memsetPhysicalPage` 依赖固件恒等映射，优先取低 GPA。
    const pml4_boot_ceiling: u64 = 512 * 1024 * 1024;
    klog.info("VM: allocating PML4 frame (low 512MiB + fallback)...", .{});
    if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
        klog.debug("VM: PML4 allocZeroed enter", .{});
        arch.flushDebugSerialOutput();
    }
    const pml4_phys = allocator.allocZeroedBelowMaxPhys(pml4_boot_ceiling) orelse allocator.allocZeroed() orelse {
        klog.err("VM: PML4 alloc failed (allocZeroedBelowMaxPhys + allocZeroed; out of frames or implausible GPA)", .{});
        return false;
    };
    klog.info("VM: PML4 phys=0x%x (post-alloc, pre-wire)", .{pml4_phys});
    if (builtin.os.tag == .freestanding) arch.flushDebugSerialOutput();
    if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) klog.debug("VM: PML4 allocZeroed ok, wiring AddressSpace", .{});
    klog.info("VM: PML4 frame GPA 0x%x", .{pml4_phys});
    space.* = .{
        .pml4_phys = pml4_phys,
        .allocator = allocator,
        .vad = .{},
        .reserved_count = 0,
        .reserved_base = @splat(0),
        .reserved_pages = @splat(0),
        .section_view_count = 0,
        .section_view_base = @splat(0),
        .section_view_pages = @splat(0),
        .section_view_obj = @splat(0),
        .section_view_token = @splat(0),
        .section_view_file_off = @splat(0),
        .section_view_is_image = @splat(false),
        .section_view_protect = @splat(0),
        .vma_len = 0,
        .vma_base = @splat(0),
        .vma_pages = @splat(0),
        .vma_user = @splat(false),
        .vma_writable = @splat(false),
    };
    space.vad.initEmpty();
    return true;
}

pub fn createAddressSpace(allocator: *FrameAllocator) ?AddressSpace {
    var space: AddressSpace = undefined;
    if (!initAddressSpaceInPlace(&space, allocator)) return null;
    return space;
}

/// fork 路径 NTSTATUS 数值（与 Win32 一致；`vm` 不依赖 `io` 模块以免静态环）。
const fork_dup_status_success: i32 = 0;
const fork_dup_status_invalid_parameter: i32 = -1073741811;
const fork_dup_status_no_memory: i32 = -1073741801;
const fork_dup_status_not_supported: i32 = -1073741822;

fn forkDupChildPteFlags(pte_raw: u64) u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            const pe = @as(paging.PageTableEntry, @bitCast(pte_raw));
            var f: u64 = paging.Present | paging.Accessed;
            if (pe.user) f |= paging.User;
            if (pe.write_through) f |= paging.WriteThrough;
            if (pe.cache_disable) f |= paging.CacheDisable;
            if (pe.global) f |= paging.Global;
            if (pe.dirty) f |= paging.Dirty;
            if (pe.no_execute) f |= paging.NoExecute;
            break :blk f;
        },
        .loongarch64 => blk: {
            // LoongArch64: CoW 复制页标志
            // - 清除 D 位使页不可写，触发 CoW
            // - 保留 NX 位（代码页的可执行性）
            // - 保留 NR 位（可能的安全标志）
            // - 保留 PLV_USER 使用户态可访问
            var f: u64 = pte_raw;
            f &= ~@as(u64, paging.D); // 清除 D 位（不可写 → CoW）
            f &= ~@as(u64, paging.NR); // 清除 NR 位（如有设置）
            // 确保 Present 和 Accessed 标志存在
            f |= paging.Present;
            break :blk f;
        },
        .mips64el => pte_raw & ~@as(u64, paging.D_BIT),
        .aarch64 => blk: {
            // Preserve all flags except make read-only for CoW:
            // Clear AP[1] (bit 7) to remove EL0 write → AP=0b00 (EL1 RW only)
            // Keep Valid, AF, SH, AttrIdx, User, NoExecute etc.
            var f: u64 = pte_raw & ~@as(u64, paging.Write);
            // Ensure present and accessed
            f |= paging.Present | paging.Accessed;
            break :blk f;
        },
        else => pte_raw,
    };
}

const DupForkWalkCtx = struct {
    dst: *AddressSpace,
    status: i32 = fork_dup_status_success,
};

fn duplicateForkLeafWalkCb(ctx_raw: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool {
    const c = @as(*DupForkWalkCtx, @ptrCast(@alignCast(ctx_raw.?)));
    if (c.dst.getPhysical(virt)) |_| return true;
    c.dst.allocator.notePageShared(phys);
    const flags = forkDupChildPteFlags(pte_raw);
    if (!paging.mapPage(
        c.dst.pml4_phys,
        virt,
        phys,
        flags,
        allocFrameCb,
        @ptrCast(c.dst.allocator),
    )) {
        c.dst.allocator.releaseShareCount(phys);
        c.status = fork_dup_status_no_memory;
        return false;
    }
    return true;
}

/// fork 大页 walk 上下文：追加大页中每个小叶的处理。
const DupForkLargePageWalkCtx = struct {
    /// 指向外层 fork walk 的上下文（共享同一个 status）
    inner: *DupForkWalkCtx,
};

/// 遍历大页中每个小页（x86_64: 2MiB 中每 4KiB；LoongArch64: 32MiB 中每 16KiB）
fn duplicateForkLargePageSubCb(ctx_raw: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool {
    _ = pte_raw;
    const c = @as(*DupForkLargePageWalkCtx, @ptrCast(@alignCast(ctx_raw.?)));
    if (c.inner.dst.getPhysical(virt)) |_| return true;
    c.inner.dst.allocator.notePageShared(phys);
    // 大页中每个子叶使用只读（CoW）标志，子进程写时触发 CoW 复制
    if (!paging.mapPage(
        c.inner.dst.pml4_phys,
        virt,
        phys,
        paging.Present | paging.User | paging.Accessed,
        allocFrameCb,
        @ptrCast(c.inner.dst.allocator),
    )) {
        c.inner.dst.allocator.releaseShareCount(phys);
        c.inner.status = fork_dup_status_no_memory;
        return false;
    }
    return true;
}

/// fork 大页块回调：将大页拆分为小页逐个 fork。
fn duplicateForkLargePageWalkCb(ctx_raw: ?*anyopaque, virt: u64, phys: u64, block_size: u64) bool {
    const c = @as(*DupForkWalkCtx, @ptrCast(@alignCast(ctx_raw.?)));
    // 按架构小页粒度逐叶 fork
    const ps: u64 = @intCast(paging.page_size);
    var offset: u64 = 0;
    while (offset < block_size) : (offset += ps) {
        const sub_virt = virt + offset;
        if (c.dst.getPhysical(sub_virt)) |_| {
            offset += ps;
            continue;
        }
        const sub_phys = phys + offset;
        c.dst.allocator.notePageShared(sub_phys);
        if (!paging.mapPage(
            c.dst.pml4_phys,
            sub_virt,
            sub_phys,
            paging.Present | paging.User | paging.Accessed,
            allocFrameCb,
            @ptrCast(c.dst.allocator),
        )) {
            c.dst.allocator.releaseShareCount(sub_phys);
            c.status = fork_dup_status_no_memory;
            return false;
        }
    }
    return true;
}

fn copyUserSideMetadataForFork(dst: *AddressSpace, src: *const AddressSpace) bool {
    var entries: [vad_mod.max_vad]vad_mod.VadEntry = undefined;
    const n = src.vad.collectEntriesInorder(&entries);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = entries[i];
        if (!dst.vad.insert(e.start, e.end_exclusive, e.state, e.protect, e.is_guard)) return false;
    }
    dst.reserved_count = src.reserved_count;
    @memcpy(&dst.reserved_base, &src.reserved_base);
    @memcpy(&dst.reserved_pages, &src.reserved_pages);
    dst.section_view_count = src.section_view_count;
    @memcpy(&dst.section_view_base, &src.section_view_base);
    @memcpy(&dst.section_view_pages, &src.section_view_pages);
    @memcpy(&dst.section_view_obj, &src.section_view_obj);
    @memcpy(&dst.section_view_file_off, &src.section_view_file_off);
    @memcpy(&dst.section_view_is_image, &src.section_view_is_image);
    @memcpy(&dst.section_view_protect, &src.section_view_protect);
    @memcpy(&dst.section_view_token, &src.section_view_token);
    dst.vma_len = src.vma_len;
    @memcpy(&dst.vma_base, &src.vma_base);
    @memcpy(&dst.vma_pages, &src.vma_pages);
    @memcpy(&dst.vma_user, &src.vma_user);
    @memcpy(&dst.vma_writable, &src.vma_writable);
    return true;
}

/// fork 子集：将 `src` 用户半区 **用户叶**（x86 为 4KiB，LoongArch 为 16KiB；API 名 `forEachUser4KiPresentLeaf` 沿用）复制到 `dst`（`notePageShared`、子侧 PTE **不可写**），并复制 VAD / `reserved_*` / `section_view_*` / VMA。
/// - **大页**（x86 2MiB / LoongArch 32MiB）：先按小叶粒度逐页 fork（CoW），避免拆分大页表项。
/// - 若 `dst` 某 VA 已有映射（如 `kuser_shared`），跳过该 VA，保留子侧原页。
/// - 要求：`dst` 在复制前 **无** VAD / 保留区 / 段视图 / VMA 元数据（与 `createProcess` + `kuser` 后状态一致）。
pub fn duplicateUserMappingsForFork(dst: *AddressSpace, src: *const AddressSpace) i32 {
    if (!@hasDecl(paging, "forEachUser4KiPresentLeaf")) return fork_dup_status_not_supported;
    if (@intFromPtr(dst) == @intFromPtr(src)) return fork_dup_status_invalid_parameter;
    if (dst.vad.len() != 0 or dst.reserved_count != 0 or dst.section_view_count != 0 or dst.vma_len != 0)
        return fork_dup_status_invalid_parameter;
    if (!copyUserSideMetadataForFork(dst, src)) return fork_dup_status_no_memory;

    // 小叶 fork（4KiB / 16KiB 粒度）
    var walk: DupForkWalkCtx = .{ .dst = dst };
    if (!paging.forEachUser4KiPresentLeaf(src.pml4_phys, @ptrCast(&walk), duplicateForkLeafWalkCb)) {
        return walk.status;
    }

    // 大页 fork（x86 2MiB / LoongArch 32MiB）：拆分为小叶逐个 fork（CoW）
    if (@hasDecl(paging, "forEachUser2MiPresentLeaf")) {
        if (!paging.forEachUser2MiPresentLeaf(src.pml4_phys, @ptrCast(&walk), duplicateForkLargePageWalkCb)) {
            return walk.status;
        }
    } else if (@hasDecl(paging, "forEachUser32MiPresentLeaf")) {
        if (!paging.forEachUser32MiPresentLeaf(src.pml4_phys, @ptrCast(&walk), duplicateForkLargePageWalkCb)) {
            return walk.status;
        }
    }

    return fork_dup_status_success;
}

pub fn handleLazyCommitFault(space: *AddressSpace, fault_va: u64, is_write: bool) bool {
    return space.tryLazyCommitFault(fault_va, is_write);
}

/// 写故障 CoW：`pfn_share_count>0` 时复制到新帧并重映射可写叶项；**不**释放旧帧（其它别名或进程可能仍映射）。
/// 文件后备页：当 `shareCount==0` 时，从文件重新加载内容到新分配的私有帧。
pub fn tryCowWriteFault(space: *AddressSpace, fault_va: u64) bool {
    if (!@hasDecl(paging, "remapLeafPhysical")) return false;
    const frame_mod = @import("frame.zig");
    const ps: u64 = @intCast(paging.page_size);
    const page = fault_va & ~(ps - 1);
    const old_phys = space.getPhysical(page) orelse return false;
    const old_share_count = space.allocator.shareCount(old_phys);

    // 分配新帧
    const new_phys = space.allocator.alloc() orelse return false;
    defer if (old_share_count == 0) space.allocator.free(new_phys);

    if (old_share_count > 0) {
        // 标准 CoW：复制物理页内容
        frame_mod.memcpyPhysicalPage(new_phys, old_phys);
        // 注意：旧帧可能仍被其它进程映射，不释放旧帧
    } else {
        // 文件后备 CoW：旧帧是文件后备只读映射，从文件重新加载
        if (!cowReloadFromFileView(space, page, new_phys)) {
            return false;
        }
    }

    const ve = space.vad.findContaining(page) orelse return false;
    const pte_flags = ntProtectToPteFlags(ve.protect) orelse return false;
    if (!paging.remapLeafPhysical(
        space.pml4_phys,
        page,
        new_phys,
        pte_flags,
        allocFrameCb,
        @ptrCast(space.allocator),
    )) {
        return false;
    }
    if (old_share_count > 0) {
        space.allocator.releaseShareCount(old_phys);
    }
    return true;
}

/// 文件后备 CoW：从文件视图重新读取当前页内容到新分配的帧。
/// 使用延迟导入避免 vm.zig ↔ section.zig 循环依赖。
fn cowReloadFromFileView(space: *AddressSpace, page: u64, new_phys: u64) bool {
    // 延迟导入 section.zig 以避免循环依赖
    const section = @import("section.zig");
    return section.reloadPageFromFileBacking(space, page, new_phys);
}

/// #PF 用户态：`tryLazyCommitFault` → `tryCowWriteFault`。
pub fn handleUserDemandOrCowFault(space: *AddressSpace, fault_va: u64, is_write: bool) bool {
    if (space.tryLazyCommitFault(fault_va, is_write)) return true;
    if (is_write and tryCowWriteFault(space, fault_va)) return true;
    return false;
}

/// 是否与任一 `MEM_RESERVE` 记录区间重叠（用于选 `base==0` 时的空洞搜索）。
pub fn isVirtInReservedRange(space: *const AddressSpace, virt_base: u64, num_pages: usize) bool {
    const ps: u64 = @intCast(paging.page_size);
    const np = @as(u64, @intCast(num_pages));
    if (ps != 0 and np > std.math.maxInt(u64) / ps) return true;
    const span = np * ps;
    if (virt_base > std.math.maxInt(u64) - span) return true;
    const end = virt_base + span;
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const rp = @as(u64, space.reserved_pages[ri]);
        if (ps != 0 and rp > std.math.maxInt(u64) / ps) continue;
        const rspan = rp * ps;
        if (b > std.math.maxInt(u64) - rspan) continue;
        const e = b + rspan;
        if (!(end <= b or virt_base >= e)) return true;
    }
    return false;
}

pub fn mapRange(space: *AddressSpace, virt_base: u64, num_pages: usize, flags: MapFlags) bool {
    const ps: u64 = @intCast(paging.page_size);
    if (flags.user) {
        if (num_pages == 0) return false;
        if (ps != 0 and num_pages > std.math.maxInt(u64) / ps) return false;
        const span = @as(u64, @intCast(num_pages)) * ps;
        if (!userVaRangeAllowedNt61(virt_base, span)) return false;
    }
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        if (ps != 0 and i > std.math.maxInt(u64) / ps) return false;
        const off = @as(u64, i) * ps;
        if (virt_base > std.math.maxInt(u64) - off) return false;
        const virt = virt_base + off;
        if (space.mapPageAlloc(virt, flags) == null) {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (ps != 0 and j > std.math.maxInt(u64) / ps) break;
                const joff = @as(u64, j) * ps;
                if (virt_base <= std.math.maxInt(u64) - joff) {
                    _ = space.unmapAndFree(virt_base + joff);
                }
            }
            return false;
        }
    }
    return true;
}

pub fn unmapRange(space: *AddressSpace, virt_base: u64, num_pages: usize) void {
    const ps: u64 = @intCast(paging.page_size);
    const np = @as(u64, @intCast(num_pages));
    if (ps == 0 or np > std.math.maxInt(u64) / ps) return;
    const span = np * ps;
    if (virt_base > std.math.maxInt(u64) - span) return;
    const end_excl = virt_base + span;
    space.removeReservedCovering(virt_base, @intCast(num_pages));
    if (!space.vad.removeExact(virt_base, @intCast(num_pages))) {
        _ = space.vad.removePrefixRange(virt_base, end_excl);
    }
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        if (ps != 0 and i > std.math.maxInt(u64) / ps) break;
        const off = @as(u64, i) * ps;
        if (virt_base <= std.math.maxInt(u64) - off) {
            _ = space.unmapAndFree(virt_base + off);
        }
    }
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb = @import("../hal/x86_64/tlb_broadcast.zig");
        tlb.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
        tlb_la.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .mips64el and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb_mips = @import("../hal/mips64el/tlb_flush.zig");
        tlb_mips.noteUserMappingInvalidatedSmp(0);
    }
}

/// `MEM_DECOMMIT`：解除 PTE 并将对应 VAD 标回 reserved（子集；须整段落在已提交 VAD 内）。
pub fn decommitVirtualRange(space: *AddressSpace, virt_base: u64, num_pages: usize) bool {
    if (num_pages == 0) return false;
    const ps: u64 = @intCast(paging.page_size);
    const np = @as(u64, @intCast(num_pages));
    if (ps == 0 or np > std.math.maxInt(u64) / ps) return false;
    const span = np * ps;
    if (virt_base > std.math.maxInt(u64) - span) return false;
    const end_excl = virt_base + span;
    if (!space.vad.decommitSubrange(virt_base, end_excl, PAGE_NOACCESS)) return false;
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        if (ps != 0 and i > std.math.maxInt(u64) / ps) return false;
        const off = @as(u64, i) * ps;
        if (virt_base > std.math.maxInt(u64) - off) return false;
        _ = space.unmapAndFree(virt_base + off);
    }
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb = @import("../hal/x86_64/tlb_broadcast.zig");
        tlb.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb_la = @import("../hal/loongarch64/tlb_flush.zig");
        tlb_la.noteUserMappingInvalidatedSmp();
    }
    if (builtin.cpu.arch == .mips64el and builtin.os.tag == .freestanding and num_pages > 0) {
        const tlb_mips = @import("../hal/mips64el/tlb_flush.zig");
        tlb_mips.noteUserMappingInvalidatedSmp(0);
    }
    return true;
}

/// `MmFreeVirtualMemory` 语义子集：解除映射并尝试自 `vma` 表移除精确匹配项。
pub fn mmFreeVirtualRange(space: *AddressSpace, virt_base: u64, num_pages: u32) void {
    unmapRange(space, virt_base, num_pages);
    _ = vmaRemove(space, virt_base, num_pages);
}
