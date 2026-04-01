//! MIPS64EL boot info
//! Provides defaults for QEMU Malta board (RAM at 0x00000000, 256MB)

pub const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0;

pub const BootMode = enum {
    normal,
    cmd,
    powershell,
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
    multiboot_handoff_start: usize = 0,
    multiboot_handoff_end_exclusive: usize = 0,
    acpi_rsdp_phys: usize = 0,

    pub fn getMmapEntry(_: BootInfo, i: usize) ?MmapEntry {
        if (i < static_mmap.len) return static_mmap[i];
        return null;
    }
};

const static_mmap = [_]MmapEntry{
    .{
        .base_addr = 0x00100000,
        .length = 256 * 1024 * 1024 - 0x100000,
        .type = @intFromEnum(MmapEntryType.available),
        .reserved = 0,
    },
};

pub fn parse(_: u32, _: usize) ?BootInfo {
    return BootInfo{};
}
