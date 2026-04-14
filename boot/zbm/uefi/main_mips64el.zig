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

//! ZirconOSAero Boot Manager (ZBM) — MIPS64EL UEFI
//!
//! Zig build-obj + GNU-EFI/ld + objcopy flow → BOOTMIPS64EL.EFI.
//! Follows same architecture as LoongArch64 ZBM (main_loongarch64.zig).
//! Includes full menu interaction with keyboard navigation.

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const unicode = std.unicode;

const menu = @import("menu_common.zig");
const zto = @import("zbm_text_out.zig");

comptime {
    if (builtin.target.cpu.arch != .mips64el)
        @compileError("main_mips64el.zig must be built for mips64el only");
}

const arch_name = "mips64el";
const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const preferred_fb_width = @import("build_options").zbm_preferred_fb_width;
const preferred_fb_height = @import("build_options").zbm_preferred_fb_height;

const KERNEL_PATH = menu.KERNEL_PATH;
const Attr = menu.Attr;

const ZIRCON_MIPS64EL_EFI_MAGIC: u32 = 0x6D697073;
const HANDOFF_PHYS: usize = 0x1FF000;
const MMAP_STORE_OFF: usize = 0x200;

const EfiHandoff = extern struct {
    magic: u32,
    version: u32,
    boot_mode: u32,
    desktop: u32,
    fb_addr: u64 = 0,
    fb_pitch: u32 = 0,
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    fb_bpp: u8 = 0,
    _pad: [3]u8 = [_]u8{0} ** 3,
    mmap_count: u32 = 0,
    mmap_entry_size: u32 = 0,
    mmap_off_from_handoff: u32 = 0,
    _mmap_pad: u32 = 0,
};

const KernelMmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
};

var g_text_in_ex: ?*uefi.protocol.SimpleTextInputEx = null;
var g_bs: *uefi.tables.BootServices = undefined;

fn storeU32(ptr: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(ptr)).* = val;
}

fn storeU64(ptr: usize, val: u64) void {
    @as(*volatile u64, @ptrFromInt(ptr)).* = val;
}

fn storeU8(ptr: usize, val: u8) void {
    @as(*volatile u8, @ptrFromInt(ptr)).* = val;
}

fn efiToKernelMmapType(mt: u32) u32 {
    const MT = uefi.tables.MemoryType;
    if (mt == @intFromEnum(MT.conventional_memory)) return 1;
    if (mt == @intFromEnum(MT.acpi_reclaim_memory)) return 3;
    if (mt == @intFromEnum(MT.unusable_memory)) return 5;
    if (mt == @intFromEnum(MT.reserved_memory_type)) return 5;
    return 2;
}

fn comptimeDesktopId() u32 {
    const s = desktop_theme_name;
    if (comptime std.mem.eql(u8, s, "none")) return 0;
    return 1;
}

fn locateSimpleTextInputEx(bs: *uefi.tables.BootServices) ?*uefi.protocol.SimpleTextInputEx {
    return bs.locateProtocol(uefi.protocol.SimpleTextInputEx, null) catch null;
}

fn readKeyStrokeSimple(cin: *uefi.protocol.SimpleTextInput) ?uefi.protocol.SimpleTextInput.Key.Input {
    return cin.readKeyStroke() catch null;
}

fn readKeyStrokeEx(ex: *uefi.protocol.SimpleTextInputEx) ?uefi.protocol.SimpleTextInputEx.Key {
    return ex.readKeyStroke() catch null;
}

fn checkEventSignaled(bs: *uefi.tables.BootServices, event: uefi.Event) bool {
    return bs.checkEvent(event) catch false;
}

fn stallMicroseconds(bs: *uefi.tables.BootServices, micros: usize) void {
    bs.stall(micros) catch {};
}

fn waitForEventWithStallFallback(bs: *uefi.tables.BootServices, events: []const uefi.Event) void {
    _ = bs.waitForEvent(events) catch {
        bs.stall(10_000) catch {};
    };
}

fn readKeyStrokeSimpleForMenu(cin: *uefi.protocol.SimpleTextInput) ?menu.KeyInput {
    if (readKeyStrokeSimple(cin)) |simple_key| {
        return .{
            .input = simple_key,
            .state = .{
                .shift = .{
                    .right_shift_pressed = false,
                    .left_shift_pressed = false,
                    .right_control_pressed = false,
                    .left_control_pressed = false,
                    .right_alt_pressed = false,
                    .left_alt_pressed = false,
                    .right_logo_pressed = false,
                    .left_logo_pressed = false,
                    .menu_key_pressed = false,
                    .sys_req_pressed = false,
                    .shift_state_valid = false,
                },
                .toggle = .{
                    .scroll_lock_active = false,
                    .num_lock_active = false,
                    .caps_lock_active = false,
                    .key_state_exposed = false,
                    .toggle_state_valid = false,
                },
            },
        };
    }
    return null;
}

fn tryReadKeyUnified(cin: *uefi.protocol.SimpleTextInput) ?menu.KeyInput {
    if (g_text_in_ex) |ex| {
        if (readKeyStrokeEx(ex)) |full| return full;
        if (checkEventSignaled(g_bs, ex.wait_for_key_ex)) {
            if (readKeyStrokeEx(ex)) |full| return full;
        }
    }
    if (readKeyStrokeSimpleForMenu(cin)) |k| return k;
    if (checkEventSignaled(g_bs, cin.wait_for_key)) {
        return readKeyStrokeSimpleForMenu(cin);
    }
    return null;
}

fn waitForKey(bs: *uefi.tables.BootServices, cin: *uefi.protocol.SimpleTextInput) void {
    while (true) {
        if (tryReadKeyUnified(cin)) |_| return;

        if (g_text_in_ex) |ex| {
            const evs = [_]uefi.Event{ ex.wait_for_key_ex, cin.wait_for_key };
            waitForEventWithStallFallback(bs, evs[0..]);
        } else {
            waitForEventWithStallFallback(bs, &.{cin.wait_for_key});
        }
    }
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

fn printDecimal(out: anytype, value: u32) void {
    if (value >= 10) printDecimal(out, value / 10);
    var buf: [1:0]u16 = .{@as(u16, @intCast('0' + (value % 10)))};
    zto.outputString(out, &buf);
}

fn puts(out: anytype, comptime s: []const u8) void {
    zto.outputString(out, unicode.utf8ToUtf16LeStringLiteral(s));
}

fn putsRuntime(out: anytype, s: []const u8) void {
    var si: usize = 0;
    while (si < s.len) : (si += 1) {
        const c = s[si];
        var buf: [1:0]u16 = .{@as(u16, c)};
        zto.outputString(out, &buf);
    }
}

fn displayBootProgress(out: anytype, selected_idx: usize) void {
    zto.setAttribute(out, Attr.normal);
    puts(out, "\r\n");
    puts(out, "                 ZirconOSAero Boot Manager (NT 6.1)                            \r\n");
    zto.setAttribute(out, Attr.dim);
    puts(out, "\r\n");
    puts(out, "    Booting: ");
    menu.putsRuntimeBootEntryDesc(out, selected_idx);
    puts(out, "\r\n\r\n");
    puts(out, "    Command line: ");
    menu.putsRuntimeBootEntryCmdline(out, selected_idx);
    puts(out, "\r\n\r\n");

    puts(out, "    [*] UEFI Console initialized\r\n");

    displayMemoryMap(out, g_bs);

    puts(out, "    [*] Loading kernel image...\r\n");
    puts(out, "    [*] Path: " ++ KERNEL_PATH ++ "\r\n");
    puts(out, "\r\n");
}

fn runBootManager(out: anytype, bs: *uefi.tables.BootServices, cin: *uefi.protocol.SimpleTextInput) void {
    g_bs = bs;
    g_text_in_ex = locateSimpleTextInputEx(bs);

    menu.initBootEntries(desktop_theme_name, KERNEL_PATH);

    var result: menu.MenuResult = undefined;
    var need_full_redraw = true;

    while (true) {
        if (need_full_redraw) {
            menu.displayBootManagerMenu(out, arch_name, debug_mode);
            need_full_redraw = false;
        }

        if (tryReadKeyUnified(cin)) |key| {
            menu.timer_active = false;

            if (key.input.unicode_char == '\t') {
                menu.menu_focus = if (menu.menu_focus == .os_list) .tools_list else .os_list;
                need_full_redraw = true;
                continue;
            }

            if (key.input.scan_code == menu.SCAN_ESC) {
                _ = bs.exit(uefi.handle, uefi.Status.aborted, null) catch {};
                while (true) {}
            }

            if (key.input.scan_code == menu.SCAN_F8) {
                menu.displayAdvancedOptions(
                    out,
                    bs,
                    cin,
                    arch_name,
                    KERNEL_PATH,
                    uefi.system_table.firmware_vendor,
                    uefi.system_table.hdr.revision,
                    debug_mode,
                );
                menu.displayBootManagerMenu(out, arch_name, debug_mode);
                continue;
            }

            const is_up = key.input.scan_code == menu.SCAN_UP or key.input.scan_code == menu.SCAN_UP_EXT or
                key.input.scan_code == menu.SCAN_PAGE_UP or key.input.scan_code == menu.SCAN_HOME or
                key.input.unicode_char == menu.UNICODE_UP or key.input.unicode_char == 'k' or key.input.unicode_char == 'w';
            const is_down = key.input.scan_code == menu.SCAN_DOWN or key.input.scan_code == menu.SCAN_DOWN_EXT or
                key.input.scan_code == menu.SCAN_PAGE_DOWN or key.input.scan_code == menu.SCAN_END or
                key.input.unicode_char == menu.UNICODE_DOWN or key.input.unicode_char == 'j' or key.input.unicode_char == 's';

            if (menu.menu_focus == .tools_list) {
                if (key.input.scan_code == menu.SCAN_HOME) {
                    menu.tool_selected = 0;
                    menu.redrawToolRows(out);
                    continue;
                }
                if (key.input.scan_code == menu.SCAN_END and menu.tool_descriptions.len > 0) {
                    menu.tool_selected = menu.tool_descriptions.len - 1;
                    menu.redrawToolRows(out);
                    continue;
                }
                if (is_up and menu.tool_selected > 0) {
                    menu.tool_selected -= 1;
                    menu.redrawToolRows(out);
                    continue;
                }
                if (is_down and menu.tool_selected + 1 < menu.tool_descriptions.len) {
                    menu.tool_selected += 1;
                    menu.redrawToolRows(out);
                    continue;
                }
                if (key.input.unicode_char == '\r' or key.input.unicode_char == '\n') {
                    menu.showToolPlaceholderScreen(out, cin);
                    need_full_redraw = true;
                    continue;
                }
                continue;
            }

            if (key.input.scan_code == menu.SCAN_HOME) {
                menu.selected = 0;
                menu.redrawOsEntryRows(out);
                continue;
            }
            if (key.input.scan_code == menu.SCAN_END and menu.entry_count > 0) {
                menu.selected = menu.entry_count - 1;
                menu.redrawOsEntryRows(out);
                continue;
            }
            if (is_up and menu.selected > 0) {
                menu.selected -= 1;
                menu.redrawOsEntryRows(out);
                continue;
            }
            if (is_down and menu.selected + 1 < menu.entry_count) {
                menu.selected += 1;
                menu.redrawOsEntryRows(out);
                continue;
            }
            if (key.input.unicode_char == '\r' or key.input.unicode_char == '\n') {
                result = .{ .selected = menu.selected };
                break;
            }
            if (key.input.unicode_char >= '1' and key.input.unicode_char <= '8') {
                const idx: usize = @intCast(key.input.unicode_char - '1');
                if (idx < menu.entry_count) {
                    menu.selected = idx;
                    result = .{ .selected = menu.selected };
                    break;
                }
            }
            continue;
        }

        stallMicroseconds(bs, 5_000);
    }

    if (result == .selected) {
        zto.reset(out, false);
        displayBootProgress(out, result.selected);
        loadAndBootKernel(out, bs, result.selected);

        puts(out, "\r\n");
        puts(out, "  [!!] Failed to load kernel image.\r\n");
        puts(out, "  [!!] Verify ESP:\\EFI\\BOOT\\BOOTMIPS64EL.EFI and \\boot\\kernel.elf.\r\n");
        puts(out, "  [!!] System halted.\r\n");
        while (true) {}
    }
}

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

fn loadAndBootKernel(out: anytype, bs: *uefi.tables.BootServices, selected_idx: usize) void {
    puts(out, "    [*] Opening kernel from ESP...\r\n");

    const loaded_image = bs.locateProtocol(uefi.protocol.LoadedImage, null) catch null orelse {
        puts(out, "    [!!] Failed to get LoadedImage protocol\r\n");
        return;
    };

    // Get device handle from loaded image (unused but keep for future use)
    _ = loaded_image.device_handle;

    const sfs = bs.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch null orelse {
        puts(out, "    [!!] Failed to get SimpleFileSystem\r\n");
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

    const kernel_entry = ehdr.e_entry;

    puts(out, "    [*] ELF64 valid, ");
    printDecimal(out, ehdr.e_phnum);
    puts(out, " program headers\r\n");

    var segments_loaded: u32 = 0;
    var ph_i: u16 = 0;
    while (ph_i < ehdr.e_phnum) : (ph_i += 1) {
        const ph_off: usize = @intCast(ehdr.e_phoff + @as(u64, ph_i) * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;

        const phdr: *const Elf64_Phdr = @ptrCast(@alignCast(file_data.ptr + ph_off));
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        var paddr: u64 = phdr.p_paddr;
        if (paddr == 0) paddr = phdr.p_vaddr;

        const num_pages: usize = @intCast((phdr.p_memsz + 4095) / 4096);
        const page_base: usize = @intCast(paddr & ~@as(u64, 0xFFF));
        const dest_ptr: [*]align(4096) uefi.Page = @ptrFromInt(page_base);

        const alloc_result: ?[]align(4096) [4096]u8 = bs.allocatePages(.{ .address = dest_ptr }, .loader_data, num_pages) catch null;
        _ = alloc_result;

        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(paddr)));
        const filesz: usize = @intCast(phdr.p_filesz);
        const memsz: usize = @intCast(phdr.p_memsz);
        const offset: usize = @intCast(phdr.p_offset);

        if (filesz > 0 and offset + filesz <= file_size) {
            const src = file_data.ptr + offset;
            var ci: usize = 0;
            while (ci < filesz) : (ci += 1) {
                dst[ci] = src[ci];
            }
        }
        if (memsz > filesz) {
            var zi: usize = filesz;
            const zeros = memsz - filesz;
            while (zi < memsz) : (zi += 1) {
                dst[zi] = 0;
            }
            _ = zeros;
        }

        segments_loaded += 1;
    }

    puts(out, "    [*] Loaded ");
    printDecimal(out, segments_loaded);
    puts(out, " ELF segments\r\n");

    // Setup handoff
    const hoff_base = HANDOFF_PHYS;
    var boot_mode: u32 = 0;
    if (selected_idx == 5) boot_mode = 1;

    storeU32(hoff_base + @offsetOf(EfiHandoff, "magic"), ZIRCON_MIPS64EL_EFI_MAGIC);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "version"), 3);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "boot_mode"), boot_mode);

    var desktop: u32 = comptimeDesktopId();
    if (selected_idx == 2 or selected_idx == 3 or selected_idx == 4 or selected_idx == 5) desktop = 0;
    storeU32(hoff_base + @offsetOf(EfiHandoff, "desktop"), desktop);

    // Memory map
    var mmap_buf: [32768]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    const max_n = (4096 - MMAP_STORE_OFF) / @sizeOf(KernelMmapEntry);
    var n: u32 = 0;
    var it = mmap.iterator();
    while (it.next()) |md| {
        if (n >= max_n) break;
        const dst = HANDOFF_PHYS + MMAP_STORE_OFF + @as(usize, n) * @sizeOf(KernelMmapEntry);
        storeU64(dst + @offsetOf(KernelMmapEntry, "base_addr"), md.physical_start);
        storeU64(dst + @offsetOf(KernelMmapEntry, "length"), md.number_of_pages * 4096);
        storeU32(dst + @offsetOf(KernelMmapEntry, "type"), efiToKernelMmapType(@intFromEnum(md.type)));
        storeU32(dst + @offsetOf(KernelMmapEntry, "reserved"), 0);
        n += 1;
    }
    storeU32(hoff_base + @offsetOf(EfiHandoff, "mmap_count"), n);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "mmap_entry_size"), @sizeOf(KernelMmapEntry));
    storeU32(hoff_base + @offsetOf(EfiHandoff, "mmap_off_from_handoff"), MMAP_STORE_OFF);

    puts(out, "    [*] Exiting boot services...\r\n");

    if (bs.exitBootServices(uefi.handle, mmap.info.key)) {
        puts(out, "    [*] ExitBootServices succeeded\r\n");
    } else |_| {
        const mmap2 = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch return;
        bs.exitBootServices(uefi.handle, mmap2.info.key) catch {};
    }

    puts(out, "    [*] Jumping to kernel at 0x");
    const hex = "0123456789abcdef";
    var v = kernel_entry;
    var hex_buf: [16]u8 = undefined;
    var hi: usize = 16;
    while (hi > 0) {
        hi -= 1;
        hex_buf[hi] = hex[@intCast(v & 0xF)];
        v >>= 4;
    }
    var hj: usize = 0;
    while (hj < hex_buf.len) : (hj += 1) {
        var buf: [1:0]u16 = .{@as(u16, hex_buf[hj])};
        zto.outputString(out, &buf);
    }
    puts(out, "\r\n");

    // Jump to kernel
    const kernel_fn: *const fn (u64, u64) callconv(.c) noreturn = @ptrFromInt(kernel_entry);
    kernel_fn(ZIRCON_MIPS64EL_EFI_MAGIC, HANDOFF_PHYS);
}

/// UEFI entry point for MIPS64EL ZBM.
export fn efi_main(image_handle: uefi.Handle, system_table: *uefi.tables.SystemTable) callconv(.c) uefi.Status {
    const st = system_table;
    const bs = st.boot_services orelse return .load_error;
    const out = st.con_out orelse return .unsupported;
    const cin = st.con_in orelse {
        return .unsupported;
    };

    uefi.handle = image_handle;
    uefi.system_table = st;

    zto.reset(out, false);
    zto.setMode(out, 0);

    g_bs = bs;
    g_text_in_ex = locateSimpleTextInputEx(bs);

    runBootManager(out, bs, cin);

    return .success;
}
