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

const ob = @import("../ob/object.zig");
const process = @import("../ps/process.zig");
const vm = @import("vm.zig");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;

// 与 `ntdll` 中 NTSTATUS 数值一致，避免模块环依赖。
const STATUS_SUCCESS: i32 = 0;
const STATUS_INVALID_PARAMETER: i32 = -1073741811;
const STATUS_NO_MEMORY: i32 = -1073741801;
const STATUS_NOT_IMPLEMENTED: i32 = -1073741822;
const STATUS_INSUFFICIENT_RESOURCES: i32 = -1073741823;

pub const MAX_SECTIONS: usize = 32;

/// 内核静态池中的节对象（匿名内存节）。
pub const SectionObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .section },
    maximum_size: u64 = 0,
    page_protection: u32 = 0,
    file_backed: bool = false,
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

/// `NtMapViewOfSection` 简化语义：在目标进程提交 `view_size` 字节（页对齐）的匿名页。
pub fn mapViewIntoProcess(
    proc: *process.Process,
    sec: *SectionObject,
    base_address: *u64,
    section_offset: u64,
    view_size: *u64,
) i32 {
    if (sec.file_backed) return STATUS_NOT_IMPLEMENTED;
    if (section_offset >= sec.maximum_size) return STATUS_INVALID_PARAMETER;
    const ps: u64 = @intCast(paging.page_size);
    const vs: u64 = if (view_size.* == 0)
        sec.maximum_size - section_offset
    else
        pageAlignUp(view_size.*);
    if (section_offset + vs > sec.maximum_size) return STATUS_INVALID_PARAMETER;

    var space = proc.address_space orelse return STATUS_NO_MEMORY;
    const num_pages: u32 = @intCast(vs / ps);
    const flags = mapFlagsFromPageProtect(sec.page_protection);

    var base = base_address.*;
    if (base == 0) {
        base = pickUserBase(&space, num_pages) orelse return STATUS_NO_MEMORY;
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
    proc.address_space = space;
    base_address.* = base;
    view_size.* = vs;
    return STATUS_SUCCESS;
}

pub fn unmapViewInProcess(proc: *process.Process, base: u64) i32 {
    var space = proc.address_space orelse return STATUS_INVALID_PARAMETER;
    const pages = space.takeSectionView(base) orelse return STATUS_INVALID_PARAMETER;
    const ps: u64 = @intCast(paging.page_size);
    var i: u32 = 0;
    while (i < pages) : (i += 1) {
        _ = space.unmapAndFree(base + @as(u64, i) * ps);
    }
    proc.address_space = space;
    return STATUS_SUCCESS;
}
