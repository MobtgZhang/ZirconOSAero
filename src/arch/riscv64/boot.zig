//! RISC-V 64：QEMU `-kernel` 默认参数，或 UEFI ZBM 经 Multiboot2 信息块传入。

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

/// QEMU virt：RAM 自 0x8000_0000。
const default_mmap = [_]mb2.MmapEntry{
    .{
        .base_addr = 0x80000000 + 0x400000,
        .length = 128 * 1024 * 1024 - 0x400000,
        .type = @intFromEnum(mb2.MmapEntryType.available),
        .reserved = 0,
    },
};

fn qemuVirtDefault() BootInfo {
    return .{
        .mem_lower_kb = 0,
        .mem_upper_kb = 131072,
        .mmap_ptr = @ptrCast(&default_mmap),
        .mmap_entry_count = default_mmap.len,
        .mmap_entry_size = @sizeOf(mb2.MmapEntry),
    };
}

pub fn parse(magic: u32, phys_addr: usize) ?BootInfo {
    if (magic != mb2.MULTIBOOT2_BOOTLOADER_MAGIC) return qemuVirtDefault();
    if (phys_addr == 0) return qemuVirtDefault();
    return mb2.parseMultiboot2(phys_addr) orelse qemuVirtDefault();
}
