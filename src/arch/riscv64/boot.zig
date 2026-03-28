//! RISC-V 64：QEMU `-kernel` 默认参数，或 UEFI ZBM 经 Multiboot2 信息块传入。

const mb2 = @import("../../boot/multiboot2_parse.zig");

const UefiVectorLayout = extern struct {
    magic: u32,
    version: u32,
    kernel_entry: u64,
    stack_addr: u64,
    mb2_phys: u64,
};
extern const _uefi_vector: UefiVectorLayout align(8);

fn multiboot2PhysFromUefiVector(reg_a1: usize) usize {
    const base = @intFromPtr(&_uefi_vector);
    if (@as(*const volatile u32, @ptrFromInt(base)).* != 0x55454649) return reg_a1;
    if (@as(*const volatile u32, @ptrFromInt(base + 4)).* < 1) return reg_a1;
    const p = @as(*const volatile u64, @ptrFromInt(base + 24)).*;
    if (p == 0) return reg_a1;
    return @as(usize, @truncate(p));
}

pub fn uefiVectorMb2PhysForDiag() u64 {
    const base = @intFromPtr(&_uefi_vector);
    if (@as(*const volatile u32, @ptrFromInt(base)).* != 0x55454649) return 0;
    if (@as(*const volatile u32, @ptrFromInt(base + 4)).* < 1) return 0;
    return @as(*const volatile u64, @ptrFromInt(base + 24)).*;
}

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
    const info_phys = multiboot2PhysFromUefiVector(phys_addr);
    if (info_phys == 0) return qemuVirtDefault();
    return mb2.parseMultiboot2(info_phys) orelse qemuVirtDefault();
}
