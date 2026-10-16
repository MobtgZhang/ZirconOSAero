// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! Boot info parsing for x86_64: Multiboot2 (BIOS/ZBM) and UEFI handoff (BOOTX64.EFI)
//! Multiboot2 tag layout (public spec): https://www.gnu.org/software/grub/manual/multiboot2/multiboot2.html
//! UEFI handoff layout matches boot/stub/efi_stub.c EfiHandoff (C ABI, 8-byte aligned).

const std = @import("std");
const mb2 = @import("../../boot/multiboot2_parse.zig");

pub const MULTIBOOT2_BOOTLOADER_MAGIC = mb2.MULTIBOOT2_BOOTLOADER_MAGIC;
pub const BootInfoHeader = mb2.BootInfoHeader;
pub const TagHeader = mb2.TagHeader;
pub const TagType = mb2.TagType;
pub const BasicMemInfoTag = mb2.BasicMemInfoTag;
pub const MmapEntryType = mb2.MmapEntryType;
pub const MmapEntry = mb2.MmapEntry;
pub const MmapTag = mb2.MmapTag;
pub const FramebufferInfo = mb2.FramebufferInfo;
pub const DesktopTheme = mb2.DesktopTheme;
pub const BootMode = mb2.BootMode;
pub const BootInfo = mb2.BootInfo;

extern const multiboot2_header: [48]u8;

/// 与 boot/stub/efi_stub.c ZIRCON_MAGIC 一致（小端四字符 `zirc`）
pub const ZIRCON_X86_64_EFI_MAGIC: u32 = 0x6372697A;

/// EfiHandoff（boot/stub/efi_stub.c）C ABI 布局（8 字节对齐）：
///   u32 magic; u32 version; u32 boot_mode; u32 desktop;
///   u64 fb_addr; u32 fb_pitch; u32 fb_width; u32 fb_height;
///   u8 fb_bpp; u8 _pad[3];
///   u32 mmap_count; u32 mmap_entry_size; u32 mmap_off_from_handoff; u32 _mmap_pad;
const EfiHandoff = extern struct {
    magic: u32,
    version: u32,
    boot_mode: u32,
    desktop: u32,
    fb_addr: u64,
    fb_pitch: u32,
    fb_width: u32,
    fb_height: u32,
    fb_bpp: u8,
    _pad: [3]u8,
    mmap_count: u32,
    mmap_entry_size: u32,
    mmap_off_from_handoff: u32,
    _mmap_pad: u32,
};

comptime {
    std.debug.assert(@sizeOf(EfiHandoff) == 56);
    std.debug.assert(@offsetOf(EfiHandoff, "fb_addr") == 16);
}

fn bootModeFromU32(v: u32) BootMode {
    return switch (v) {
        0 => .normal,
        1 => .cmd,
        2 => .desktop,
        else => .normal,
    };
}

fn desktopFromU32(v: u32) DesktopTheme {
    return switch (v) {
        0 => .none,
        1 => .aero,
        else => .none,
    };
}

pub fn parse(magic: u32, phys_addr: usize) ?BootInfo {
    if (magic == ZIRCON_X86_64_EFI_MAGIC and phys_addr != 0) {
        return parseEfiHandoff(phys_addr);
    }
    return mb2.parseMultiboot2(phys_addr);
}

fn parseEfiHandoff(info_addr: usize) ?BootInfo {
    const h: *const EfiHandoff = @ptrFromInt(info_addr);
    if (h.magic != ZIRCON_X86_64_EFI_MAGIC) return null;
    var bi = BootInfo{
        .mem_lower_kb = 640,
        .mem_upper_kb = 262144,
        .mmap_ptr = @as([*]const u8, @ptrFromInt(0x1000)),
        .mmap_entry_count = 0,
        .mmap_entry_size = @sizeOf(MmapEntry),
    };
    bi.desktop_theme = desktopFromU32(h.desktop);
    bi.boot_mode = bootModeFromU32(h.boot_mode);
    if (h.fb_addr != 0 and h.fb_width > 0 and h.fb_height > 0 and h.fb_bpp > 0) {
        const bpp: u8 = @intCast(h.fb_bpp);
        const computed_pitch = h.fb_width * @as(u32, bpp) / 8;
        bi.fb_info = .{
            .addr = h.fb_addr,
            .pitch = if (h.fb_pitch > 0) h.fb_pitch else computed_pitch,
            .width = h.fb_width,
            .height = h.fb_height,
            .bpp = bpp,
            .fb_type = 2,
        };
    }
    return bi;
}
