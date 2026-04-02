// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/section.zig
// Purpose: Section 对象与映射视图（匿名、页对齐）；文件后备为后续里程碑。
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

// 与 `ntdll` 中 NTSTATUS 数值一致，避免模块环依赖。
const STATUS_SUCCESS: i32 = 0;
const STATUS_INVALID_PARAMETER: i32 = -1073741811;
const STATUS_NO_MEMORY: i32 = -1073741801;
const STATUS_NOT_IMPLEMENTED: i32 = -1073741822;
const STATUS_INSUFFICIENT_RESOURCES: i32 = -1073741823;

pub const MAX_SECTIONS: usize = 32;

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
    /// 写时拷贝：尚未实现；为真时 `mapViewIntoProcess` 应拒绝或走 COW 路径。
    cow_requested: bool = false,
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
            s.* = .{
                .header = .{ .obj_type = .section, .ref_count = 1, .handle_count = 0 },
                .maximum_size = aligned,
                .page_protection = page_protection,
                .file_backed = false,
            };
            return s;
        }
    }
    return null;
}

/// 只读文件后备节（`NtCreateSection` + 文件句柄）；`max_size` 0 表示取 `file.file_size`。
pub fn createFileBackedSection(max_size: u64, page_protection: u32, file: *vfs.FileObject) ?*SectionObject {
    var i: usize = 0;
    while (i < MAX_SECTIONS) : (i += 1) {
        if (!g_section_used[i]) {
            g_section_used[i] = true;
            const s = &g_sections[i];
            const from_file = if (max_size == 0) file.file_size else @min(max_size, file.file_size);
            const aligned = pageAlignUp(from_file);
            const cow = (page_protection & 0x88) != 0; // WRITECOPY / EXECUTE_WRITECOPY
            s.* = .{
                .header = .{ .obj_type = .section, .ref_count = 1, .handle_count = 0 },
                .maximum_size = aligned,
                .page_protection = page_protection,
                .file_backed = true,
                .backing_file = file,
                .active_view_count = 0,
                .is_image_section = false,
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
    const executable = (prot & 0x70) != 0; // EXECUTE*
    return .{ .writable = writable, .user = true, .executable = executable };
}

fn pickUserBase(space: *vm.AddressSpace, num_pages: u32) ?u64 {
    const ps: u64 = @intCast(paging.page_size);
    section_va_salt = section_va_salt *% 1664525 +% 1013904223;
    const slide: u64 = @as(u64, section_va_salt % 512);
    var base: u64 = 0x0000_0000_4000_0000 + slide * ps;
    const vs = @as(u64, num_pages) * ps;
    while (base < vm.USER_VA_MAX_HINT_X86_64 -| vs) : (base += ps) {
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

/// `NtMapViewOfSection`：匿名页 **或** 只读文件后备（映射时读入内容）；COW/可写文件图为路线图。
fn copyFileIntoMappedPages(
    space: *vm.AddressSpace,
    base: u64,
    num_pages: u32,
    file: *vfs.FileObject,
    start_file_off: u64,
) i32 {
    const ps: u64 = @intCast(paging.page_size);
    var buf: [4096]u8 = undefined;
    if (ps > buf.len) return STATUS_INVALID_PARAMETER;
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
    if (sec.cow_requested) return STATUS_NOT_IMPLEMENTED;
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
    if (sec.file_backed and flags.writable) return STATUS_NOT_IMPLEMENTED;

    var base = base_address.*;
    if (base == 0) {
        base = pickUserBase(space, num_pages) orelse return STATUS_NO_MEMORY;
    } else {
        if (base & (ps - 1) != 0) return STATUS_INVALID_PARAMETER;
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
    if (!space.recordSectionView(base, num_pages, @intFromPtr(sec))) {
        var j: u32 = 0;
        while (j < num_pages) : (j += 1) {
            _ = space.unmapAndFree(base + @as(u64, j) * ps);
        }
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    if (sec.file_backed) {
        const fo = sec.backing_file orelse {
            var j: u32 = 0;
            while (j < num_pages) : (j += 1) {
                _ = space.unmapAndFree(base + @as(u64, j) * ps);
            }
            _ = space.takeSectionView(base);
            return STATUS_INVALID_PARAMETER;
        };
        const cp = copyFileIntoMappedPages(space, base, num_pages, fo, section_offset);
        if (cp != STATUS_SUCCESS) {
            var j: u32 = 0;
            while (j < num_pages) : (j += 1) {
                _ = space.unmapAndFree(base + @as(u64, j) * ps);
            }
            _ = space.takeSectionView(base);
            return cp;
        }
    }
    sec.active_view_count +%= 1;
    vm.recordCommittedVadRange(space, base, num_pages, sec.page_protection);
    base_address.* = base;
    view_size.* = vs;
    return STATUS_SUCCESS;
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
