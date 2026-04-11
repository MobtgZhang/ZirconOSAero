//! ZirconOSAero Boot Manager (ZBM) — LoongArch64 UEFI（与 `boot/zbm/uefi/main.zig` 共用 menu_common）
//!
//! Zig build-obj + GNU-EFI/ld + objcopy 或 C stub 流程（linker_stub.lds）生成 BOOTLOONGARCH64.EFI。
//! 默认 Zig 路径：`build.zig` 中 `cpu_model=baseline` + `code_model=medium`，减轻 la464 不支持的指令与 PCREL 溢出（历史 INE/错址）。
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const unicode = std.unicode;
const elf = std.elf;

const menu = @import("menu_common.zig");
const la = @import("loongarch_tcg_mem.zig");
const zto = @import("zbm_text_out.zig");
const zcall = @import("zbm_uefi_calls.zig");

const arch_name = "loongarch64";
const debug_mode = @import("build_options").debug;
const desktop_theme_name = @import("build_options").desktop;
const preferred_fb_width = @import("build_options").zbm_preferred_fb_width;
const preferred_fb_height = @import("build_options").zbm_preferred_fb_height;
const KERNEL_PATH = menu.KERNEL_PATH;
const Attr = menu.Attr;

/// CSR **EUEN**（0x2）：bit0 = PLV0 FPU 使能。EDK2/QEMU 常以 `EUEN=0` 进入 EFI；Zig `baseline` 含 **+d**，未开 FPE 时硬件浮点可 #INE。
/// 另：LLVM 常为大型 `switch`/跳转表生成 **`ldx.d`**；部分 **`-cpu la464` QEMU TCG** 对该类指令支持不完整时会在菜单循环后 #INE（与 EUEN 无关）——见 `Makefile` 的 `QEMU_LOONGARCH64_CPU`（默认 `max`）。
fn enableLoongArchExtendedUnitsEarly() void {
    const CSR_EUEN: comptime_int = 0x2;
    const EUEN_FPE: u64 = 1 << 0;
    asm volatile ("csrwr %[v], %[c]"
        :
        : [v] "r" (EUEN_FPE),
          [c] "i" (CSR_EUEN),
    );
}

// ── LoongArch EFI handoff（与 src/arch/loongarch64/boot.zig 一致）──

const ZIRCON_LOONGARCH_EFI_MAGIC: u32 = 0x6372697A;
/// 须落在 **已加载内核映像之前** 的 RAM 空洞内。`0x100000`（1MiB）在部分 EDK2/QEMU 路径上与固件保留区重叠，`AllocatePages(AtAddress)` 可长时间挂起；`0x1FF000` 为内核首段 PhysAddr `0x200000` 前一页。
const HANDOFF_PHYS: usize = 0x1FF000;
/// 内核入口点字段在 EfiHandoff 结构体中的偏移，通过 @offsetOf 动态获取。
const HANDOFF_KERNEL_ENTRY_OFFSET: usize = @offsetOf(EfiHandoff, "kernel_entry");
/// 入口点在 handoff 页面中的绝对物理地址
const HANDOFF_KERNEL_ENTRY_SLOT: usize = HANDOFF_PHYS + HANDOFF_KERNEL_ENTRY_OFFSET;

/// 与 `src/arch/loongarch64/boot.zig` 中 `EfiHandoff` 布局一致（v2 GOP / v3 mmap / v4 kernel_entry）
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
    /// v4: 内核入口点（由 ZBM 在 ExitBootServices 之前写入）
    kernel_entry: u64 = 0,
};

/// 与内核 `boot.MmapEntry` 布局一致
const KernelMmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
};

const MMAP_STORE_OFF: usize = 0x200;

/// 仅接受 **U32 内存类型值**。LLVM 会把稠密枚举映射优化成小跳转表（`ldx.w`）；用 **asm 屏障**打断值域分析，保留逐次比较。
noinline fn efiToKernelMmapTypeU32(mt: u32) u32 {
    const MT = uefi.tables.MemoryType;
    var m = mt;
    asm volatile (""
        : [m] "+r" (m),
    );
    if (m == @intFromEnum(MT.conventional_memory)) return 1;
    if (m == @intFromEnum(MT.acpi_reclaim_memory)) return 3;
    if (m == @intFromEnum(MT.unusable_memory)) return 5;
    if (m == @intFromEnum(MT.reserved_memory_type)) return 5;
    return 2;
}

fn fillHandoffMmapInto(page: [*]u8, mmap_slice: uefi.tables.MemoryMapSlice, out_count: *u32, out_esz: *u32) void {
    const max_n = (4096 - MMAP_STORE_OFF) / @sizeOf(KernelMmapEntry);
    la.setBytes(page + MMAP_STORE_OFF, 4096 - MMAP_STORE_OFF, 0);
    var i: usize = 0;
    var n: u32 = 0;
    const ds = mmap_slice.info.descriptor_size;
    const base = @intFromPtr(mmap_slice.ptr);
    while (i < mmap_slice.info.len) : (i += 1) {
        if (n >= max_n) break;
        const md_base = base +% i *% ds;
        const mt = la.loadU32Abs(md_base + @offsetOf(uefi.tables.MemoryDescriptor, "type"));
        const phys = la.loadU64Abs(md_base + @offsetOf(uefi.tables.MemoryDescriptor, "physical_start"));
        const pages = la.loadU64Abs(md_base + @offsetOf(uefi.tables.MemoryDescriptor, "number_of_pages"));
        const dst_base = @intFromPtr(page + MMAP_STORE_OFF + @as(usize, n) * @sizeOf(KernelMmapEntry));
        const len = pages * 4096;
        la.storeU64Abs(dst_base + @offsetOf(KernelMmapEntry, "base_addr"), phys);
        la.storeU64Abs(dst_base + @offsetOf(KernelMmapEntry, "length"), len);
        la.storeU32Abs(dst_base + @offsetOf(KernelMmapEntry, "type"), efiToKernelMmapTypeU32(mt));
        la.storeU32Abs(dst_base + @offsetOf(KernelMmapEntry, "reserved"), 0);
        n += 1;
    }
    out_count.* = n;
    out_esz.* = @sizeOf(KernelMmapEntry);
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

fn comptimeDesktopId() u32 {
    const s = desktop_theme_name;
    if (comptime std.mem.eql(u8, s, "none")) return 0;
    return 1;
}

/// 将菜单项映射为 EFI handoff（与 x86 条目语义尽量对应）。
/// **仅 `st.*` 绝对寻址写入**，避免对 `*EfiHandoff` 字段普通赋值与后继路径合成 **`ldx.*`/错跳转**（QEMU LoongArch TCG #INE）。
noinline fn initHandoffBaseAbs(out: *EfiHandoff, idx: usize) void {
    const def_id = comptimeDesktopId();
    var boot_mode: u32 = 0;
    if (idx == 5) boot_mode = 1;

    var desktop: u32 = def_id;
    if (idx == 2) desktop = 0;
    if (idx == 3) desktop = 0;
    if (idx == 4) desktop = 0;
    if (idx == 5) desktop = 0;

    const b = @intFromPtr(out);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "magic"), ZIRCON_LOONGARCH_EFI_MAGIC);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "version"), 1);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "boot_mode"), boot_mode);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "desktop"), desktop);
    la.storeU64Abs(b + @offsetOf(EfiHandoff, "fb_addr"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "fb_pitch"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "fb_width"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "fb_height"), 0);
    la.storeU8Abs(b + @offsetOf(EfiHandoff, "fb_bpp"), 0);
    const pad0 = b + @offsetOf(EfiHandoff, "_pad");
    la.storeU8Abs(pad0 + 0, 0);
    la.storeU8Abs(pad0 + 1, 0);
    la.storeU8Abs(pad0 + 2, 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "mmap_count"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "mmap_entry_size"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "mmap_off_from_handoff"), 0);
    la.storeU32Abs(b + @offsetOf(EfiHandoff, "_mmap_pad"), 0);
}

noinline fn applyGopToHandoffAbs(ho: *EfiHandoff, fb_addr: u64, pitch: u32, w: u32, fb_h: u32, bpp: u8) void {
    const hb = @intFromPtr(ho);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "version"), 2);
    la.storeU64Abs(hb + @offsetOf(EfiHandoff, "fb_addr"), fb_addr);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "fb_pitch"), pitch);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "fb_width"), w);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "fb_height"), fb_h);
    la.storeU8Abs(hb + @offsetOf(EfiHandoff, "fb_bpp"), bpp);
}

noinline fn applyMmapMetaToHandoffAbs(h: *EfiHandoff, mmap_count: u32, mmap_esz: u32) void {
    const hb = @intFromPtr(h);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "mmap_count"), mmap_count);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "mmap_entry_size"), mmap_esz);
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "mmap_off_from_handoff"), MMAP_STORE_OFF);
}

/// 等价 `hand.version = @max(hand.version, 3)`，**勿用** `@max`（LLVM 可能对 u32 生成跳转表）。
noinline fn bumpHandoffVersionAtLeast3Abs(h: *EfiHandoff) void {
    const hb = @intFromPtr(h);
    var v = la.loadU32Abs(hb + @offsetOf(EfiHandoff, "version"));
    if (v < 3) v = 3;
    la.storeU32Abs(hb + @offsetOf(EfiHandoff, "version"), v);
}

/// 将内核入口点通过参数传递给跳转函数。
/// kernel_entry 直接作为参数传入，asm 中用 "r" 约束。
/// 相比从固定槽读取，避免了 LLVM 寄存器分配问题。
fn jumpToKernel(handoff_phys: usize, kernel_entry: u64) noreturn {
    const mag: u64 = @as(u64, ZIRCON_LOONGARCH_EFI_MAGIC);
    asm volatile (
        \\ move $a0, %[mag]
        \\ move $a1, %[hand]
        \\ move $t0, %[entry]
        \\ jr $t0
        :
        : [mag] "r" (mag),
          [hand] "r" (handoff_phys),
          [entry] "r" (kernel_entry),
        : .{});
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

    zto.reset(out, false);
    zto.setMode(out, 0);

    menu.initBootEntries(desktop_theme_name, KERNEL_PATH);

    const cin = st.con_in orelse {
        displayBootProgress(out, menu.selected);
        loadAndBootLoongArchKernel(out, bs, menu.selected);
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
            .cancel => {
                _ = bs.exit(uefi.handle, uefi.Status.aborted, null) catch {};
                haltLa();
            },
        }
    }

    const boot_idx = menu.selected;
    zto.reset(out, false);
    displayBootProgress(out, boot_idx);
    loadAndBootLoongArchKernel(out, bs, boot_idx);

    puts(out, "\r\n");
    puts(out, "  [!!] Failed to load kernel image.\r\n");
    puts(out, "  [!!] Verify ESP:\\EFI\\BOOT\\BOOTLOONGARCH64.EFI and \\boot\\kernel.elf.\r\n");
    puts(out, "  [!!] System halted.\r\n");
    haltLa();
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

    displayMemoryMap(out, uefi.system_table.boot_services orelse return);

    puts(out, "    [*] Loading kernel image...\r\n");
    puts(out, "    [*] Path: " ++ KERNEL_PATH ++ "\r\n");
    puts(out, "\r\n");
}

const GopFbInfo = extern struct {
    addr: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    pixel_bgr: u8,
};

noinline fn storeBoolAbs(p: *bool, v: bool) void {
    la.storeU8Abs(@intFromPtr(p), if (v) 1 else 0);
}

/// 仅 `st.*` 清零，避免对 `*GopFbInfo` 字段成组写与后继路径合成 **错跳转进 `.data` 串区**（QEMU 下 ERA 曾落在 UTF-16 字面量地址，#INE）。
noinline fn resetGopFbInfoAbs(p: *GopFbInfo) void {
    const b = @intFromPtr(p);
    la.storeU64Abs(b + @offsetOf(GopFbInfo, "addr"), 0);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "width"), 0);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "height"), 0);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "pitch"), 0);
    la.storeU8Abs(b + @offsetOf(GopFbInfo, "bpp"), 0);
    la.storeU8Abs(b + @offsetOf(GopFbInfo, "pixel_bgr"), 0);
}

noinline fn commitGopFbInfoAbs(p: *GopFbInfo, addr: u64, w: u32, h: u32, pitch: u32, bpp: u8, pixel_bgr: u8) void {
    const b = @intFromPtr(p);
    la.storeU64Abs(b + @offsetOf(GopFbInfo, "addr"), addr);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "width"), w);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "height"), h);
    la.storeU32Abs(b + @offsetOf(GopFbInfo, "pitch"), pitch);
    la.storeU8Abs(b + @offsetOf(GopFbInfo, "bpp"), bpp);
    la.storeU8Abs(b + @offsetOf(GopFbInfo, "pixel_bgr"), pixel_bgr);
}

/// 将 GOP 尺寸读到独立栈槽；**noinline** 切断 LLVM 跨 `puts`/handoff 的错误跨函数优化（误入 `.data`）。
noinline fn readGopFbHandoffScalars(info: *const GopFbInfo, out_addr: *u64, out_w: *u32, out_h: *u32, out_pitch: *u32, out_bpp: *u8) void {
    const b = @intFromPtr(info);
    la.storeU64Abs(@intFromPtr(out_addr), la.loadU64Abs(b + @offsetOf(GopFbInfo, "addr")));
    la.storeU32Abs(@intFromPtr(out_w), la.loadU32Abs(b + @offsetOf(GopFbInfo, "width")));
    la.storeU32Abs(@intFromPtr(out_h), la.loadU32Abs(b + @offsetOf(GopFbInfo, "height")));
    la.storeU32Abs(@intFromPtr(out_pitch), la.loadU32Abs(b + @offsetOf(GopFbInfo, "pitch")));
    la.storeU8Abs(@intFromPtr(out_bpp), la.loadU8Abs(b + @offsetOf(GopFbInfo, "bpp")));
}

fn gopPixelFormatIsLinear(f: uefi.protocol.GraphicsOutput.PixelFormat) bool {
    return f == .red_green_blue_reserved_8_bit_per_color or
        f == .blue_green_red_reserved_8_bit_per_color or
        f == .bit_mask;
}

/// 内核 handoff 与 `queryGopFramebufferInto` 仅支持 32bpp 线性（RGB/BGR 打包或 bit_mask）；不含 BltOnly。
fn gopModeIs32bppLinear(mi: *const uefi.protocol.GraphicsOutput.Mode.Info) bool {
    return gopPixelFormatIsLinear(mi.pixel_format);
}

/// 同分辨率下优先 RGB、其次 BGR、再 bit_mask（部分固件 bit_mask 与扫描线对齐异常）。
fn gopPixelFormatRank(f: uefi.protocol.GraphicsOutput.PixelFormat) u8 {
    const PF = uefi.protocol.GraphicsOutput.PixelFormat;
    const v = @intFromEnum(f);
    if (v == @intFromEnum(PF.red_green_blue_reserved_8_bit_per_color)) return 0;
    if (v == @intFromEnum(PF.blue_green_red_reserved_8_bit_per_color)) return 1;
    if (v == @intFromEnum(PF.bit_mask)) return 2;
    return 255;
}

fn printGopModeDiag(out: anytype, mid: u32, mi: *const uefi.protocol.GraphicsOutput.Mode.Info) void {
    puts(out, "        ");
    printDecimal(out, mid);
    puts(out, " ");
    printDecimal(out, mi.horizontal_resolution);
    puts(out, "x");
    printDecimal(out, mi.vertical_resolution);
    puts(out, " fmt=");
    printDecimal(out, @as(u32, @intFromEnum(mi.pixel_format)));
    puts(out, " ppsl=");
    printDecimal(out, mi.pixels_per_scan_line);
    puts(out, "\r\n");
}

/// virtio-gpu / 部分固件以 PixelBltOnly 启动；尝试切到带线性 32bpp 帧缓冲的模式。
/// 在每种像素格式内按 **模式表索引递增** 取首个匹配（与固件常见枚举顺序一致），格式优先级 RGB → BGR → bit_mask。
fn trySetLinearGopMode(out: anytype, gop: *uefi.protocol.GraphicsOutput) void {
    const cur = gop.mode.info.pixel_format;
    if (gopPixelFormatIsLinear(cur)) return;

    // 勿用 `for (&[_]PixelFormat{...})`：运行时常从 rodata 用 **`ldx.w`** 取枚举表项；改用 comptime 展开的 `inline for`。
    const prefer_order = [_]uefi.protocol.GraphicsOutput.PixelFormat{
        .red_green_blue_reserved_8_bit_per_color,
        .blue_green_red_reserved_8_bit_per_color,
        .bit_mask,
    };
    inline for (prefer_order) |want_pf| {
        const want_v = @intFromEnum(want_pf);
        var mid: u32 = 0;
        while (mid < gop.mode.max_mode) : (mid += 1) {
            const mi = gop.queryMode(mid) catch continue;
            if (@intFromEnum(mi.pixel_format) != want_v) continue;
            gop.setMode(mid) catch continue;
            const after = gop.queryMode(mid) catch return;
            puts(out, "    [*] GOP: selected linear 32bpp mode idx=");
            printDecimal(out, mid);
            puts(out, "\r\n");
            printGopModeDiag(out, mid, after);
            return;
        }
    }
    puts(out, "    [!] GOP: no linear 32bpp mode in firmware table\r\n");
}

/// 优先 `zbm_preferred_fb_width`×`height`（与 Makefile RESOLUTION / build -D 一致），其次不小于该分辨率的最小像素数模式，再选最大线性模式；同分辨率优先 RGB>BGR>bit_mask。
fn trySetPreferredGopMode(out: anytype, gop: *uefi.protocol.GraphicsOutput, want_w: u32, want_h: u32) void {
    trySetLinearGopMode(out, gop);

    var best_exact: ?u32 = null;
    var best_exact_rank: u8 = 255;
    var mid: u32 = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopModeIs32bppLinear(mi)) continue;
        if (mi.horizontal_resolution != want_w or mi.vertical_resolution != want_h) continue;
        const r = gopPixelFormatRank(mi.pixel_format);
        if (best_exact == null or r < best_exact_rank) {
            best_exact = mid;
            best_exact_rank = r;
        }
    }
    if (best_exact) |m| {
        gop.setMode(m) catch return;
        puts(out, "    [*] GOP: set preferred mode ");
        printDecimal(out, want_w);
        puts(out, "x");
        printDecimal(out, want_h);
        puts(out, " idx=");
        printDecimal(out, m);
        puts(out, "\r\n");
        if (gop.queryMode(m)) |mi| {
            printGopModeDiag(out, m, mi);
        } else |_| {}
        return;
    }

    puts(out, "    [*] GOP: no exact ");
    printDecimal(out, want_w);
    puts(out, "x");
    printDecimal(out, want_h);
    puts(out, "; trying smallest linear mode >= preferred\r\n");

    var best_cover: ?u32 = null;
    var best_cover_px: u64 = std.math.maxInt(u64);
    var best_cover_rank: u8 = 255;
    mid = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopModeIs32bppLinear(mi)) continue;
        const w = mi.horizontal_resolution;
        const h = mi.vertical_resolution;
        if (w < want_w or h < want_h) continue;
        const px = @as(u64, w) * @as(u64, h);
        const r = gopPixelFormatRank(mi.pixel_format);
        const better = blk: {
            if (best_cover == null) break :blk true;
            if (px < best_cover_px) break :blk true;
            if (px == best_cover_px and r < best_cover_rank) break :blk true;
            break :blk false;
        };
        if (better) {
            best_cover = mid;
            best_cover_px = px;
            best_cover_rank = r;
        }
    }
    if (best_cover) |m| {
        gop.setMode(m) catch return;
        puts(out, "    [*] GOP: set mode >= preferred ");
        printDecimal(out, want_w);
        puts(out, "x");
        printDecimal(out, want_h);
        puts(out, " idx=");
        printDecimal(out, m);
        puts(out, "\r\n");
        if (gop.queryMode(m)) |mi| {
            printGopModeDiag(out, m, mi);
        } else |_| {}
        return;
    }

    puts(out, "    [*] GOP: no mode >= preferred; falling back to largest linear 32bpp\r\n");

    var best_any: ?u32 = null;
    var max_px: u64 = 0;
    var best_any_rank: u8 = 255;
    mid = 0;
    while (mid < gop.mode.max_mode) : (mid += 1) {
        const mi = gop.queryMode(mid) catch continue;
        if (!gopModeIs32bppLinear(mi)) continue;
        const px = @as(u64, mi.horizontal_resolution) * @as(u64, mi.vertical_resolution);
        const r = gopPixelFormatRank(mi.pixel_format);
        const better = blk: {
            if (best_any == null) break :blk true;
            if (px > max_px) break :blk true;
            if (px == max_px and r < best_any_rank) break :blk true;
            break :blk false;
        };
        if (better) {
            best_any = mid;
            max_px = px;
            best_any_rank = r;
        }
    }
    if (best_any) |m| {
        gop.setMode(m) catch return;
        puts(out, "    [*] GOP: set largest linear 32bpp idx=");
        printDecimal(out, m);
        puts(out, "\r\n");
        if (gop.queryMode(m)) |mi| {
            printGopModeDiag(out, m, mi);
        } else |_| {}
    } else {
        puts(out, "    [!] GOP: no usable linear mode\r\n");
    }
}

/// 通过 `out_ok` / `out_info` 输出；避免按值返回大聚合体（易生成 `@memcpy`/`ldx.*`，QEMU LoongArch TCG 会 #INE）。
fn queryGopFramebufferInto(out: anytype, bs: *uefi.tables.BootServices, out_ok: *bool, out_info: *GopFbInfo) void {
    storeBoolAbs(out_ok, false);
    resetGopFbInfoAbs(out_info);

    const gop = zcall.locateGraphicsOutput(bs) orelse return;

    trySetPreferredGopMode(out, gop, preferred_fb_width, preferred_fb_height);

    const GMode = uefi.protocol.GraphicsOutput.Mode;
    const GInfo = GMode.Info;
    const mode_ptr = gop.mode;
    const info_va = la.loadU64Abs(@intFromPtr(mode_ptr) + @offsetOf(GMode, "info"));
    const pf = la.loadU32Abs(info_va + @offsetOf(GInfo, "pixel_format"));
    const w = la.loadU32Abs(info_va + @offsetOf(GInfo, "horizontal_resolution"));
    const h = la.loadU32Abs(info_va + @offsetOf(GInfo, "vertical_resolution"));
    const ppsl = la.loadU32Abs(info_va + @offsetOf(GInfo, "pixels_per_scan_line"));
    const fb_base = la.loadU64Abs(@intFromPtr(mode_ptr) + @offsetOf(GMode, "frame_buffer_base"));

    const PF = uefi.protocol.GraphicsOutput.PixelFormat;
    var bpp: u8 = 0;
    if (pf == @intFromEnum(PF.red_green_blue_reserved_8_bit_per_color)) bpp = 32;
    if (pf == @intFromEnum(PF.blue_green_red_reserved_8_bit_per_color)) bpp = 32;
    if (pf == @intFromEnum(PF.bit_mask)) bpp = 32;

    if (bpp == 0) {
        puts(out, "    [!] GOP pixel format unsupported for framebuffer\r\n");
        return;
    }

    var pixel_bgr: u8 = 1;
    if (pf == @intFromEnum(PF.blue_green_red_reserved_8_bit_per_color)) pixel_bgr = 1;
    if (pf == @intFromEnum(PF.bit_mask)) pixel_bgr = 1;
    if (pf == @intFromEnum(PF.red_green_blue_reserved_8_bit_per_color)) pixel_bgr = 0;

    const pitch = ppsl * (@as(u32, bpp) / 8);

    puts(out, "    [*] GOP Framebuffer: ");
    printDecimal(out, w);
    puts(out, "x");
    printDecimal(out, h);
    puts(out, "x");
    printDecimal(out, @as(u32, bpp));
    puts(out, "\r\n");

    if (w != preferred_fb_width or h != preferred_fb_height) {
        puts(out, "    [!] GOP: active mode != build preferred ");
        printDecimal(out, preferred_fb_width);
        puts(out, "x");
        printDecimal(out, preferred_fb_height);
        puts(out, " (set build.conf RESOLUTION; make sync-resolution; firmware/QEMU may not expose exact mode)\r\n");
    }

    commitGopFbInfoAbs(out_info, fb_base, w, h, pitch, bpp, pixel_bgr);
    storeBoolAbs(out_ok, true);
}

/// `BootServices.openProtocol` 使用 `std.meta.activeTag(attributes)`，在 LoongArch 上会生成 `ldx.d`；QEMU TCG 对该指令 #INE。
fn openProtocolByHandleNoLdx(
    bs: *uefi.tables.BootServices,
    comptime Protocol: type,
    handle: uefi.Handle,
) uefi.tables.BootServices.OpenProtocolError!?*Protocol {
    if (!@hasDecl(Protocol, "guid"))
        @compileError("protocol missing guid: " ++ @typeName(Protocol));
    var ptr: ?*Protocol = undefined;
    const st = bs._openProtocol(
        handle,
        &Protocol.guid,
        @as(*?*anyopaque, @ptrCast(&ptr)),
        null,
        null,
        uefi.tables.OpenProtocolAttributes.by_handle_protocol,
    );
    const sv = @intFromEnum(st);
    if (sv == @intFromEnum(uefi.Status.success)) return ptr;
    if (sv == @intFromEnum(uefi.Status.unsupported)) return null;
    if (sv == @intFromEnum(uefi.Status.access_denied)) return error.AccessDenied;
    if (sv == @intFromEnum(uefi.Status.already_started)) return error.AlreadyStarted;
    return uefi.unexpectedStatus(st);
}

fn loadAndBootLoongArchKernel(out: anytype, bs: *uefi.tables.BootServices, selected_idx: usize) void {
    puts(out, "    [*] Opening kernel from ESP...\r\n");

    const loaded_image = openProtocolByHandleNoLdx(bs, uefi.protocol.LoadedImage, uefi.handle) catch {
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

    const sfs = openProtocolByHandleNoLdx(bs, uefi.protocol.SimpleFileSystem, device_handle) catch {
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
    const ehdr_base: usize = @intFromPtr(file_data.ptr);

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

    const kernel_entry = la.loadU64Abs(ehdr_base + @offsetOf(Elf64_Ehdr, "e_entry"));

    puts(out, "    [*] ELF64 valid, ");
    printDecimal(out, ehdr.e_phnum);
    puts(out, " program headers\r\n");

    var segments_loaded: u32 = 0;
    var ph_i: usize = 0;
    while (ph_i < ehdr.e_phnum) : (ph_i += 1) {
        const ph_off: usize = @intCast(ehdr.e_phoff + @as(u64, @intCast(ph_i)) * ehdr.e_phentsize);
        if (ph_off + @sizeOf(Elf64_Phdr) > file_size) break;

        const ph_base = @intFromPtr(file_data.ptr) +% ph_off;
        const phdr: Elf64_Phdr = .{
            .p_type = la.loadU32Abs(ph_base),
            .p_flags = la.loadU32Abs(ph_base +% 4),
            .p_offset = la.loadU64Abs(ph_base +% 8),
            .p_vaddr = la.loadU64Abs(ph_base +% 16),
            .p_paddr = la.loadU64Abs(ph_base +% 24),
            .p_filesz = la.loadU64Abs(ph_base +% 32),
            .p_memsz = la.loadU64Abs(ph_base +% 40),
            .p_align = la.loadU64Abs(ph_base +% 48),
        };
        if (phdr.p_type != PT_LOAD) continue;
        if (phdr.p_memsz == 0) continue;

        var paddr: u64 = phdr.p_paddr;
        if (paddr == 0) paddr = phdr.p_vaddr;

        const num_pages: usize = @intCast((phdr.p_memsz + 4095) / 4096);
        const page_base: usize = @intCast(paddr & ~@as(u64, 0xFFF));
        const dest_ptr: [*]align(4096) uefi.Page = @ptrFromInt(page_base);

        _ = zcall.allocatePagesAtLoaderThin(bs, dest_ptr, num_pages);

        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(paddr)));
        const filesz: usize = @intCast(phdr.p_filesz);
        const memsz: usize = @intCast(phdr.p_memsz);
        const offset: usize = @intCast(phdr.p_offset);

        if (filesz > 0 and offset + filesz <= file_size) {
            const src = file_data.ptr + offset;
            la.copyBytes(dst, src, filesz);
        }
        if (memsz > filesz) {
            la.setBytes(dst + filesz, memsz - filesz, 0);
        }

        segments_loaded += 1;
    }

    puts(out, "    [*] Loaded ");
    printDecimal(out, segments_loaded);
    puts(out, " ELF segments\r\n");

    // SetMode 到 ≥1024×768 后把线性 GOP 写入 handoff，使内核与 QEMU 主窗口（固件 GOP 扫描）一致。
    var gop_ok: bool = false;
    var gop_fb: GopFbInfo = undefined;
    queryGopFramebufferInto(out, bs, &gop_ok, &gop_fb);
    if (debug_mode) {
        puts(out, "    [dbg] ZBM: after GOP query\r\n");
    }
    var gop_addr: u64 = 0;
    var gop_w: u32 = 0;
    var gop_h: u32 = 0;
    var gop_pitch: u32 = 0;
    var gop_bpp: u8 = 0;
    readGopFbHandoffScalars(&gop_fb, &gop_addr, &gop_w, &gop_h, &gop_pitch, &gop_bpp);
    if (debug_mode) {
        puts(out, "    [dbg] ZBM: after readGopFbHandoffScalars\r\n");
    }

    var hand: EfiHandoff = undefined;
    initHandoffBaseAbs(&hand, selected_idx);
    if (debug_mode) {
        puts(out, "    [dbg] ZBM: after initHandoffBaseAbs\r\n");
    }

    puts(out, "    [*] kernel entry at 0x");
    printHex64(out, kernel_entry);
    puts(out, "\r\n");
    // 仅当 GOP 同时达到构建首选宽高时写入 handoff：内核若收到更小 GOP 会弃用并走 ramfb（fw_cfg），以得到与 build.conf RESOLUTION 一致的桌面。
    if (gop_ok) {
        if (gop_w >= preferred_fb_width and gop_h >= preferred_fb_height) {
            applyGopToHandoffAbs(&hand, gop_addr, gop_pitch, gop_w, gop_h, gop_bpp);
        } else {
            puts(out, "    [*] Firmware FB ");
            printDecimal(out, gop_w);
            puts(out, " x ");
            printDecimal(out, gop_h);
            puts(out, " < pref ");
            printDecimal(out, preferred_fb_width);
            puts(out, " x ");
            printDecimal(out, preferred_fb_height);
            puts(out, "\r\n");
            puts(out, "    [*] No handoff FB; kernel uses ramfb + fw_cfg at pref (normal).\r\n");
            puts(out, "        Serial: ramfb:  Desktop: fb  first frame. Text pane may stay small.\r\n");
        }
    }
    const ho_ptr: [*]align(4096) uefi.Page = @ptrFromInt(HANDOFF_PHYS);
    if (!zcall.allocatePagesAtLoaderThin(bs, ho_ptr, 1)) {
        puts(out, "    [!!] Failed to allocate handoff page\r\n");
        return;
    }
    const hp: *EfiHandoff = @ptrCast(ho_ptr);
    const page_u8: [*]u8 = @ptrCast(ho_ptr);

    var mmap_buf: [32768]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const mmap = zcall.getMemoryMapThin(bs, @as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) orelse {
        puts(out, "    [!!] Failed to get memory map\r\n");
        return;
    };

    var mmap_count: u32 = 0;
    var mmap_esz: u32 = 0;
    fillHandoffMmapInto(page_u8, mmap, &mmap_count, &mmap_esz);
    applyMmapMetaToHandoffAbs(&hand, mmap_count, mmap_esz);
    if (mmap_count > 0) {
        bumpHandoffVersionAtLeast3Abs(&hand);
    }
    // 入口点写入 EfiHandoff.kernel_entry（随结构体一起 copy 到 handoff 页面）
    hand.kernel_entry = kernel_entry;
    if (builtin.cpu.arch == .loongarch64) {
        la.copyBytes(@ptrCast(ho_ptr), @ptrCast(@alignCast(&hand)), @sizeOf(EfiHandoff));
        // 独立写入固定槽（确保入口点在固定偏移，jumpToKernel 读取 HANDOFF_KERNEL_ENTRY_SLOT）
        la.storeU64Abs(HANDOFF_KERNEL_ENTRY_SLOT, kernel_entry);
    } else {
        hp.* = hand;
    }

    puts(out, "    [*] Exiting boot services...\r\n");

    if (!zcall.exitBootServicesThin(bs, uefi.handle, mmap.info.key)) {
        const mmap2 = zcall.getMemoryMapThin(bs, @as([]align(@alignOf(uefi.tables.MemoryDescriptor)) u8, &mmap_buf)) orelse return;
        if (!zcall.exitBootServicesThin(bs, uefi.handle, mmap2.info.key)) return;
    }

    jumpToKernel(HANDOFF_PHYS, kernel_entry);
}

fn displayMemoryMap(out: anytype, bs: *uefi.tables.BootServices) void {
    const info = zcall.getMemoryMapInfoThin(bs) orelse {
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
    zto.outputString(out, &buf);
}

fn printHex64(out: anytype, value: u64) void {
    const hex = "0123456789abcdef";
    var v = value;
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = la.loadU8(hex.ptr, @intCast(v & 0xF));
        v >>= 4;
    }
    var j: usize = 0;
    while (j < buf.len) : (j += 1) {
        const c = la.loadU8(@ptrCast(&buf), j);
        var u16buf: [1:0]u16 = .{@as(u16, c)};
        zto.outputString(out, &u16buf);
    }
}

fn puts(out: anytype, comptime s: []const u8) void {
    zto.outputString(out, unicode.utf8ToUtf16LeStringLiteral(s));
}

fn putsRuntime(out: anytype, s: []const u8) void {
    var si: usize = 0;
    while (si < s.len) : (si += 1) {
        const c = la.loadU8(s.ptr, si);
        var buf: [1:0]u16 = .{@as(u16, c)};
        zto.outputString(out, &buf);
    }
}

export fn efi_main(image_handle: uefi.Handle, st: *uefi.tables.SystemTable) callconv(uefi.cc) uefi.Status {
    enableLoongArchExtendedUnitsEarly();
    uefi.handle = image_handle;
    uefi.system_table = st;
    return runBootManager(st);
}
