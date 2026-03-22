//! ZirconOS Boot Manager — LoongArch64 UEFI（与 `boot/zbm/uefi/main.zig` 共用 menu_common）
//!
//! Zig build-obj + GNU-EFI/ld + objcopy 或 C stub 流程（linker_stub.lds）生成 BOOTLOONGARCH64.EFI。
const std = @import("std");
const uefi = std.os.uefi;
const unicode = std.unicode;
const elf = std.elf;

const menu = @import("menu_common.zig");

const arch_name = "loongarch64";
const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const KERNEL_PATH = menu.KERNEL_PATH;
const Attr = menu.Attr;

// ── LoongArch EFI handoff（与 src/arch/loongarch64/boot.zig 一致）──

const ZIRCON_LOONGARCH_EFI_MAGIC: u32 = 0x6372697A;
const HANDOFF_PHYS: usize = 0x100000;

const EfiHandoff = extern struct {
    magic: u32,
    version: u32,
    boot_mode: u32,
    desktop: u32,
};

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

fn comptimeDesktopId() u32 {
    const s = desktop_theme_name;
    if (comptime std.mem.eql(u8, s, "none")) return 0;
    return 1;
}

/// 将菜单项映射为 EFI handoff（与 x86 条目语义尽量对应）
fn handoffForSelectedEntry(idx: usize) EfiHandoff {
    const def_id = comptimeDesktopId();
    var boot_mode: u32 = 0;
    var desktop: u32 = def_id;
    switch (idx) {
        0 => {
            boot_mode = 0;
            desktop = def_id;
        },
        1 => {
            boot_mode = 0;
            desktop = def_id;
        },
        2, 3, 4 => {
            boot_mode = 0;
            desktop = 0;
        },
        5 => {
            boot_mode = 1;
            desktop = 0;
        },
        else => {
            boot_mode = 0;
            desktop = def_id;
        },
    }
    return .{
        .magic = ZIRCON_LOONGARCH_EFI_MAGIC,
        .version = 1,
        .boot_mode = boot_mode,
        .desktop = desktop,
    };
}

fn jumpToKernel(entry: u64, handoff_phys: usize) noreturn {
    const mag: u64 = @as(u64, ZIRCON_LOONGARCH_EFI_MAGIC);
    asm volatile (
        \\ move $a0, %[mag]
        \\ move $a1, %[hand]
        \\ jr %[entry]
        :
        : [mag] "r" (mag),
          [hand] "r" (handoff_phys),
          [entry] "r" (entry),
    );
    unreachable;
}

fn haltLa() noreturn {
    while (true) {
        asm volatile ("idle 0");
    }
}

// ── Boot flow（与 x86 `main` 等价，出口为 `efi_main`）──

fn runBootManager(st: *uefi.tables.SystemTable) uefi.Status {
    const out = st.con_out orelse return .unsupported;
    const bs = st.boot_services orelse return .unsupported;

    out.reset(false) catch {};
    _ = out.setMode(0) catch {};

    menu.initBootEntries(desktop_theme_name, KERNEL_PATH);

    const cin = st.con_in orelse {
        displayBootProgress(out);
        loadAndBootLoongArchKernel(out, bs);
        puts(out, "\r\n");
        puts(out, "  [!!] Failed to load kernel image (no console input path).\r\n");
        haltLa();
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
        }
    }

    out.reset(false) catch {};
    displayBootProgress(out);
    loadAndBootLoongArchKernel(out, bs);

    puts(out, "\r\n");
    puts(out, "  [!!] Failed to load kernel image.\r\n");
    puts(out, "  [!!] Verify ESP:\\EFI\\BOOT\\BOOTLOONGARCH64.EFI and \\boot\\kernel.elf.\r\n");
    puts(out, "  [!!] System halted.\r\n");
    haltLa();
}


fn displayBootProgress(out: anytype) void {
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "                    ZirconOS Boot Manager                                     \r\n");
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

const GopFbInfo = struct {
    addr: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    pixel_bgr: u8,
};

fn queryGopFramebuffer(out: anytype, bs: *uefi.tables.BootServices) ?GopFbInfo {
    const gop_opt = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return null;
    const gop = gop_opt orelse return null;

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
        .pitch = info.pixels_per_scan_line * (@as(u32, bpp) / 8),
        .bpp = bpp,
        .pixel_bgr = pixel_bgr,
    };

    puts(out, "    [*] GOP Framebuffer: ");
    printDecimal(out, fb_info.width);
    puts(out, "x");
    printDecimal(out, fb_info.height);
    puts(out, "x");
    printDecimal(out, @as(u32, bpp));
    puts(out, "\r\n");

    return fb_info;
}

fn loadAndBootLoongArchKernel(out: anytype, bs: *uefi.tables.BootServices) void {
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
    if (ehdr.e_machine != @intFromEnum(elf.EM.LOONGARCH)) {
        puts(out, "    [!!] Not a LoongArch ELF\r\n");
        return;
    }

    puts(out, "    [*] ELF64 valid, ");
    printDecimal(out, ehdr.e_phnum);
    puts(out, " program headers\r\n");

    var segments_loaded: u32 = 0;
    for (0..ehdr.e_phnum) |i| {
        const ph_off: usize = @intCast(ehdr.e_phoff + @as(u64, @intCast(i)) * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;

        const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        var paddr: u64 = phdr.p_paddr;
        if (paddr == 0) paddr = phdr.p_vaddr;

        const num_pages: usize = @intCast((phdr.p_memsz + 4095) / 4096);
        const page_base: usize = @intCast(paddr & ~@as(u64, 0xFFF));
        const dest_ptr: [*]align(4096) uefi.Page = @ptrFromInt(page_base);

        _ = bs.allocatePages(.{ .address = dest_ptr }, .loader_data, num_pages) catch {};

        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(paddr)));
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

    _ = queryGopFramebuffer(out, bs);

    puts(out, "    [*] kernel entry at 0x");
    printHex64(out, ehdr.e_entry);
    puts(out, "\r\n");

    const hand = handoffForSelectedEntry(menu.selected);
    const ho_ptr: [*]align(4096) uefi.Page = @ptrFromInt(HANDOFF_PHYS);
    _ = bs.allocatePages(.{ .address = ho_ptr }, .loader_data, 1) catch {
        puts(out, "    [!!] Failed to allocate handoff page\r\n");
        return;
    };
    const hp: *EfiHandoff = @ptrCast(ho_ptr);
    hp.* = hand;

    var mmap_buf: [32768]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    puts(out, "    [*] Exiting boot services...\r\n");

    bs.exitBootServices(uefi.handle, mmap.info.key) catch {
        const mmap2 = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch return;
        bs.exitBootServices(uefi.handle, mmap2.info.key) catch return;
    };

    jumpToKernel(ehdr.e_entry, HANDOFF_PHYS);
}

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

fn puts(out: anytype, comptime s: []const u8) void {
    _ = out.outputString(unicode.utf8ToUtf16LeStringLiteral(s)) catch false;
}

fn putsRuntime(out: anytype, s: []const u8) void {
    for (s) |c| {
        var buf: [1:0]u16 = .{@as(u16, c)};
        _ = out.outputString(&buf) catch false;
    }
}

export fn efi_main(image_handle: uefi.Handle, st: *uefi.tables.SystemTable) callconv(uefi.cc) uefi.Status {
    uefi.handle = image_handle;
    uefi.system_table = st;
    return runBootManager(st);
}
