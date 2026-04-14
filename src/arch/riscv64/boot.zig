//! RISC-V 64 boot handoff: UEFI ZBM via Multiboot2, or QEMU -kernel via DTB.
//!
//! QEMU `-kernel` 启动时：a0=hartid(0), a1=DTB指针(0xD00DFEED)
//! UEFI ZBM 启动时：a0=0x36d76289, a1=UEFI向量表物理地址
//!
//! 当 a0!=MULTIBOOT2_MAGIC 时（QEMU -kernel 路径），尝试从 a1 读取 DTB。

const mb2 = @import("../../boot/multiboot2_parse.zig");
const fdt = @import("../../hal/riscv64/fdt.zig");

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

/// QEMU virt 默认内存信息（无 DTB / DTB 解析失败时回退）。
/// 128 MiB 与 EDK2 QEMU virt 默认 RAM 大小一致。
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
    // UEFI ZBM 路径：magic == MULTIBOOT2_MAGIC
    if (magic == mb2.MULTIBOOT2_BOOTLOADER_MAGIC) {
        const info_phys = multiboot2PhysFromUefiVector(phys_addr);
        if (info_phys != 0) {
            return mb2.parseMultiboot2(info_phys);
        }
        return qemuVirtDefault();
    }

    // QEMU -kernel 路径：magic != MULTIBOOT2_MAGIC，phys_addr 是 DTB 指针
    // QEMU virt 的 DTB 包含完整内存映射和 hart 信息
    const fdt_phys: usize = @intCast(phys_addr);
    if (fdt_phys != 0) {
        const hart_count = fdt.parse(fdt_phys);
        if (hart_count > 0) {
            // DTB 解析成功：从 fdt 模块获取内存信息构造 BootInfo
            const mem_bytes = fdt.dtb_mem_size;
            const mem_upper_kb: u32 = @truncate(@min(mem_bytes / 1024, 0xFFFFFFFF));
            return .{
                .mem_lower_kb = 0,
                .mem_upper_kb = mem_upper_kb,
                .mmap_ptr = @ptrCast(&default_mmap), // DTB mmap 由 fdt 模块内部管理，entry_count=0时不会被访问
                .mmap_entry_count = 0,
                .mmap_entry_size = @sizeOf(mb2.MmapEntry),
            };
        }
    }

    return qemuVirtDefault();
}
