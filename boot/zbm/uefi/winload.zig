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

const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const unicode = std.unicode;

const menu = @import("menu_common.zig");
const gop_pitch_fixup = @import("gop_pitch_fixup.zig");

const arch_name = switch (builtin.target.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .riscv64 => "riscv64",
    .loongarch64 => "loongarch64",
    else => "unknown",
};

const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const preferred_fb_width = @import("build_options").zbm_preferred_fb_width;
const preferred_fb_height = @import("build_options").zbm_preferred_fb_height;

const KERNEL_PATH = "\\Windows\\System32\\ntoskrnl.exe";
const HAL_PATH = "\\Windows\\System32\\hal.dll";
const BOOT_DRIVER_PATHS = [_][]const u8{
    "\\Windows\\System32\\drivers\\acpi.sys",
    "\\Windows\\System32\\drivers\\bootvid.sys",
    "\\Windows\\System32\\drivers\\disk.sys",
    "\\Windows\\System32\\drivers\\partmgr.sys",
    "\\Windows\\System32\\drivers\\classpnp.sys",
};

const BOOT_IMAGE_KIND_KERNEL: u32 = 0;
const BOOT_IMAGE_KIND_HAL: u32 = 1;
const BOOT_IMAGE_KIND_DRIVER: u32 = 2;
const BOOT_IMAGE_KIND_SMSS: u32 = 3;
const BOOT_IMAGE_KIND_WININIT: u32 = 4;
const BOOT_IMAGE_KIND_SERVICES: u32 = 5;
const BOOT_IMAGE_KIND_LSASS: u32 = 6;
const BOOT_IMAGE_KIND_WINLOGON: u32 = 7;
const BOOT_IMAGE_KIND_USERINIT: u32 = 8;
const BOOT_IMAGE_KIND_CMD: u32 = 9;
const Attr = menu.Attr;

// ── UEFI Boot Manager Entry Point ──

pub fn main() noreturn {
    const st = uefi.system_table;
    const out = st.con_out orelse halt();
    const bs = st.boot_services orelse halt();

    out.reset(false) catch {};
    _ = out.setMode(0) catch {};

    menu.initBootEntries(desktop_theme_name, KERNEL_PATH);

    out.reset(false) catch {};
    displayBootProgress(out);
    loadAndBootKernel(out, bs);

    puts(out, "\r\n");
    puts(out, "  [!!] Failed to load kernel image.\r\n");
    puts(out, "  [!!] Verify ESP:\\Windows\\System32\\ntoskrnl.exe on the FAT volume.\r\n");
    puts(out, "  [!!] System halted.\r\n");
    halt();
}

// (Menu display moved to menu_common.zig)

// ── Boot Progress Display ──

fn displayBootProgress(out: anytype) void {
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "                 ZirconOSAero Boot Manager (NT 6.1)                            \r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Booting: ");
    putsRuntime(out, menu.entries[menu.selected].description);
    puts(out, "\r\n\r\n");
    puts(out, "    Command line: ");
    putsRuntime(out, menu.entries[menu.selected].cmdline);
    puts(out, "\r\n\r\n");

    puts(out, "    [*] UEFI Console initialized\r\n");

    displayMemoryMap(out, uefi.system_table.boot_services orelse return);

    puts(out, "    [*] Loading kernel image...\r\n");
    puts(out, "    [*] Path: " ++ KERNEL_PATH ++ "\r\n");
    puts(out, "\r\n");
}

fn loadAndBootKernel(out: anytype, bs: *uefi.tables.BootServices) void {
    puts(out, "    [*] Loading NT images from ESP...\r\n");

    const loaded_image = bs.openProtocol(
        uefi.protocol.LoadedImage,
        uefi.handle,
        .{ .by_handle_protocol = .{} },
    ) catch {
        puts(out, "    [!!] Failed to get LoadedImage protocol\r\n");
        return;
    } orelse {
        puts(out, "    [!!] LoadedImage protocol is null\r\n");
        return;
    };

    const device_handle: uefi.Handle = if (loaded_image.device_handle) |handle| handle else blk: {
        var handles: [16]uefi.Handle = undefined;
        const located = bs.locateHandle(
            .{ .by_protocol = &uefi.protocol.SimpleFileSystem.guid },
            &handles,
        ) catch {
            puts(out, "    [!!] Failed to locate ESP SimpleFileSystem handles\r\n");
            return;
        };
        if (located.len == 0) {
            puts(out, "    [!!] No ESP SimpleFileSystem handles found\r\n");
            return;
        }
        break :blk located[0];
    };

    const sfs = bs.openProtocol(
        uefi.protocol.SimpleFileSystem,
        device_handle,
        .{ .by_handle_protocol = .{} },
    ) catch {
        puts(out, "    [!!] Failed to get SimpleFileSystem\r\n");
        return;
    } orelse {
        puts(out, "    [!!] SimpleFileSystem is null\r\n");
        return;
    };

    const root = sfs.openVolume() catch {
        puts(out, "    [!!] Failed to open ESP volume\r\n");
        return;
    };

    if (loadAllBootImages(out, bs, root)) |images| {
        bootFromLoadedImages(out, bs, images);
        return;
    }

    puts(out, "    [!!] One or more required NT boot images failed to load\r\n");
}

// ── ELF64 Structures ──

const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const PT_LOAD: u32 = 1;
const PF_X: u32 = 1;
const PF_W: u32 = 2;

/// PT_LOAD 在内存中占用的物理页上界（独占），用于与下一页对齐的区间 `[p_lo, end)`。
fn ptLoadPageRangeEndExclusive(p_paddr: u64, memsz: u64) u64 {
    if (memsz == 0) return p_paddr & ~@as(u64, 0xFFF);
    const last_byte = p_paddr +% (memsz -% 1);
    return (last_byte & ~@as(u64, 0xFFF)) + 4096;
}

fn physPageWantsLoaderData(
    file_data: []const u8,
    file_size: usize,
    ehdr: *const Elf64_Ehdr,
    page_addr: u64,
) bool {
    const page_end = page_addr + 4096;
    var i: u16 = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const ph_off: usize = @intCast(ehdr.e_phoff + @as(usize, i) * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;
        const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;
        const seg_lo = phdr.p_paddr;
        const seg_hi = phdr.p_paddr +% phdr.p_memsz;
        if (seg_lo < page_end and seg_hi > page_addr) {
            if ((phdr.p_flags & PF_W) != 0) return true;
        }
    }
    return false;
}

fn gopPixelFormatIsLinear(f: uefi.protocol.GraphicsOutput.PixelFormat) bool {
    return f == .red_green_blue_reserved_8_bit_per_color or
        f == .blue_green_red_reserved_8_bit_per_color or
        f == .bit_mask;
}

/// virtio-gpu 等可能以 PixelBltOnly 启动，无线性帧缓冲；尝试 SetMode 到带 RGB/BGR/bit_mask 的模式。
fn trySetLinearGopMode(out: anytype, gop: *uefi.protocol.GraphicsOutput) void {
    const cur = gop.mode.info.pixel_format;
    if (gopPixelFormatIsLinear(cur)) return;

    var mid: u32 = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (gopPixelFormatIsLinear(mi.pixel_format)) {
            gop.setMode(mid) catch continue;
            puts(out, "    [*] GOP: selected linear framebuffer mode\r\n");
            return;
        }
    }
}

/// 优先 `preferred_fb_width`×`preferred_fb_height`（build / Makefile RESOLUTION），其次不小于该分辨率的最小模式，再选最大线性模式。
fn trySetPreferredGopMode(out: anytype, gop: *uefi.protocol.GraphicsOutput, want_w: u32, want_h: u32) void {
    trySetLinearGopMode(out, gop);

    var mid: u32 = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopPixelFormatIsLinear(mi.pixel_format)) continue;
        if (mi.horizontal_resolution == want_w and mi.vertical_resolution == want_h) {
            gop.setMode(mid) catch continue;
            puts(out, "    [*] GOP: set preferred mode ");
            printDecimal(out, want_w);
            puts(out, "x");
            printDecimal(out, want_h);
            puts(out, "\r\n");
            return;
        }
    }

    var best_cover: ?u32 = null;
    var best_cover_px: u64 = std.math.maxInt(u64);
    mid = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopPixelFormatIsLinear(mi.pixel_format)) continue;
        const w = mi.horizontal_resolution;
        const h = mi.vertical_resolution;
        if (w < want_w or h < want_h) continue;
        const px = @as(u64, w) * @as(u64, h);
        if (best_cover == null or px < best_cover_px) {
            best_cover = mid;
            best_cover_px = px;
        }
    }
    if (best_cover) |m| {
        gop.setMode(m) catch return;
        puts(out, "    [*] GOP: set mode >= preferred ");
        printDecimal(out, want_w);
        puts(out, "x");
        printDecimal(out, want_h);
        puts(out, "\r\n");
        return;
    }

    var best_any: ?u32 = null;
    var max_px: u64 = 0;
    mid = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopPixelFormatIsLinear(mi.pixel_format)) continue;
        const px = @as(u64, mi.horizontal_resolution) * @as(u64, mi.vertical_resolution);
        if (px > max_px) {
            best_any = mid;
            max_px = px;
        }
    }
    if (best_any) |m| {
        gop.setMode(m) catch return;
        puts(out, "    [*] GOP: set largest linear mode\r\n");
    }
}

// GOP framebuffer info passed from UEFI to kernel via multiboot2 tag
const GopFbInfo = struct {
    addr: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    /// 1 = UEFI BGR 顺序（首字节蓝，与 QEMU GOP 常见）；0 = RGB 顺序
    pixel_bgr: u8,
};

const DosHeader = extern struct {
    signature: u16,
    _reserved: [58]u8,
    pe_offset: u32,
};

const CoffHeader = extern struct {
    machine: u16,
    number_of_sections: u16,
    time_date_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbol_table_entries: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

const OptionalHeaderPe32Plus = extern struct {
    magic: u16,
    major_linker_version: u8,
    minor_linker_version: u8,
    size_of_code: u32,
    size_of_initialized_data: u32,
    size_of_uninitialized_data: u32,
    address_of_entry_point: u32,
    base_of_code: u32,
    image_base: u64,
    section_alignment: u32,
    file_alignment: u32,
    major_operating_system_version: u16,
    minor_operating_system_version: u16,
    major_image_version: u16,
    minor_image_version: u16,
    major_subsystem_version: u16,
    minor_subsystem_version: u16,
    win32_version_value: u32,
    size_of_image: u32,
    size_of_headers: u32,
    checksum: u32,
    subsystem: u16,
    dll_characteristics: u16,
    size_of_stack_reserve: u64,
    size_of_stack_commit: u64,
    size_of_heap_reserve: u64,
    size_of_heap_commit: u64,
    loader_flags: u32,
    number_of_rva_and_sizes: u32,
};

const SectionHeader = extern struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_line_numbers: u32,
    number_of_relocations: u16,
    number_of_line_numbers: u16,
    characteristics: u32,
};

const UEFI_VECTOR_MAGIC: u32 = 0x55454649;
const MULTIBOOT2_MAGIC: u32 = 0x36d76289;
const BOOT_IMAGE_TAG_TYPE: u32 = 0x5A494E31;
const MAX_BOOT_IMAGES: usize = 2 + BOOT_DRIVER_PATHS.len + 7;

/// 与 `src/arch/aarch64|riscv64/start.S` 对齐：v0 长 24 字节；v1 多 8 字节 `mb2_phys`（ZBM 写入后内核从向量表读，避免 x1/VA 与物理不一致）。
const uefi_vec_off_magic: usize = 0;
const uefi_vec_off_version: usize = 4;
const uefi_vec_off_kernel_entry: usize = 8;
const uefi_vec_off_stack: usize = 16;
const uefi_vec_off_mb2_phys: usize = 24;

const mmap_scratch_nbytes: usize = 32768;
const boot_info_page_size: usize = 4096;

/// Copies a fixed-size little-endian structure from a potentially unaligned byte buffer.
fn readStructAt(comptime T: type, data: []const u8, offset: usize) T {
    const byte_count = @sizeOf(T);
    const bytes = @as(*const [byte_count]u8, @ptrCast(data.ptr + offset));
    return std.mem.bytesToValue(T, bytes);
}

/// 按「mmap 缓冲能容纳的最多 UEFI 描述符」估算 Multiboot2 块上限，避免固件项多或 ExitBootServices 后重取图时越界。
fn multiboot2BootInfoMaxBytes(max_mmap_entries: usize, cmdline_len: usize, has_fb: bool) usize {
    var need: usize = 8;
    const str_sz = cmdline_len + 1;
    need +|= (8 + str_sz + 7) & ~@as(usize, 7);
    need +|= 16;
    const mmap_body = 16 + max_mmap_entries * 24;
    need +|= (mmap_body + 7) & ~@as(usize, 7);
    if (has_fb) need +|= (32 + 7) & ~@as(usize, 7);
    need +|= (8 + MAX_BOOT_IMAGES * 24 + 7) & ~@as(usize, 7);
    need +|= 8;
    return need;
}

const LoadedPeImage = struct {
    base: u64,
    size: u64,
    entry: u64,
    kind: u32,
};

const LoadPeResult = union(enum) {
    image: LoadedPeImage,
    missing,
    invalid,
    allocation_failed,
    too_large,
};

fn bootInfoPagesForScratchBuffer(scratch_len: usize, cmdline_len: usize, has_fb: bool) usize {
    const desc_sz = @sizeOf(uefi.tables.MemoryDescriptor);
    const max_entries = scratch_len / desc_sz;
    const bytes = multiboot2BootInfoMaxBytes(max_entries, cmdline_len, has_fb);
    return @max((bytes + boot_info_page_size - 1) / boot_info_page_size, 1);
}

// ── Kernel Loading (UEFI) ──

fn displayNameForPath(path: []const u8) []const u8 {
    var last: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '\\') last = index + 1;
    }
    return path[last..];
}

const BootImageSet = struct {
    images: [MAX_BOOT_IMAGES]LoadedPeImage,
    count: usize,
};

fn loadAllBootImages(out: anytype, bs: *uefi.tables.BootServices, root: *uefi.protocol.File) ?BootImageSet {
    var set = BootImageSet{ .images = @splat(.{ .base = 0, .size = 0, .entry = 0, .kind = 0 }), .count = 0 };

    const required_images = [_]struct { path: []const u8, kind: u32 }{
        .{ .path = KERNEL_PATH, .kind = BOOT_IMAGE_KIND_KERNEL },
        .{ .path = HAL_PATH, .kind = BOOT_IMAGE_KIND_HAL },
    };
    inline for (required_images) |image| {
        const result = loadPeImageFromEsp(out, bs, root, image.path, displayNameForPath(image.path), false, image.kind);
        switch (result) {
            .image => |loaded| {
                set.images[set.count] = loaded;
                set.count += 1;
            },
            else => return null,
        }
    }

    inline for (BOOT_DRIVER_PATHS) |driver_path| {
        const result = loadPeImageFromEsp(out, bs, root, driver_path, displayNameForPath(driver_path), false, BOOT_IMAGE_KIND_DRIVER);
        switch (result) {
            .image => |loaded| {
                set.images[set.count] = loaded;
                set.count += 1;
            },
            else => return null,
        }
    }

    const user_images = [_]struct { path: []const u8, kind: u32 }{
        .{ .path = "\\Windows\\System32\\smss.exe", .kind = BOOT_IMAGE_KIND_SMSS },
        .{ .path = "\\Windows\\System32\\wininit.exe", .kind = BOOT_IMAGE_KIND_WININIT },
        .{ .path = "\\Windows\\System32\\services.exe", .kind = BOOT_IMAGE_KIND_SERVICES },
        .{ .path = "\\Windows\\System32\\lsass.exe", .kind = BOOT_IMAGE_KIND_LSASS },
        .{ .path = "\\Windows\\System32\\winlogon.exe", .kind = BOOT_IMAGE_KIND_WINLOGON },
        .{ .path = "\\Windows\\System32\\userinit.exe", .kind = BOOT_IMAGE_KIND_USERINIT },
        .{ .path = "\\Windows\\System32\\cmd.exe", .kind = BOOT_IMAGE_KIND_CMD },
    };
    inline for (user_images) |image| {
        const result = loadPeImageFromEsp(out, bs, root, image.path, displayNameForPath(image.path), true, image.kind);
        switch (result) {
            .image => |loaded| {
                set.images[set.count] = loaded;
                set.count += 1;
            },
            else => return null,
        }
    }

    return set;
}

fn bootFromLoadedImages(out: anytype, bs: *uefi.tables.BootServices, set: BootImageSet) void {
    const kernel_base: usize = @intCast(set.images[0].base);
    const kernel_end: u64 = set.images[0].base + set.images[0].size;

    var vec_base: ?usize = null;
    if (kernel_base != 0) {
        const scan_end = kernel_base + 0x10000;
        var addr = kernel_base;
        while (addr + 24 <= scan_end) : (addr += 8) {
            const magic = @as(*const u32, @ptrFromInt(addr + uefi_vec_off_magic)).*;
            if (magic != UEFI_VECTOR_MAGIC) continue;
            const ver = @as(*const u32, @ptrFromInt(addr + uefi_vec_off_version)).*;
            if (ver > 1) continue;
            const ke = @as(*const u64, @ptrFromInt(addr + uefi_vec_off_kernel_entry)).*;
            const stk = @as(*const u64, @ptrFromInt(addr + uefi_vec_off_stack)).*;
            if (ke <= kernel_base or stk <= kernel_base) continue;
            if (ver == 1 and addr + 32 > scan_end) continue;
            vec_base = addr;
            break;
        }
    }

    if (vec_base == null) {
        puts(out, "    [!!] UEFI vector table not found in kernel\r\n");
        return;
    }

    const vb = vec_base.?;
    const kernel_entry = @as(*const u64, @ptrFromInt(vb + uefi_vec_off_kernel_entry)).*;
    puts(out, "    [*] kernel_main at 0x");
    printHex64(out, kernel_entry);
    puts(out, "\r\n");

    const gop_fb = queryGopFramebuffer(out, bs);
    var mmap_buf: [mmap_scratch_nbytes]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    const cmdline = menu.entries[menu.selected].cmdline;
    const bi_num_pages = bootInfoPagesForScratchBuffer(mmap_buf.len, cmdline.len, gop_fb != null);
    const bi_phys_aligned: usize = std.mem.alignForward(usize, @as(usize, @intCast(kernel_end)), boot_info_page_size);
    var mb_handoff_is_fixed_pa: bool = true;
    const boot_info_pages = bs.allocatePages(
        .{ .address = @ptrFromInt(bi_phys_aligned) },
        .loader_data,
        bi_num_pages,
    ) catch blk: {
        mb_handoff_is_fixed_pa = false;
        break :blk bs.allocatePages(.any, .loader_data, bi_num_pages) catch {
            puts(out, "    [!!] Failed to allocate boot info memory\r\n");
            return;
        };
    };
    const bi_cap = bi_num_pages * boot_info_page_size;
    const bi_base: [*]u8 = @ptrCast(boot_info_pages.ptr);
    @memset(bi_base[0..bi_cap], 0);

    buildBootInfo(bi_base, bi_cap, mmap, cmdline, gop_fb, set.images[0..set.count]) catch {
        puts(out, "    [!!] Multiboot2 boot info larger than buffer (internal error)\r\n");
        return;
    };
    const boot_info_addr: usize = if (mb_handoff_is_fixed_pa) bi_phys_aligned else @intFromPtr(bi_base);
    const ver = @as(*const u32, @ptrFromInt(vb + uefi_vec_off_version)).*;
    if (ver >= 1) {
        @as(*volatile u64, @ptrFromInt(vb + uefi_vec_off_mb2_phys)).* = boot_info_addr;
    }

    puts(out, "    [*] Multiboot2 boot info ready (");
    printDecimal(out, @intCast(bi_num_pages));
    puts(out, " pages)\r\n");
    puts(out, "    [*] Exiting boot services...\r\n");
    bs.exitBootServices(uefi.handle, mmap.info.key) catch {
        const mmap2 = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch return;
        buildBootInfo(bi_base, bi_cap, mmap2, cmdline, gop_fb, set.images[0..set.count]) catch return;
        bs.exitBootServices(uefi.handle, mmap2.info.key) catch return;
    };

    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ic iallu
            \\dsb sy
            \\isb
            ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence.i" ::: .{ .memory = true }),
        else => {},
    }

    const kernel_stack: u64 = @as(*const u64, @ptrFromInt(vb + uefi_vec_off_stack)).*;
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile (
            \\mov %[stack], %%rsp
            \\sub $8, %%rsp
            \\xor %%rbp, %%rbp
            \\mov %[magic], %%rdi
            \\mov %[info], %%rsi
            \\jmp *%[entry]
            :
            : [stack] "r" (kernel_stack),
              [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
              [info] "r" (@as(u64, boot_info_addr)),
              [entry] "r" (kernel_entry),
            : .{ .rdi = true, .rsi = true, .rsp = true, .rbp = true }),
        .aarch64 => asm volatile (
            \\mov sp, %[stack]
            \\mov x0, %[magic]
            \\mov x1, %[info]
            \\br %[entry]
            :
            : [stack] "r" (kernel_stack),
              [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
              [info] "r" (@as(u64, boot_info_addr)),
              [entry] "r" (kernel_entry),
            ),
        .riscv64 => asm volatile (
            \\mv sp, %[stack]
            \\mv a0, %[magic]
            \\mv a1, %[info]
            \\jr %[entry]
            :
            : [stack] "r" (kernel_stack),
              [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
              [info] "r" (@as(u64, boot_info_addr)),
              [entry] "r" (kernel_entry),
            ),
        else => unreachable,
    }
    unreachable;
}

fn queryGopFramebuffer(out: anytype, bs: *uefi.tables.BootServices) ?GopFbInfo {
    const gop_opt = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return null;
    const gop = gop_opt orelse return null;

    trySetPreferredGopMode(out, gop, preferred_fb_width, preferred_fb_height);

    const mode = gop.mode;
    const info = mode.info;

    const bpp: u8 = switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color,
        .blue_green_red_reserved_8_bit_per_color,
        => 32,
        .bit_mask => 32,
        else => 0,
    };

    if (bpp == 0) {
        puts(out, "    [!] GOP pixel format unsupported for framebuffer\r\n");
        return null;
    }

    const pixel_bgr: u8 = switch (info.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => 1,
        .red_green_blue_reserved_8_bit_per_color => 0,
        .bit_mask => 1,
        else => 1,
    };

    const fb_info = GopFbInfo{
        .addr = @intCast(mode.frame_buffer_base),
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = gop_pitch_fixup.effectivePitchBytes(info.horizontal_resolution, info.pixels_per_scan_line, bpp),
        .bpp = bpp,
        .pixel_bgr = pixel_bgr,
    };

    puts(out, "    [*] GOP Framebuffer: ");
    printDecimal(out, fb_info.width);
    puts(out, "x");
    printDecimal(out, fb_info.height);
    puts(out, "x");
    printDecimal(out, @as(u32, bpp));
    puts(out, " pitch_B=");
    printDecimal(out, fb_info.pitch);
    puts(out, "\r\n");

    return fb_info;
}

fn loadPeImageFromEsp(
    out: anytype,
    bs: *uefi.tables.BootServices,
    root: *uefi.protocol.File,
    comptime path: []const u8,
    display_name: []const u8,
    comptime raw_only: bool,
    kind: u32,
) LoadPeResult {
    const file = root.open(
        unicode.utf8ToUtf16LeStringLiteral(path),
        .read,
        .{},
    ) catch return .missing;

    var info_buf: [256]u8 align(8) = undefined;
    const file_info = file.getInfo(.file, @as([]align(8) u8, &info_buf)) catch return .invalid;
    const file_size: usize = @intCast(file_info.file_size);
    if (file_size < @sizeOf(DosHeader) + @sizeOf(CoffHeader) + @sizeOf(OptionalHeaderPe32Plus)) {
        _ = file.close() catch {};
        return .invalid;
    }

    const file_data = bs.allocatePool(.loader_data, file_size) catch return .allocation_failed;
    var total_read: usize = 0;
    while (total_read < file_size) {
        const n = file.read(file_data[total_read..]) catch {
            _ = file.close() catch {};
            return .invalid;
        };
        if (n == 0) break;
        total_read += n;
    }
    _ = file.close() catch {};
    if (total_read != file_size) return .invalid;

    if (raw_only) {
        return .{ .image = .{
            .base = @intFromPtr(file_data.ptr),
            .size = file_size,
            .entry = 0,
            .kind = kind,
        } };
    }

    const dos_header: DosHeader = readStructAt(DosHeader, file_data, 0);
    if (dos_header.signature != 0x5A4D) return .invalid;
    const pe_offset: usize = @intCast(dos_header.pe_offset);
    if (pe_offset + @sizeOf(u32) + @sizeOf(CoffHeader) > file_size) return .invalid;
    if (std.mem.readInt(u32, file_data[pe_offset..][0..4], .little) != 0x00004550) return .invalid;

    const coff_offset = pe_offset + @sizeOf(u32);
    const coff_header: CoffHeader = readStructAt(CoffHeader, file_data, coff_offset);
    if (coff_header.machine != 0x8664) return .invalid;
    if (coff_header.size_of_optional_header < @sizeOf(OptionalHeaderPe32Plus)) return .invalid;

    const optional_offset = coff_offset + @sizeOf(CoffHeader);
    const optional_header: OptionalHeaderPe32Plus = readStructAt(OptionalHeaderPe32Plus, file_data, optional_offset);
    if (optional_header.magic != 0x020B) return .invalid;

    const section_offset = optional_offset + coff_header.size_of_optional_header;
    const section_table_size = @as(usize, coff_header.number_of_sections) * @sizeOf(SectionHeader);
    if (section_offset + section_table_size > file_size) return .invalid;

    const image_base: u64 = optional_header.image_base;
    const uses_absolute_vas = image_base == 0;
    var mapped_base: u64 = if (uses_absolute_vas) std.math.maxInt(u64) else image_base;
    var mapped_end: u64 = 0;
    for (0..coff_header.number_of_sections) |index| {
        const section = readStructAt(SectionHeader, file_data, section_offset + index * @sizeOf(SectionHeader));
        const virtual_size: u64 = @max(section.virtual_size, section.size_of_raw_data);
        if (uses_absolute_vas) {
            mapped_base = @min(mapped_base, section.virtual_address);
            mapped_end = @max(mapped_end, section.virtual_address +| virtual_size);
        } else {
            mapped_base = @min(mapped_base, image_base +| section.virtual_address);
            mapped_end = @max(mapped_end, image_base +| section.virtual_address +| virtual_size);
        }
    }
    if (mapped_base == 0 or mapped_base > mapped_end) return .invalid;

    const declared_span: u64 = optional_header.size_of_image;
    const image_span: u64 = mapped_end - mapped_base;
    const actual_span: u64 = if (uses_absolute_vas) image_span else @max(image_span, declared_span);
    const image_span_pages = (actual_span + 0xFFF) / 0x1000;
    if (image_span_pages > 262144) return .too_large;

    const image_pages = bs.allocatePages(
        .{ .address = @ptrFromInt(@as(usize, @intCast(mapped_base))) },
        .loader_data,
        @intCast(image_span_pages),
    ) catch return .allocation_failed;
    if (@intFromPtr(image_pages.ptr) != mapped_base or image_pages.len != @as(usize, @intCast(image_span_pages))) {
        return .allocation_failed;
    }

    const image_memory: [*]u8 = @ptrCast(image_pages.ptr);
    @memset(image_memory[0..actual_span], 0);

    const headers_size: u64 = optional_header.size_of_headers;
    if (headers_size == 0 or headers_size > actual_span) return .invalid;
    if (headers_size > file_size) return .invalid;
    @memcpy(image_memory[0..@intCast(headers_size)], file_data[0..@intCast(headers_size)]);

    var sections_loaded: u32 = 0;
    for (0..coff_header.number_of_sections) |index| {
        const section = readStructAt(SectionHeader, file_data, section_offset + index * @sizeOf(SectionHeader));
        const raw_size = @min(section.size_of_raw_data, actual_span - section.virtual_address);
        if (raw_size == 0) continue;
        const raw_offset: usize = @intCast(section.pointer_to_raw_data);
        if (raw_offset + raw_size > file_size) return .invalid;
        const absolute_va = if (uses_absolute_vas) section.virtual_address else mapped_base +| section.virtual_address;
        const destination = image_memory + @as(usize, @intCast(absolute_va - mapped_base));
        @memcpy(destination[0..raw_size], file_data[raw_offset..][0..raw_size]);
        sections_loaded += 1;
    }

    puts(out, "    [*] Loaded ");
    putsRuntime(out, display_name);
    puts(out, " at 0x");
    printHex64(out, mapped_base);
    puts(out, " size 0x");
    printHex64(out, actual_span);
    puts(out, " sections ");
    printDecimal(out, sections_loaded);
    puts(out, "\r\n");
    return .{ .image = .{
        .base = mapped_base,
        .size = actual_span,
        .entry = mapped_base + optional_header.address_of_entry_point,
        .kind = kind,
    } };
}

fn buildBootInfo(
    bi_base: [*]u8,
    cap: usize,
    mmap: uefi.tables.MemoryMapSlice,
    cmdline: []const u8,
    gop_fb: ?GopFbInfo,
    boot_images: []const LoadedPeImage,
) error{BootInfoTooLarge}!void {
    var off: usize = 8; // skip BootInfoHeader (filled at end)

    // Tag: command line (type=1)
    {
        const str_sz: u32 = @intCast(cmdline.len + 1);
        const tag_len = (8 + str_sz + 7) & ~@as(usize, 7);
        if (off + tag_len > cap) return error.BootInfoTooLarge;
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 1;
        // Multiboot2：size 为含 padding 的整段标签长度（须与 tag_len 一致）
        p[1] = @intCast(tag_len);
        @memcpy((bi_base + off + 8)[0..cmdline.len], cmdline);
        (bi_base + off + 8)[cmdline.len] = 0;
        off += tag_len;
    }

    // Vendor tag: ZBM-loaded NT 6.1 images (kernel, HAL, BOOT_START drivers).
    {
        const body_len = boot_images.len * 24;
        const tag_len = (8 + body_len + 7) & ~@as(usize, 7);
        if (off + tag_len > cap) return error.BootInfoTooLarge;
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = BOOT_IMAGE_TAG_TYPE;
        p[1] = @intCast(tag_len);
        for (boot_images, 0..) |image, index| {
            const entry: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(@alignCast(p))) + 8 + index * 24));
            entry[0] = image.base;
            entry[1] = image.size;
            const flags: u32 = image.kind;
            @as(*u32, @ptrFromInt(@intFromPtr(entry + 2))).* = flags;
            @as(*u32, @ptrFromInt(@intFromPtr(entry + 3))).* = 0;
        }
        off += tag_len;
    }

    // Tag: basic memory info (type=4)
    const meminfo_off = off;
    {
        if (off + 16 > cap) return error.BootInfoTooLarge;
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 4;
        p[1] = 16;
        p[2] = 640; // mem_lower KB (conventional below 1MB)
        p[3] = 0; // mem_upper KB (filled after mmap scan)
        off += 16;
    }

    // Tag: memory map (type=6)
    {
        const tag_start = off;
        if (off + 16 > cap) return error.BootInfoTooLarge;
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 6;
        p[2] = 24; // entry_size
        p[3] = 0; // entry_version
        var eoff: usize = 16;
        var mem_upper_kb: u32 = 0;

        var it = mmap.iterator();
        while (it.next()) |desc| {
            if (tag_start + eoff + 24 > cap) return error.BootInfoTooLarge;
            const mb_type: u32 = uefiToMb2MemType(desc.type);
            const base = desc.physical_start;
            const length = desc.number_of_pages * 4096;

            const ep: [*]u8 = bi_base + tag_start + eoff;
            @as(*u64, @ptrCast(@alignCast(ep))).* = base;
            @as(*u64, @ptrCast(@alignCast(ep + 8))).* = length;
            @as(*u32, @ptrCast(@alignCast(ep + 16))).* = mb_type;
            @as(*u32, @ptrCast(@alignCast(ep + 20))).* = 0;

            if (mb_type == 1 and base >= 0x100000) {
                mem_upper_kb +|= @intCast(length / 1024);
            }
            eoff += 24;
        }

        p[1] = @intCast(eoff); // tag size

        // Write mem_upper back to basic meminfo tag
        const mi: [*]u32 = @ptrCast(@alignCast(bi_base + meminfo_off));
        mi[3] = mem_upper_kb;

        const mmap_tag_total = (eoff + 7) & ~@as(usize, 7);
        if (tag_start + mmap_tag_total > cap) return error.BootInfoTooLarge;
        off += mmap_tag_total;
    }

    // Tag: framebuffer (type=8) — GOP framebuffer info for graphical desktop
    if (gop_fb) |fb| {
        const tag_len = (32 + 7) & ~@as(usize, 7);
        if (off + tag_len > cap) return error.BootInfoTooLarge;
        const base = bi_base + off;
        @as(*u32, @ptrCast(@alignCast(base))).* = 8; // type
        @as(*u32, @ptrCast(@alignCast(base + 4))).* = 32; // size (8+8+4+4+4+1+1+2=32)
        @as(*u64, @ptrCast(@alignCast(base + 8))).* = fb.addr; // framebuffer_addr
        @as(*u32, @ptrCast(@alignCast(base + 16))).* = fb.pitch; // pitch
        @as(*u32, @ptrCast(@alignCast(base + 20))).* = fb.width; // width
        @as(*u32, @ptrCast(@alignCast(base + 24))).* = fb.height; // height
        base[28] = fb.bpp; // bpp
        base[29] = 1; // fb_type = 1 (direct color)
        base[30] = fb.pixel_bgr; // 1=BGR 首字节蓝, 0=RGB 首字节红
        base[31] = 0x5A; // 扩展有效标记（旧引导未填时内核默认 BGR）
        off += tag_len;
    }

    // Tag: end (type=0)
    {
        if (off + 8 > cap) return error.BootInfoTooLarge;
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 0;
        p[1] = 8;
        off += 8;
    }

    // Fill boot info header
    const hdr: [*]u32 = @ptrCast(@alignCast(bi_base));
    hdr[0] = @intCast(off); // total_size
    hdr[1] = 0; // reserved
}

fn uefiToMb2MemType(t: uefi.tables.MemoryType) u32 {
    return switch (t) {
        .conventional_memory,
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        => 1, // available
        .acpi_reclaim_memory => 3,
        .acpi_memory_nvs => 4,
        .unusable_memory => 5,
        else => 2, // reserved
    };
}

fn printHex64(out: anytype, value: u64) void {
    const hex = "0123456789abcdef";
    var v = value;
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xF))];
        v >>= 4;
    }
    for (buf) |c| {
        var u16buf: [1:0]u16 = .{@as(u16, c)};
        _ = out.outputString(&u16buf) catch false;
    }
}

// ── UEFI Helper Functions ──

fn displayMemoryMap(out: anytype, bs: *uefi.tables.BootServices) void {
    const info = bs.getMemoryMapInfo() catch {
        puts(out, "    [!] Memory map unavailable\r\n");
        return;
    };

    puts(out, "    [*] Memory map: ");
    printDecimal(out, @intCast(info.len));
    puts(out, " entries\r\n");
}

fn printUefiVersion(out: anytype, revision: u32) void {
    const major = revision >> 16;
    const minor = revision & 0xFFFF;

    puts(out, "      UEFI Rev     : ");
    printDecimal(out, major);
    puts(out, ".");
    printDecimal(out, minor);
    puts(out, "\r\n");
}

fn printDecimal(out: anytype, value: u32) void {
    if (value >= 10) printDecimal(out, value / 10);
    var buf: [1:0]u16 = .{@as(u16, @intCast('0' + (value % 10)))};
    _ = out.outputString(&buf) catch false;
}

fn puts(out: anytype, comptime s: []const u8) void {
    _ = out.outputString(unicode.utf8ToUtf16LeStringLiteral(s)) catch false;
}

fn putsRuntime(out: anytype, s: []const u8) void {
    for (s) |c| {
        var buf: [1:0]u16 = .{@as(u16, c)};
        _ = out.outputString(&buf) catch false;
    }
}

fn halt() noreturn {
    while (true) {
        switch (builtin.target.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            else => {},
        }
    }
}
