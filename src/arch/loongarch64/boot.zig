//! LoongArch64 boot info
//! Provides defaults for QEMU virt machine（首段 RAM 0..256MB；与 link/loongarch64.ld 物理入口一致）

pub const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0;

pub const BootMode = enum {
    normal,
    cmd,
    desktop,
};

pub const DesktopTheme = enum {
    none,
    aero,
};

pub const MmapEntryType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    nvs = 4,
    bad = 5,
    _,
};

pub const MmapEntry = struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
};

pub const FramebufferInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
};

pub const BootInfo = struct {
    mem_lower_kb: u32 = 0,
    mem_upper_kb: u32 = 262144,
    mmap_ptr: [*]const u8 = @as([*]const u8, @ptrFromInt(0x1000)),
    mmap_entry_count: usize = 1,
    mmap_entry_size: u32 = @sizeOf(MmapEntry),
    boot_mode: BootMode = .normal,
    desktop_theme: DesktopTheme = .none,
    fb_info: ?FramebufferInfo = null,
    /// 与 `multiboot2_parse.BootInfo` 对齐；LoongArch 无 Multiboot2 handoff，恒为 0。
    multiboot_handoff_start: usize = 0,
    multiboot_handoff_end_exclusive: usize = 0,
    acpi_rsdp_phys: usize = 0,
    /// UEFI handoff v3：`mmap_ptr` 指向 `EfiHandoff` 之后的打包表
    mmap_from_handoff: bool = false,

    pub fn getMmapEntry(self: BootInfo, i: usize) ?MmapEntry {
        if (self.mmap_from_handoff and self.mmap_entry_count > 0) {
            if (i >= self.mmap_entry_count) return null;
            if (self.mmap_entry_size < @sizeOf(MmapEntry)) return null;
            const p: *align(1) const MmapEntry = @ptrCast(self.mmap_ptr + i * self.mmap_entry_size);
            return p.*;
        }
        if (i < static_mmap.len) return static_mmap[i];
        return null;
    }
};

const static_mmap = [_]MmapEntry{
    .{
        .base_addr = 0x00200000,
        .length = 256 * 1024 * 1024 - 0x200000,
        .type = @intFromEnum(MmapEntryType.available),
        .reserved = 0,
    },
};

/// 与 boot/zbm/uefi/main_loongarch64.zig 中 ZIRCON_LOONGARCH_EFI_MAGIC 一致（小端四字符 `zirc`）
pub const ZIRCON_LOONGARCH_EFI_MAGIC: u32 = 0x6372697A;

/// 与 boot/stub/efi_stub.c / `main_loongarch64.zig` 一致；v3 在 handoff 页 `mmap_off_from_handoff` 起存放 `MmapEntry` 数组
pub const EfiHandoff = extern struct {
    magic: u32,
    version: u32,
    boot_mode: u32,
    desktop: u32,
    /// v2: GOP framebuffer
    fb_addr: u64 = 0,
    fb_pitch: u32 = 0,
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    fb_bpp: u8 = 0,
    _pad: [3]u8 = [_]u8{0} ** 3,
    /// v3: UEFI 内存映射条数（与 `mmap_off_from_handoff` 联用）
    mmap_count: u32 = 0,
    mmap_entry_size: u32 = 0,
    /// 相对 `info_addr`（handoff 结构体首址）的字节偏移
    mmap_off_from_handoff: u32 = 0,
    _mmap_pad: u32 = 0,
};

fn desktopFromU32(id: u32) DesktopTheme {
    return if (id == 0) .none else .aero;
}

fn bootModeFromU32(b: u32) BootMode {
    return switch (b) {
        0 => .normal,
        1 => .cmd,
        2 => .desktop,
        else => .normal,
    };
}

pub fn parse(magic: u32, info_addr: usize) ?BootInfo {
    if (magic != ZIRCON_LOONGARCH_EFI_MAGIC or info_addr == 0) {
        return BootInfo{};
    }
    const h: *const EfiHandoff = @ptrFromInt(info_addr);
    if (h.magic != ZIRCON_LOONGARCH_EFI_MAGIC) return BootInfo{};
    var bi = BootInfo{};
    bi.desktop_theme = desktopFromU32(h.desktop);
    bi.boot_mode = bootModeFromU32(h.boot_mode);
    if (h.fb_addr != 0 and h.fb_width > 0 and h.fb_height > 0 and h.fb_bpp > 0) {
        bi.fb_info = .{
            .addr = h.fb_addr,
            .pitch = if (h.fb_pitch > 0) h.fb_pitch else h.fb_width * @as(u32, h.fb_bpp) / 8,
            .width = h.fb_width,
            .height = h.fb_height,
            .bpp = h.fb_bpp,
            .fb_type = 2,
        };
    }
    if (h.version >= 3 and h.mmap_count > 0 and h.mmap_entry_size == @sizeOf(MmapEntry) and h.mmap_off_from_handoff >= @sizeOf(EfiHandoff)) {
        bi.mmap_ptr = @ptrFromInt(info_addr + @as(usize, h.mmap_off_from_handoff));
        bi.mmap_entry_count = h.mmap_count;
        bi.mmap_entry_size = h.mmap_entry_size;
        bi.mmap_from_handoff = true;
    }
    return bi;
}
