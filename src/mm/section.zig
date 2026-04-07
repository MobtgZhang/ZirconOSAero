// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/section.zig
// Purpose: Section 对象与映射视图（匿名、文件后备 eager copy、SEC_IMAGE 标志）；视图 token 登记于 `vm.AddressSpace`。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-ntcreatesection
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K1.6

const std = @import("std");
const ob = @import("../ob/object.zig");
const process = @import("../ps/process.zig");
const vm = @import("vm.zig");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;
const vfs = @import("../fs/vfs.zig");
const cleanup_hooks = @import("../ob/cleanup_hooks.zig");

// 与 `ntdll` 中 NTSTATUS 数值一致，避免模块环依赖。
const STATUS_SUCCESS: i32 = 0;
const STATUS_INVALID_PARAMETER: i32 = -1073741811;
const STATUS_NO_MEMORY: i32 = -1073741801;
const STATUS_NOT_IMPLEMENTED: i32 = -1073741822;
const STATUS_INSUFFICIENT_RESOURCES: i32 = -1073741823;

pub const MAX_SECTIONS: usize = 256;

/// 注册 `NtClose` 最后一道引用释放时对静态节槽的回收（由 `main` 启动早期调用一次）。
pub fn registerSectionCleanupHook() void {
    cleanup_hooks.section_last_reference = releaseSectionObjectByPtr;
}

fn releaseSectionObjectByPtr(object_ptr: u64) void {
    releaseSectionObject(@as(*SectionObject, @ptrFromInt(object_ptr)));
}

/// **句柄与引用**：`NtCreateSection` 经 `allocHandle` 增加 `ref_count`；`NtClose` 至 `ref_count==0` 时
/// `object.cleanup_hooks` 调用 `releaseSectionObject` 回收 `g_sections` 槽位。
/// 若存在仍映射的视图（`active_view_count>0`），关闭节句柄在完整 NT 语义下应失败或延迟销毁；当前为路线图项。
///
/// 内核静态池中的节对象（匿名或文件后备只读映射）。
pub const SectionObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .section },
    maximum_size: u64 = 0,
    page_protection: u32 = 0,
    file_backed: bool = false,
    /// `vfs.FileObject` 内核指针；仅 `file_backed` 时有效。
    backing_file: ?*vfs.FileObject = null,
    /// 打开的映射视图数（最后一视图卸载后仍可保留节句柄；供将来共享/COW 回收）。
    active_view_count: u32 = 0,
    /// `SEC_IMAGE` 等：完整 PE 映射为路线图；仅作标志供加载器探测。
    is_image_section: bool = false,
    /// 写时拷贝：**文件后备**仍为路线图；**匿名**节上 `PAGE_WRITECOPY` 与私有 RW 等价（fork 时由 `duplicateUserMappingsForFork` 做 CoW）。
    cow_requested: bool = false,
    /// A2b：**多进程共享只读映像**（DLL `SEC_IMAGE`）须在独立 CR3 上映射同一 `SectionObject` 后备帧；当前为标志位 + 文档锚点，完整引用计数与视图令牌生命周期见 `MM_Section_Roadmap.md`。
    shared_image_candidate: bool = false,
};

var g_sections: [MAX_SECTIONS]SectionObject = undefined;
var g_section_used: [MAX_SECTIONS]bool = [_]bool{false} ** MAX_SECTIONS;

var section_va_salt: u32 = 0xA5A5_5A5A;

fn pageAlignUp(size: u64) u64 {
    const ps: u64 = @intCast(paging.page_size);
    return (size + ps - 1) & ~(ps - 1);
}

/// 分配匿名节；`max_size` 为 0 时按一页处理。
pub fn createAnonymousSection(max_size: u64, page_protection: u32) ?*SectionObject {
    var i: usize = 0;
    while (i < MAX_SECTIONS) : (i += 1) {
        if (!g_section_used[i]) {
            g_section_used[i] = true;
            const s = &g_sections[i];
            const aligned = if (max_size == 0) @as(u64, @intCast(paging.page_size)) else pageAlignUp(max_size);
            const cow = (page_protection & 0x88) != 0; // WRITECOPY / EXECUTE_WRITECOPY
            s.* = .{
                .header = .{ .obj_type = .section, .ref_count = 0, .handle_count = 0 },
                .maximum_size = aligned,
                .page_protection = page_protection,
                .file_backed = false,
                .cow_requested = cow,
            };
            return s;
        }
    }
    return null;
}

/// 文件后备节（`NtCreateSection` + 文件句柄）；`max_size` 0 表示取 `file.file_size`。
/// `is_image_section`：`SEC_IMAGE`（PE 映像节）；映射策略仍与只读/可写文件子集共用，完整 PE 加载器对齐见 `loader/pe.zig` 路线图。
pub fn createFileBackedSection(max_size: u64, page_protection: u32, file: *vfs.FileObject, is_image_section: bool) ?*SectionObject {
    var i: usize = 0;
    while (i < MAX_SECTIONS) : (i += 1) {
        if (!g_section_used[i]) {
            g_section_used[i] = true;
            const s = &g_sections[i];
            const from_file = if (max_size == 0) file.file_size else @min(max_size, file.file_size);
            const aligned = pageAlignUp(from_file);
            const cow = (page_protection & 0x88) != 0; // WRITECOPY / EXECUTE_WRITECOPY
            s.* = .{
                .header = .{ .obj_type = .section, .ref_count = 0, .handle_count = 0 },
                .maximum_size = aligned,
                .page_protection = page_protection,
                .file_backed = true,
                .backing_file = file,
                .active_view_count = 0,
                .is_image_section = is_image_section,
                .cow_requested = cow,
            };
            return s;
        }
    }
    return null;
}

pub fn releaseSectionObject(sec: *SectionObject) void {
    const base = @intFromPtr(sec);
    var idx: usize = 0;
    while (idx < MAX_SECTIONS) : (idx += 1) {
        if (g_section_used[idx] and @intFromPtr(&g_sections[idx]) == base) {
            g_section_used[idx] = false;
            sec.* = .{};
            return;
        }
    }
}

fn mapFlagsFromPageProtect(prot: u32) vm.MapFlags {
    const writable = (prot & 0xCC) != 0; // READWRITE / WRITECOPY / EXECUTE_READWRITE / EXECUTE_WRITECOPY
    const executable = ((prot & 0xF0) >= 0x10); // PAGE_EXECUTE (0x10) through PAGE_EXECUTE_WRITECOPY (0x80)
    return .{ .writable = writable, .user = true, .executable = executable };
}

fn pickUserBase(space: *vm.AddressSpace, num_pages: u32) ?u64 {
    const ps: u64 = @intCast(paging.page_size);
    if (ps != 0 and @as(u64, num_pages) > std.math.maxInt(u64) / ps) return null;
    const vs = @as(u64, num_pages) * ps;
    if (!vm.userVaRangeAllowedNt61(vm.USER_VA_MIN_X64_NT, vs)) return null;
    section_va_salt = section_va_salt *% 1664525 +% 1013904223;
    const slide: u64 = @as(u64, section_va_salt % 512);
    var base: u64 = std.mem.alignForward(u64, vm.USER_VA_MIN_X64_NT + slide * ps, ps);
    if (!vm.userVaRangeAllowedNt61(base, vs)) {
        base = std.mem.alignForward(u64, vm.USER_VA_MIN_X64_NT, ps);
        if (!vm.userVaRangeAllowedNt61(base, vs)) return null;
    }
    while (vm.userVaRangeAllowedNt61(base, vs)) : (base += ps) {
        if (space.getPhysical(base) != null) continue;
        if (vm.isVirtInReservedRange(space, base, num_pages)) continue;
        var ok = true;
        var p: u32 = 0;
        while (p < num_pages) : (p += 1) {
            const va = base + @as(u64, p) * ps;
            if (space.getPhysical(va)) |_| {
                ok = false;
                break;
            }
        }
        if (ok) return base;
    }
    return null;
}

/// `NtMapViewOfSection`：匿名页 **或** 文件后备（映射时读入内容）。可写文件后备为 **整段 eager copy**（非真 COW）。
fn copyFileIntoMappedPages(
    space: *vm.AddressSpace,
    base: u64,
    num_pages: u32,
    file: *vfs.FileObject,
    start_file_off: u64,
) i32 {
    const ps: u64 = @intCast(paging.page_size);
    var buf: [4096]u8 = undefined;
    var file_pos = start_file_off;
    var p: u32 = 0;
    while (p < num_pages) : (p += 1) {
        const va = base + @as(u64, p) * ps;
        const phys = space.getPhysical(va) orelse return STATUS_NO_MEMORY;
        var written: u64 = 0;
        while (written < ps) {
            const to_read: usize = @intCast(@min(ps - written, @as(u64, buf.len)));
            file.position = file_pos;
            const rr = vfs.read(file, buf[0..to_read]);
            if (rr.status != .success) return STATUS_INVALID_PARAMETER;
            const got = rr.bytes_read;
            const dst_k: [*]u8 = @ptrFromInt(phys + written);
            if (got > 0) {
                @memcpy(dst_k[0..got], buf[0..got]);
                file_pos += got;
            }
            if (got < to_read) {
                @memset(dst_k[got..to_read], 0);
            }
            written += to_read;
        }
    }
    return STATUS_SUCCESS;
}

pub fn mapViewIntoProcess(
    proc: *process.Process,
    sec: *SectionObject,
    base_address: *u64,
    section_offset: u64,
    view_size: *u64,
) i32 {
    // 文件后备 + 请求真 COW：尚未实现（须 #PF 路径或只读映射 + 写时复制）。
    if (sec.file_backed and sec.cow_requested) return STATUS_NOT_IMPLEMENTED;
    if (section_offset >= sec.maximum_size) return STATUS_INVALID_PARAMETER;
    const ps: u64 = @intCast(paging.page_size);
    const vs: u64 = if (view_size.* == 0)
        sec.maximum_size - section_offset
    else
        pageAlignUp(view_size.*);
    if (section_offset + vs > sec.maximum_size) return STATUS_INVALID_PARAMETER;

    const space = proc.address_space orelse return STATUS_NO_MEMORY;
    const num_pages: u32 = @intCast(vs / ps);
    const flags = mapFlagsFromPageProtect(sec.page_protection);

    var base = base_address.*;
    if (base == 0) {
        base = pickUserBase(space, num_pages) orelse return STATUS_NO_MEMORY;
    } else {
        if (base & (ps - 1) != 0) return STATUS_INVALID_PARAMETER;
    }
    if (!vm.userVaRangeAllowedNt61(base, vs)) return STATUS_INVALID_PARAMETER;

    if (sec.file_backed) {
        const end_excl = base + vs;
        if (!space.vad.insert(base, end_excl, .reserved, sec.page_protection, false)) {
            return STATUS_NO_MEMORY;
        }
        if (!space.recordSectionView(base, num_pages, @intFromPtr(sec), section_offset, sec.is_image_section, sec.page_protection)) {
            _ = space.vad.removeExact(base, num_pages);
            return STATUS_INSUFFICIENT_RESOURCES;
        }
        sec.active_view_count +%= 1;
        base_address.* = base;
        view_size.* = vs;
        return STATUS_SUCCESS;
    }

    var p: u32 = 0;
    while (p < num_pages) : (p += 1) {
        const va = base + @as(u64, p) * ps;
        if (space.mapPageAlloc(va, flags) == null) {
            var j: u32 = 0;
            while (j < p) : (j += 1) {
                _ = space.unmapAndFree(base + @as(u64, j) * ps);
            }
            return STATUS_NO_MEMORY;
        }
    }

    if (!space.recordSectionView(base, num_pages, @intFromPtr(sec), 0, sec.is_image_section, sec.page_protection)) {
        var j: u32 = 0;
        while (j < num_pages) : (j += 1) {
            _ = space.unmapAndFree(base + @as(u64, j) * ps);
        }
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    sec.active_view_count +%= 1;
    vm.recordCommittedVadRange(space, base, num_pages, sec.page_protection);
    base_address.* = base;
    view_size.* = vs;
    return STATUS_SUCCESS;
}

/// 由 `vm.setSectionLazyCommitFillHook` 注册：惰性提交 PTE 已建立后，自文件视图读入该页。
pub fn onLazyCommitFillPage(space: *vm.AddressSpace, page_va: u64) bool {
    const ps: u64 = @intCast(paging.page_size);
    const page = page_va & ~(ps - 1);
    var vi: u8 = 0;
    while (vi < space.section_view_count) : (vi += 1) {
        const vb = space.section_view_base[vi];
        const np = space.section_view_pages[vi];
        if (ps == 0) return false;
        if (@as(u64, np) > std.math.maxInt(u64) / ps) continue;
        const span = @as(u64, np) * ps;
        if (page < vb or page >= vb + span) continue;
        const sec = @as(*SectionObject, @ptrFromInt(space.section_view_obj[vi]));
        if (!sec.file_backed) return false;
        const fo = sec.backing_file orelse return false;
        const page_idx = (page - vb) / ps;
        const file_off = space.section_view_file_off[vi] + page_idx * ps;
        const phys = space.getPhysical(page) orelse return false;
        var buf: [4096]u8 = undefined;
        var written: u64 = 0;
        while (written < ps) {
            fo.position = file_off + written;
            const to_read: usize = @intCast(@min(ps - written, @as(u64, buf.len)));
            const rr = vfs.read(fo, buf[0..to_read]);
            if (rr.status != .success) return false;
            const got = rr.bytes_read;
            const dst: [*]u8 = @ptrFromInt(phys + written);
            if (got > 0) @memcpy(dst[0..got], buf[0..got]);
            if (got < to_read) @memset(dst[got..to_read], 0);
            written += to_read;
        }
        return true;
    }
    return false;
}

pub fn unmapViewInProcess(proc: *process.Process, base: u64) i32 {
    const space = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    var sec_opt: ?*SectionObject = null;
    var vi: u8 = 0;
    while (vi < space.section_view_count) : (vi += 1) {
        if (space.section_view_base[vi] == base) {
            sec_opt = @ptrFromInt(space.section_view_obj[vi]);
            break;
        }
    }
    const pages = space.takeSectionView(base) orelse return STATUS_INVALID_PARAMETER;
    if (sec_opt) |sec| {
        if (sec.active_view_count > 0) sec.active_view_count -= 1;
    }
    vm.unmapRange(space, base, pages);
    return STATUS_SUCCESS;
}

test "SectionObject is backed by object header type section" {
    const s: SectionObject = .{};
    try std.testing.expect(s.header.obj_type == ob.ObjectType.section);
}

test "MAX_SECTIONS is bounded for static pool" {
    try std.testing.expect(MAX_SECTIONS > 0 and MAX_SECTIONS <= 256);
}
