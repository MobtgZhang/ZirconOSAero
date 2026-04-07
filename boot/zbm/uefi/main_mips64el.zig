//! ZirconOSAero Boot Manager (ZBM) — MIPS64EL UEFI
//!
//! Zig build-obj + GNU-EFI/ld + objcopy flow → BOOTMIPS64EL.EFI.
//! Follows same architecture as LoongArch64 ZBM (main_loongarch64.zig).

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

const arch_name = "mips64el";
const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const preferred_fb_width = @import("build_options").zbm_preferred_fb_width;
const preferred_fb_height = @import("build_options").zbm_preferred_fb_height;

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

fn earlyPrint(st: *uefi.tables.SystemTable, msg: [*:0]const u16) void {
    if (st.con_out) |con| {
        _ = con.outputString(msg) catch {};
    }
}

/// UEFI entry point for MIPS64EL ZBM.
export fn efi_main(image_handle: uefi.Handle, system_table: *uefi.tables.SystemTable) callconv(.c) uefi.Status {
    const st = system_table;
    earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("ZirconOSAero ZBM [MIPS64EL UEFI]\r\n"));

    // Get boot services
    const bs = st.boot_services orelse return .load_error;

    // Allocate handoff page at fixed physical address (Zig 0.15: AllocateLocation union)
    const handoff_page: [*]align(4096) uefi.Page = @ptrFromInt(HANDOFF_PHYS);
    if (bs.allocatePages(.{ .address = handoff_page }, .loader_data, 1)) |_| {} else |_| {
        earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("[ZBM] WARN: handoff page alloc failed, using address anyway\r\n"));
    }

    // Fill handoff base
    const hoff_base = HANDOFF_PHYS;
    storeU32(hoff_base + @offsetOf(EfiHandoff, "magic"), ZIRCON_MIPS64EL_EFI_MAGIC);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "version"), 3);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "boot_mode"), 0);
    storeU32(hoff_base + @offsetOf(EfiHandoff, "desktop"), comptimeDesktopId());

    // Try to get GOP framebuffer (Zig 0.15: locateProtocol(ProtocolType, registration))
    const gop_opt = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null;
    if (gop_opt) |g| {
        const mode = g.mode;
        if (mode.frame_buffer_base != 0) {
            storeU64(hoff_base + @offsetOf(EfiHandoff, "fb_addr"), mode.frame_buffer_base);
            const info = mode.info.*;
            storeU32(hoff_base + @offsetOf(EfiHandoff, "fb_width"), info.horizontal_resolution);
            storeU32(hoff_base + @offsetOf(EfiHandoff, "fb_height"), info.vertical_resolution);
            storeU32(hoff_base + @offsetOf(EfiHandoff, "fb_pitch"), info.pixels_per_scan_line * 4);
            storeU8(hoff_base + @offsetOf(EfiHandoff, "fb_bpp"), 32);
        }
    }

    // Get memory map (Zig 0.15: getMemoryMap([]align u8) → MemoryMapSlice)
    var mmap_buf: [32768]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    var mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
        earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("[ZBM] ERROR: getMemoryMap failed\r\n"));
        return .load_error;
    };

    // Convert EFI mmap to kernel format in handoff page
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

    earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("[ZBM] ExitBootServices...\r\n"));

    bs.exitBootServices(image_handle, mmap.info.key) catch {
        mmap = bs.getMemoryMap(@as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) catch {
            earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("[ZBM] FATAL: getMemoryMap after ExitBootServices fail\r\n"));
            while (true) {}
        };
        bs.exitBootServices(image_handle, mmap.info.key) catch {
            earlyPrint(st, std.unicode.utf8ToUtf16LeStringLiteral("[ZBM] FATAL: ExitBootServices failed\r\n"));
            while (true) {}
        };
    };

    // Jump to kernel _start with handoff info
    // $a0 = magic, $a1 = handoff physical address
    const kernel_entry: *const fn (u64, u64) callconv(.c) noreturn = @ptrFromInt(0xFFFFFFFF80100000);
    kernel_entry(ZIRCON_MIPS64EL_EFI_MAGIC, HANDOFF_PHYS);
}
