// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: boot/zbm/uefi/main_riscv64.zig
// Purpose: RISC-V64 UEFI ZBM root — same Multiboot2 handoff as legacy main.zig but compiled
//          only for riscv64-freestanding so the object matches RISC-V GNU-EFI link (see build.zig).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://github.com/riscv-non-isa/riscv-elf-psabi-doc (calling convention); UEFI on RISC-V.
const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const unicode = std.unicode;

const menu = @import("menu_common.zig");
const gop_pitch_fixup = @import("gop_pitch_fixup.zig");

comptime {
    if (builtin.target.cpu.arch != .riscv64)
        @compileError("main_riscv64.zig must be built for riscv64 only");
}

const arch_name = "riscv64";

const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const preferred_fb_width = @import("build_options").zbm_preferred_fb_width;
const preferred_fb_height = @import("build_options").zbm_preferred_fb_height;

const KERNEL_PATH = menu.KERNEL_PATH;
const Attr = menu.Attr;

// ── UEFI Boot Manager Entry Point ──

pub fn main() noreturn {
    const st = uefi.system_table;
    const out = st.con_out orelse halt();
    const bs = st.boot_services orelse halt();

    out.reset(false) catch {};
    _ = out.setMode(0) catch {};

    menu.initBootEntries(desktop_theme_name, KERNEL_PATH);

    const cin = st.con_in orelse {
        displayBootProgress(out);
        loadAndBootKernel(out, bs);
        puts(out, "\r\n");
        puts(out, "  [!!] Failed to load kernel image (no console input path).\r\n");
        halt();
    };

    var result: menu.MenuResult = undefined;
    while (true) {
        result = menu.runMenuLoop(out, bs, cin, arch_name, debug_mode);
        switch (result) {
            .selected => break,
            .show_advanced => {
                menu.displayAdvancedOptions(
                    out,
                    bs,
                    cin,
                    arch_name,
                    KERNEL_PATH,
                    st.firmware_vendor,
                    st.hdr.revision,
                    debug_mode,
                );
                menu.displayBootManagerMenu(out, arch_name, debug_mode);
            },
            .cancel => {
                _ = bs.exit(uefi.handle, uefi.Status.aborted, null) catch {};
                halt();
            },
        }
    }

    out.reset(false) catch {};
    displayBootProgress(out);
    loadAndBootKernel(out, bs);

    puts(out, "\r\n");
    puts(out, "  [!!] Failed to load kernel image.\r\n");
    puts(out, "  [!!] Verify ESP:\\EFI\\BOOT\\BOOT*.EFI and \\boot\\kernel.elf on the FAT volume.\r\n");
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

const UEFI_VECTOR_MAGIC: u32 = 0x55454649;
const MULTIBOOT2_MAGIC: u32 = 0x36d76289;

/// 与 `src/arch/aarch64|riscv64/start.S` 对齐：v0 长 24 字节；v1 多 8 字节 `mb2_phys`（ZBM 写入后内核从向量表读，避免 x1/VA 与物理不一致）。
const uefi_vec_off_magic: usize = 0;
const uefi_vec_off_version: usize = 4;
const uefi_vec_off_kernel_entry: usize = 8;
const uefi_vec_off_stack: usize = 16;
const uefi_vec_off_mb2_phys: usize = 24;

const mmap_scratch_nbytes: usize = 32768;
const boot_info_page_size: usize = 4096;

/// 按「mmap 缓冲能容纳的最多 UEFI 描述符」估算 Multiboot2 块上限，避免固件项多或 ExitBootServices 后重取图时越界。
fn multiboot2BootInfoMaxBytes(max_mmap_entries: usize, cmdline_len: usize, has_fb: bool) usize {
    var need: usize = 8;
    const str_sz = cmdline_len + 1;
    need +|= (8 + str_sz + 7) & ~@as(usize, 7);
    need +|= 16;
    const mmap_body = 16 + max_mmap_entries * 24;
    need +|= (mmap_body + 7) & ~@as(usize, 7);
    if (has_fb) need +|= (32 + 7) & ~@as(usize, 7);
    need +|= 8;
    return need;
}

fn bootInfoPagesForScratchBuffer(scratch_len: usize, cmdline_len: usize, has_fb: bool) usize {
    const desc_sz = @sizeOf(uefi.tables.MemoryDescriptor);
    const max_entries = scratch_len / desc_sz;
    const bytes = multiboot2BootInfoMaxBytes(max_entries, cmdline_len, has_fb);
    return @max((bytes + boot_info_page_size - 1) / boot_info_page_size, 1);
}

// ── Kernel Loading (UEFI) ──

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

fn loadAndBootKernel(out: anytype, bs: *uefi.tables.BootServices) void {
    // ── Step 1: Open kernel.elf from ESP ──
    puts(out, "    [*] Opening kernel from ESP...\r\n");

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

    const device_handle = loaded_image.device_handle orelse {
        puts(out, "    [!!] No boot device handle\r\n");
        return;
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

    const kernel_file = root.open(
        unicode.utf8ToUtf16LeStringLiteral(KERNEL_PATH),
        .read,
        .{},
    ) catch {
        puts(out, "    [!!] kernel.elf not found on ESP\r\n");
        return;
    };

    puts(out, "    [*] kernel.elf opened\r\n");

    // ── Step 2: Read kernel file into memory ──
    var info_buf: [256]u8 align(8) = undefined;
    const file_info = kernel_file.getInfo(.file, @as([]align(8) u8, &info_buf)) catch {
        puts(out, "    [!!] Failed to get kernel file info\r\n");
        return;
    };
    const file_size: usize = @intCast(file_info.file_size);

    puts(out, "    [*] Kernel size: ");
    printDecimal(out, @intCast(file_size / 1024));
    puts(out, " KB\r\n");

    const file_data = bs.allocatePool(.loader_data, file_size) catch {
        puts(out, "    [!!] Failed to allocate memory for kernel\r\n");
        return;
    };

    var total_read: usize = 0;
    while (total_read < file_size) {
        const n = kernel_file.read(file_data[total_read..]) catch {
            puts(out, "    [!!] Failed to read kernel file\r\n");
            return;
        };
        if (n == 0) break;
        total_read += n;
    }
    _ = kernel_file.close() catch {};

    puts(out, "    [*] Kernel file read into buffer\r\n");

    // ── Step 3: Parse ELF64 header ──
    if (file_size < @sizeOf(Elf64_Ehdr)) {
        puts(out, "    [!!] File too small for ELF header\r\n");
        return;
    }

    const ehdr: *const Elf64_Ehdr = @ptrCast(@alignCast(file_data.ptr));

    if (ehdr.e_ident[0] != 0x7F or ehdr.e_ident[1] != 'E' or
        ehdr.e_ident[2] != 'L' or ehdr.e_ident[3] != 'F')
    {
        puts(out, "    [!!] Invalid ELF magic\r\n");
        return;
    }
    if (ehdr.e_ident[4] != 2) {
        puts(out, "    [!!] Not a 64-bit ELF\r\n");
        return;
    }

    puts(out, "    [*] ELF64 valid, ");
    printDecimal(out, ehdr.e_phnum);
    puts(out, " program headers\r\n");

    // ── Step 4: Load PT_LOAD — 先按物理页去重 allocatePages（多段常共享同一页），再逐段 memcpy
    const max_kernel_pages: u64 = 262144; // 1GiB / 4KiB，防止畸形 ELF
    var min_page: u64 = std.math.maxInt(u64);
    var max_page_excl: u64 = 0;
    var segments_loaded: u32 = 0;

    {
        var i: u16 = 0;
        while (i < ehdr.e_phnum) : (i += 1) {
            const ph_off: usize = @intCast(ehdr.e_phoff + @as(usize, i) * ehdr.e_phentsize);
            if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;
            const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
            if (phdr.p_type != PT_LOAD) continue;
            if (phdr.p_memsz == 0) continue;
            segments_loaded += 1;
            const p_lo = phdr.p_paddr & ~@as(u64, 0xFFF);
            const p_hi_excl = ptLoadPageRangeEndExclusive(phdr.p_paddr, phdr.p_memsz);
            min_page = @min(min_page, p_lo);
            max_page_excl = @max(max_page_excl, p_hi_excl);
        }
    }

    if (segments_loaded == 0) {
        puts(out, "    [!!] No PT_LOAD segments in kernel ELF\r\n");
        return;
    }

    const total_pages = (max_page_excl - min_page) / 4096;
    if (total_pages > max_kernel_pages) {
        puts(out, "    [!!] PT_LOAD span too large for UEFI loader\r\n");
        return;
    }

    var pa = min_page;
    while (pa < max_page_excl) : (pa += 4096) {
        const page_mem_type: uefi.tables.MemoryType =
            if (physPageWantsLoaderData(file_data, file_size, ehdr, pa))
                .loader_data
            else
                .loader_code;
        _ = bs.allocatePages(
            .{ .address = @ptrFromInt(pa) },
            page_mem_type,
            1,
        ) catch {
            puts(out, "    [!!] allocatePages failed for kernel phys page 0x");
            printHex64(out, pa);
            puts(out, "\r\n");
            return;
        };
    }

    segments_loaded = 0;
    for (0..ehdr.e_phnum) |i| {
        const ph_off: usize = @intCast(ehdr.e_phoff + i * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;

        const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(phdr.p_paddr)));
        const filesz: usize = @intCast(phdr.p_filesz);
        const memsz: usize = @intCast(phdr.p_memsz);
        const offset: usize = @intCast(phdr.p_offset);

        if (filesz > 0 and offset + filesz <= file_size) {
            const src = file_data.ptr + offset;
            @memcpy(dst[0..filesz], src[0..filesz]);
        }

        if (memsz > filesz) {
            @memset(dst[filesz..memsz], 0);
        }

        segments_loaded += 1;
    }

    puts(out, "    [*] Loaded ");
    printDecimal(out, segments_loaded);
    puts(out, " ELF segments\r\n");

    // ── Step 5: Find UEFI vector table in loaded kernel ──
    // Scan the first loaded segment for the magic pattern 0x55454649
    const kernel_base: usize = blk: {
        for (0..ehdr.e_phnum) |i| {
            const pho: usize = @intCast(ehdr.e_phoff + i * ehdr.e_phentsize);
            if (pho + @sizeOf(Elf64_Phdr) > file_size) continue;
            const ph: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + pho));
            if (ph.p_type == PT_LOAD) break :blk @as(usize, @intCast(ph.p_paddr));
        }
        break :blk 0;
    };

    var vec_base: ?usize = null;
    if (kernel_base != 0) {
        // Scan the first 64KB from kernel base for the magic pattern
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

    // ── Step 6: Query GOP framebuffer (must be done BEFORE ExitBootServices) ──
    const gop_fb = queryGopFramebuffer(out, bs);

    // ── Step 7: Memory map + sized Multiboot2 boot info ──
    var mmap_buf: [mmap_scratch_nbytes]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    const cmdline = menu.entries[menu.selected].cmdline;
    const bi_num_pages = bootInfoPagesForScratchBuffer(mmap_buf.len, cmdline.len, gop_fb != null);
    // Multiboot2 指针必须对内核可用：内核在 identity map 下按「物理地址」读 handoff。
    // `allocatePages(.any)` 在部分 AArch64 固件上返回的指针数值 ≠ 物理页基址，会导致解析读到全 0 并回退 qemuVirtDefault（无 GOP tag）。
    const bi_phys_aligned: usize = std.mem.alignForward(usize, @as(usize, @intCast(max_page_excl)), boot_info_page_size);
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

    buildBootInfo(bi_base, bi_cap, mmap, cmdline, gop_fb) catch {
        puts(out, "    [!!] Multiboot2 boot info larger than buffer (internal error)\r\n");
        return;
    };
    const boot_info_addr: usize = if (mb_handoff_is_fixed_pa) bi_phys_aligned else @intFromPtr(bi_base);
    // v1 向量表：把 Multiboot2 物理地址写回已加载映像（内核优先读此槽，不依赖 x1 数值）
    {
        const ver = @as(*const u32, @ptrFromInt(vb + uefi_vec_off_version)).*;
        if (ver >= 1) {
            @as(*volatile u64, @ptrFromInt(vb + uefi_vec_off_mb2_phys)).* = boot_info_addr;
        }
    }
    puts(out, "    [*] Multiboot2 boot info ready (");

    printDecimal(out, @intCast(bi_num_pages));
    puts(out, " pages)\r\n");

    // ── Step 8: Exit boot services ──
    puts(out, "    [*] Exiting boot services...\r\n");

    bs.exitBootServices(uefi.handle, mmap.info.key) catch {
        const mmap2 = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch return;
        buildBootInfo(bi_base, bi_cap, mmap2, cmdline, gop_fb) catch return;
        bs.exitBootServices(uefi.handle, mmap2.info.key) catch return;
    };

    // ═══ NO MORE UEFI CALLS PAST THIS POINT ═══

    // 将 ELF 段 memcpy 到 RAM 后须使指令对 CPU 可见（AArch64 I-cache；RISC-V fence.i）
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ic iallu
            \\dsb sy
            \\isb
            ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence.i" ::: .{ .memory = true }),
        else => {},
    }

    // ── Jump to kernel_main（架构相关调用约定）──
    // x86_64: RDI=magic, RSI=info, RSP=内核栈（勿用 UEFI 栈）
    // AArch64: x0=magic, x1=info, SP=内核栈
    // RISC-V: a0=magic, a1=info, sp=内核栈
    const kernel_stack = @as(*const u64, @ptrFromInt(vb + uefi_vec_off_stack)).*;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            asm volatile ("cli");
            asm volatile (
                \\mov %[stack], %%rsp
                \\xor %%rbp, %%rbp
                \\mov %[magic], %%rdi
                \\mov %[info], %%rsi
                \\jmp *%[entry]
                :
                : [entry] "r" (kernel_entry),
                  [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
                  [info] "r" (@as(u64, boot_info_addr)),
                  [stack] "r" (kernel_stack),
                : .{ .rdi = true, .rsi = true, .rsp = true, .rbp = true });
        },
        .aarch64 => {
            asm volatile (
                \\mov sp, %[stack]
                \\mov %[magic], x0
                \\mov %[info], x1
                \\br %[entry]
                :
                : [stack] "r" (kernel_stack),
                  [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
                  [info] "r" (@as(u64, boot_info_addr)),
                  [entry] "r" (kernel_entry),
            );
        },
        .riscv64 => {
            asm volatile (
                \\mv sp, %[stack]
                \\mv a0, %[magic]
                \\mv a1, %[info]
                \\jr %[entry]
                :
                : [stack] "r" (kernel_stack),
                  [magic] "r" (@as(u64, MULTIBOOT2_MAGIC)),
                  [info] "r" (@as(u64, boot_info_addr)),
                  [entry] "r" (kernel_entry),
            );
        },
        else => unreachable,
    }
    unreachable;
}

fn buildBootInfo(
    bi_base: [*]u8,
    cap: usize,
    mmap: uefi.tables.MemoryMapSlice,
    cmdline: []const u8,
    gop_fb: ?GopFbInfo,
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
