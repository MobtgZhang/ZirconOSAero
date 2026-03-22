//! Multiboot2 header and boot info parsing for x86_64
//! Reference: https://www.gnu.org/software/grub/manual/multiboot2/multiboot2.html

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

extern const multiboot2_header: [48]u8;

pub fn parse(_: u32, phys_addr: usize) ?BootInfo {
    return mb2.parseMultiboot2(phys_addr);
}
