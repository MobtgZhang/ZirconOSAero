const std = @import("std");
const uefi = std.os.uefi;
const builtin = @import("builtin");
const unicode = std.unicode;

const arch_name = switch (builtin.target.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .riscv64 => "riscv64",
    .loongarch64 => "loongarch64",
    else => "unknown",
};

const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;

// ── ZirconOS Boot Manager Constants ──

const ZBM_VERSION = "6.1";
const TIMER_INTERVAL: u64 = 10_000_000; // 1 second in 100ns units
const DEFAULT_TIMEOUT: u32 = 10;
const MAX_ENTRIES: usize = 8;

/// Windows 7–style text boot menu (black background). VGA attribute bytes.
const Attr = struct {
    const normal: u8 = 0x0F; // bright white on black
    const dim: u8 = 0x07; // light gray on black
    const highlight: u8 = 0x70; // black on light gray (selection bar)
    const border: u8 = 0x08; // dark gray on black (separator)
};

const KERNEL_PATH = "\\boot\\kernel.elf";
const BCD_PATH = "\\boot\\BCD";

// ── Boot Entry ──

const BootEntry = struct {
    description: []const u8,
    kernel_path: []const u8,
    cmdline: []const u8,
    is_default: bool,
};

// ── Boot Manager State ──

var entries: [MAX_ENTRIES]BootEntry = undefined;
var entry_count: usize = 0;
var selected: usize = 0;
var countdown: u32 = DEFAULT_TIMEOUT;
var timer_active: bool = true;

fn initBootEntries() void {
    // DESKTOP=none: default boot is text/CMD session, not a graphical desktop theme.
    if (comptime std.mem.eql(u8, desktop_theme_name, "none")) {
        addEntry("ZirconOSAero (NT 6.1)", KERNEL_PATH, "console=serial,vga debug=0 shell=cmd", true);
        addEntry("ZirconOSAero (NT 6.1) [Debug Mode]", KERNEL_PATH, "console=serial,vga debug=1 verbose=1 shell=cmd", false);
    } else {
        addEntry("ZirconOSAero (NT 6.1)", KERNEL_PATH, "console=serial,vga debug=0 desktop=" ++ desktop_theme_name, true);
        addEntry("ZirconOSAero (NT 6.1) [Debug Mode]", KERNEL_PATH, "console=serial,vga debug=1 verbose=1 desktop=" ++ desktop_theme_name, false);
    }
    addEntry("ZirconOSAero [Safe Mode]", KERNEL_PATH, "safe_mode=1 debug=0 minimal=1", false);
    addEntry("ZirconOSAero [Safe Mode with Networking]", KERNEL_PATH, "safe_mode=1 network=1", false);
    addEntry("ZirconOSAero [Recovery Console]", KERNEL_PATH, "recovery=1 console=serial,vga debug=1", false);
    addEntry("ZirconOSAero [CMD Shell]", KERNEL_PATH, "console=serial,vga shell=cmd", false);
}

fn addEntry(desc: []const u8, path: []const u8, cmdline: []const u8, is_default: bool) void {
    if (entry_count >= MAX_ENTRIES) return;
    entries[entry_count] = .{
        .description = desc,
        .kernel_path = path,
        .cmdline = cmdline,
        .is_default = is_default,
    };
    entry_count += 1;
}

// ── UEFI Boot Manager Entry Point ──

pub fn main() noreturn {
    const st = uefi.system_table;
    const out = st.con_out orelse halt();
    const bs = st.boot_services orelse halt();

    out.reset(false) catch {};

    // Set console mode to 80x25 (mode 0) if available
    _ = out.setMode(0) catch {};

    initBootEntries();

    // ── Display Boot Manager Menu ──
    displayBootManagerMenu(out);
    _ = out.enableCursor(false) catch {};

    // ── Interactive Menu Loop ──
    const cin = st.con_in orelse {
        // No console input (headless firmware): boot default entry immediately.
        // Previously we halted here, which prevented the kernel from ever loading.
        displayBootProgress(out);
        loadAndBootKernel(out, bs);
        puts(out, "\r\n");
        puts(out, "  [!!] Failed to load kernel image (no console input path).\r\n");
        halt();
    };

    while (true) {
        // Check for keypress
        if (readKey(cin)) |key| {
            timer_active = false;

            switch (key.scan_code) {
                0x01 => { // Up arrow
                    if (selected > 0) selected -= 1;
                    displayBootManagerMenu(out);
                },
                0x02 => { // Down arrow
                    if (selected + 1 < entry_count) selected += 1;
                    displayBootManagerMenu(out);
                },
                0x0D => { // Enter (scan code for some UEFI)
                    break; // Boot selected
                },
                0x17 => { // ESC
                    displayAdvancedOptions(out);
                },
                else => {
                    if (key.unicode_char == '\r' or key.unicode_char == '\n') {
                        break; // Boot selected
                    }
                    // Number keys 1-6
                    if (key.unicode_char >= '1' and key.unicode_char <= '6') {
                        const idx: usize = key.unicode_char - '1';
                        if (idx < entry_count) {
                            selected = idx;
                            break;
                        }
                    }
                },
            }
        }

        // Timer tick (simple busy wait, ~1 second intervals)
        if (timer_active) {
            waitOneSecond(bs);
            if (countdown > 0) {
                countdown -= 1;
                updateTimerDisplay(out);
            } else {
                break; // Timeout: boot default
            }
        }
    }

    // ── Boot the selected entry ──
    out.reset(false) catch {};
    displayBootProgress(out);

    // Attempt to load kernel from ESP
    loadAndBootKernel(out, bs);

    // If kernel load failed, show error
    puts(out, "\r\n");
    puts(out, "  [!!] Failed to load kernel image.\r\n");
    puts(out, "  [!!] Verify ESP:\\EFI\\BOOT\\BOOT*.EFI and \\boot\\kernel.elf on the FAT volume.\r\n");
    puts(out, "  [!!] System halted.\r\n");
    halt();
}

// ── Menu Display ──

/// Row index (0-based) of the countdown line for the current `entry_count` layout.
fn bootMenuTimerRow() usize {
    return 11 + entry_count;
}

fn clearTextRow(out: anytype, row: usize) void {
    _ = out.setCursorPosition(0, row) catch return;
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    var c: usize = 0;
    while (c < 80) : (c += 1) {
        puts(out, " ");
    }
}

/// Redraw only the countdown line (avoids full `reset` + repaint every second — no flicker).
fn refreshTimerLine(out: anytype) void {
    if (!timer_active or countdown == 0) return;
    const row = bootMenuTimerRow();
    _ = out.setCursorPosition(0, row) catch {
        displayBootManagerMenu(out);
        return;
    };
    _ = out.enableCursor(false) catch {};
    clearTextRow(out, row);
    _ = out.setCursorPosition(0, row) catch {
        displayBootManagerMenu(out);
        return;
    };
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "    Seconds until the highlighted choice will be started automatically: ");
    printDecimal(out, countdown);
    puts(out, "\r\n");
}

fn displayBootManagerMenu(out: anytype) void {
    out.reset(false) catch {};

    // Black screen, white text (Windows 7 text-mode boot menu style)
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};

    puts(out, "\r\n");
    puts(out, "                    ZirconOS Boot Manager                                     \r\n");
    puts(out, "                         Version " ++ ZBM_VERSION ++ "                                             \r\n");

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "    Choose an operating system to start:\r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");
    puts(out, "\r\n");

    // Display entries
    for (0..entry_count) |i| {
        if (i == selected) {
            _ = out.setAttribute(@bitCast(Attr.highlight)) catch {};
            puts(out, "  > ");
        } else {
            _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
            puts(out, "    ");
        }
        putsRuntime(out, entries[i].description);
        puts(out, "\r\n");
    }

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    _ = out.setAttribute(@bitCast(Attr.border)) catch {};
    puts(out, "    ");
    for (0..72) |_| puts(out, "-");
    puts(out, "\r\n\r\n");

    // Timer
    if (timer_active and countdown > 0) {
        _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
        puts(out, "    Seconds until the highlighted choice will be started automatically: ");
        printDecimal(out, countdown);
        puts(out, "\r\n");
    }

    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");

    // Description of selected entry
    puts(out, "    ");
    displayEntryDescription(out, selected);
    puts(out, "\r\n");

    // Footer
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "  ENTER=Choose  |  ESC=Advanced Options  |  F1=Help                          \r\n");

    // System info
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Architecture: " ++ arch_name ++ "  |  Boot: UEFI");
    if (debug_mode) {
        puts(out, "  |  Build: DEBUG\r\n");
    } else {
        puts(out, "  |  Build: RELEASE\r\n");
    }

    _ = out.enableCursor(false) catch {};
}

fn displayEntryDescription(out: anytype, index: usize) void {
    if (index == 0) {
        puts(out, "Start ZirconOS normally.");
    } else if (index == 1) {
        puts(out, "Start with debug logging and serial output enabled.");
    } else if (index == 2) {
        puts(out, "Start with minimal drivers and services.");
    } else if (index == 3) {
        puts(out, "Start in safe mode with network support.");
    } else if (index == 4) {
        puts(out, "Start the Recovery Console for system repair.");
    } else if (index == 5) {
        puts(out, "Use the last configuration that worked.");
    }
}

fn updateTimerDisplay(out: anytype) void {
    refreshTimerLine(out);
}

fn displayAdvancedOptions(out: anytype) void {
    out.reset(false) catch {};
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "                ZirconOS Advanced Boot Options                                 \r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Boot Information:\r\n");
    puts(out, "      Architecture : " ++ arch_name ++ "\r\n");
    puts(out, "      Boot Method  : UEFI Application\r\n");
    puts(out, "      Firmware     : ");
    _ = out.outputString(uefi.system_table.firmware_vendor) catch false;
    puts(out, "\r\n");

    printUefiVersion(out, uefi.system_table.hdr.revision);

    puts(out, "\r\n");
    puts(out, "    Partition Information:\r\n");
    puts(out, "      Scheme       : GPT (GUID Partition Table)\r\n");
    puts(out, "      Boot Partition: EFI System Partition (ESP)\r\n");
    puts(out, "      Kernel Path  : " ++ KERNEL_PATH ++ "\r\n");
    puts(out, "\r\n");
    puts(out, "    Boot Configuration Data (BCD):\r\n");
    puts(out, "      Store        : In-memory (default entries)\r\n");
    puts(out, "      Entries      : ");
    printDecimal(out, @intCast(entry_count));
    puts(out, "\r\n");
    puts(out, "      Default      : ");
    putsRuntime(out, entries[0].description);
    puts(out, "\r\n");
    puts(out, "      Timeout      : ");
    printDecimal(out, DEFAULT_TIMEOUT);
    puts(out, " seconds\r\n");
    puts(out, "\r\n");

    if (debug_mode) {
        puts(out, "    Debug Features:\r\n");
        puts(out, "      [*] Verbose kernel log (EMERG..DEBUG)\r\n");
        puts(out, "      [*] Dual output: VGA + Serial (COM1)\r\n");
        puts(out, "      [*] GDB remote debugging support\r\n");
        puts(out, "\r\n");
    }

    puts(out, "    Supported Boot Paths (ZBM only in this tree):\r\n");
    puts(out, "      UEFI    : EFI Application -> ZBM -> kernel.elf (GPT)\r\n");
    puts(out, "      BIOS    : MBR -> VBR -> stage2 -> ZBM -> kernel.elf\r\n");
    puts(out, "\r\n");

    puts(out, "    Boot Chain:\r\n");
    puts(out, "      zbmfw.efi -> zbmload -> kernel -> HAL\r\n");
    puts(out, "        -> Executive Init -> smss -> csrss -> shell\r\n");
    puts(out, "\r\n");
    puts(out, "    Kernel Phases (0-11):\r\n");
    puts(out, "      0: Early Init          6: I/O + FS + Drivers\r\n");
    puts(out, "      1: Boot + Hardware     7: PE/ELF Loader\r\n");
    puts(out, "      2: Trap/Timer/Sched    8: Native Userland\r\n");
    puts(out, "      3: VM + User Mode      9: Win32 Subsystem\r\n");
    puts(out, "      4: Object/Handle      10: GUI (user32/gdi32)\r\n");
    puts(out, "      5: IPC + Services     11: WOW64 (32-bit)\r\n");
    puts(out, "\r\n");

    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "  Press any key to return to boot menu...                                     \r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};

    // Wait for keypress
    if (uefi.system_table.con_in) |cin| {
        waitForKey(cin);
    }

    timer_active = false;
    displayBootManagerMenu(out);
}

// ── Boot Progress Display ──

fn displayBootProgress(out: anytype) void {
    _ = out.setAttribute(@bitCast(Attr.normal)) catch {};
    puts(out, "\r\n");
    puts(out, "                    ZirconOS Boot Manager                                     \r\n");
    _ = out.setAttribute(@bitCast(Attr.dim)) catch {};
    puts(out, "\r\n");
    puts(out, "    Booting: ");
    putsRuntime(out, entries[selected].description);
    puts(out, "\r\n\r\n");
    puts(out, "    Command line: ");
    putsRuntime(out, entries[selected].cmdline);
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

const UefiVectorTable = extern struct {
    magic: u32,
    version: u32,
    kernel_entry: u64,
    stack_addr: u64,
};

// ── Kernel Loading (UEFI) ──

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

    // ── Step 4: Load PT_LOAD segments into physical memory ──
    var segments_loaded: u32 = 0;
    for (0..ehdr.e_phnum) |i| {
        const ph_off: usize = @intCast(ehdr.e_phoff + i * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;

        const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        const num_pages: usize = @intCast((phdr.p_memsz + 4095) / 4096);
        const page_base: usize = @intCast(phdr.p_paddr & ~@as(u64, 0xFFF));

        _ = bs.allocatePages(
            .{ .address = @ptrFromInt(page_base) },
            .loader_data,
            num_pages,
        ) catch {
            // Pages might overlap or be pre-allocated; continue anyway
        };

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

    var vec: ?*const UefiVectorTable = null;
    if (kernel_base != 0) {
        // Scan the first 64KB from kernel base for the magic pattern
        const scan_end = kernel_base + 0x10000;
        var addr = kernel_base;
        while (addr + @sizeOf(UefiVectorTable) <= scan_end) : (addr += 8) {
            const candidate: *const UefiVectorTable = @ptrFromInt(addr);
            if (candidate.magic == UEFI_VECTOR_MAGIC and candidate.version == 0 and
                candidate.kernel_entry > kernel_base and candidate.stack_addr > kernel_base)
            {
                vec = candidate;
                break;
            }
        }
    }

    if (vec == null) {
        puts(out, "    [!!] UEFI vector table not found in kernel\r\n");
        return;
    }

    const kernel_entry = vec.?.kernel_entry;
    puts(out, "    [*] kernel_main at 0x");
    printHex64(out, kernel_entry);
    puts(out, "\r\n");

    // ── Step 6: Query GOP framebuffer (must be done BEFORE ExitBootServices) ──
    const gop_fb = queryGopFramebuffer(out, bs);

    // ── Step 7: Build Multiboot2-compatible boot info ──
    const boot_info_pages = bs.allocatePages(.{ .any = {} }, .loader_data, 2) catch {
        puts(out, "    [!!] Failed to allocate boot info memory\r\n");
        return;
    };
    const bi_base: [*]u8 = @ptrCast(boot_info_pages.ptr);
    @memset(bi_base[0..8192], 0);

    // Get UEFI memory map (final state) and build boot info from it
    var mmap_buf: [32768]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    const boot_info_addr = buildBootInfo(bi_base, mmap, entries[selected].cmdline, gop_fb);
    puts(out, "    [*] Multiboot2 boot info ready\r\n");

    // ── Step 8: Exit boot services ──
    puts(out, "    [*] Exiting boot services...\r\n");

    bs.exitBootServices(uefi.handle, mmap.info.key) catch {
        // Key changed, retry
        const mmap2 = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch return;
        _ = buildBootInfo(bi_base, mmap2, entries[selected].cmdline, gop_fb);
        bs.exitBootServices(uefi.handle, mmap2.info.key) catch return;
    };

    // ═══ NO MORE UEFI CALLS PAST THIS POINT ═══

    // ── Step 8: Jump to kernel_main ──
    // kernel_main uses System V AMD64 ABI: RDI=magic, RSI=info_addr
    // CRITICAL: Set RSP to the kernel stack from the UEFI vector table.
    // The UEFI stack lives in firmware memory that becomes unmapped when
    // the kernel loads its own page tables (Phase 3 identity-maps ~512MB).
    const kernel_stack = vec.?.stack_addr;
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
        : .{ .rdi = true, .rsi = true, .rsp = true, .rbp = true }
    );
    unreachable;
}

fn buildBootInfo(
    bi_base: [*]u8,
    mmap: uefi.tables.MemoryMapSlice,
    cmdline: []const u8,
    gop_fb: ?GopFbInfo,
) usize {
    var off: usize = 8; // skip BootInfoHeader (filled at end)

    // Tag: command line (type=1)
    {
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 1;
        const str_sz: u32 = @intCast(cmdline.len + 1);
        p[1] = 8 + str_sz;
        @memcpy((bi_base + off + 8)[0..cmdline.len], cmdline);
        (bi_base + off + 8)[cmdline.len] = 0;
        off += (8 + str_sz + 7) & ~@as(usize, 7);
    }

    // Tag: basic memory info (type=4)
    const meminfo_off = off;
    {
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
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 6;
        p[2] = 24; // entry_size
        p[3] = 0; // entry_version
        var eoff: usize = 16;
        var mem_upper_kb: u32 = 0;

        var it = mmap.iterator();
        while (it.next()) |desc| {
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

        off += (eoff + 7) & ~@as(usize, 7);
    }

    // Tag: framebuffer (type=8) — GOP framebuffer info for graphical desktop
    if (gop_fb) |fb| {
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
        off += (32 + 7) & ~@as(usize, 7);
    }

    // Tag: end (type=0)
    {
        const p: [*]u32 = @ptrCast(@alignCast(bi_base + off));
        p[0] = 0;
        p[1] = 8;
        off += 8;
    }

    // Fill boot info header
    const hdr: [*]u32 = @ptrCast(@alignCast(bi_base));
    hdr[0] = @intCast(off); // total_size
    hdr[1] = 0; // reserved

    return @intFromPtr(bi_base);
}

fn uefiToMb2MemType(t: uefi.tables.MemoryType) u32 {
    return switch (t) {
        .conventional_memory, .loader_code, .loader_data,
        .boot_services_code, .boot_services_data,
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

const InputKey = uefi.protocol.SimpleTextInputEx.Key.Input;

fn readKey(cin: anytype) ?InputKey {
    return cin.readKeyStroke() catch return null;
}

fn waitForKey(cin: anytype) void {
    while (true) {
        if (readKey(cin) != null) return;
    }
}

fn waitOneSecond(bs: *uefi.tables.BootServices) void {
    _ = bs.stall(1_000_000) catch {
        var i: u64 = 0;
        while (i < 30_000_000) : (i += 1) {
            asm volatile ("" ::: .{ .memory = true });
        }
    };
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
