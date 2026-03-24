//! ZirconOS Boot Manager (ZBM) — Main Module
//!
//! This is the root module for the ZirconOS Boot Manager, inspired by
//! Windows Boot Manager (bootmgr / bootmgfw.efi).
//!
//! ZBM Architecture:
//!
//!   ┌─────────────────────────────────────────────────────┐
//!   │              ZirconOS Boot Manager (ZBM)            │
//!   ├─────────────┬──────────────┬────────────────────────┤
//!   │   BCD Store │   Menu UI    │   Kernel Loader        │
//!   │  (config)   │ (text mode)  │ (ELF/PE parser)        │
//!   ├─────────────┴──────────────┴────────────────────────┤
//!   │              Disk / Partition Layer                  │
//!   │            (GPT / MBR detection)                    │
//!   ├─────────────────────────────────────────────────────┤
//!   │        Platform Abstraction Layer                   │
//!   │   ┌──────────────┐   ┌──────────────────┐          │
//!   │   │  BIOS Path   │   │   UEFI Path      │          │
//!   │   │  (INT 13h)   │   │ (UEFI protocols) │          │
//!   │   └──────────────┘   └──────────────────┘          │
//!   └─────────────────────────────────────────────────────┘
//!
//! Boot Paths:
//!
//!   BIOS/MBR Boot Path:
//!     BIOS → MBR (stage1) → VBR → stage2 → ZBM → kernel.elf
//!     - MBR scans partition table, loads VBR from active partition
//!     - VBR loads stage2 from consecutive sectors
//!     - Stage2 enables A20, enters protected mode, shows menu
//!     - Loads kernel.elf to 1MB, builds Multiboot2 info, jumps
//!
//!   BIOS/GPT Boot Path (Hybrid):
//!     BIOS → Protective MBR → stage2 (from known LBA) → ZBM → kernel.elf
//!     - MBR detects GPT protective partition (type 0xEE)
//!     - Loads stage2 from LBA 2 (after GPT header)
//!     - Stage2 parses GPT to find ZirconOS boot partition
//!     - Proceeds same as MBR path from there
//!
//!   UEFI/GPT Boot Path:
//!     UEFI → ESP → zbmfw.efi (ZBM UEFI app) → kernel.elf
//!     - UEFI firmware loads zbmfw.efi from ESP
//!     - ZBM uses UEFI protocols for disk/file access
//!     - Displays boot menu via UEFI console
//!     - Loads kernel.elf via UEFI Simple File System
//!     - Exits boot services, jumps to kernel

pub const bcd = @import("common/bcd.zig");
pub const disk = @import("common/disk.zig");
pub const menu = @import("common/menu.zig");
pub const loader = @import("loader.zig");

// ── Boot Manager Version ──

pub const ZBM_VERSION_MAJOR: u16 = 1;
pub const ZBM_VERSION_MINOR: u16 = 0;
pub const ZBM_VERSION_BUILD: u16 = 1;
pub const ZBM_VERSION_STRING = "1.0.1";

// ── Boot Path Identification ──

pub const BootPath = enum(u8) {
    bios_mbr = 0,
    bios_gpt = 1,
    uefi_gpt = 2,
};

// ── Boot Manager Context ──

pub const BootContext = struct {
    boot_path: BootPath,
    boot_drive: u8,
    partition_scheme: disk.PartitionScheme,
    disk_info: disk.DiskInfo,
    bcd_store: bcd.BcdStore,
    menu_state: menu.MenuState,
    selected_entry: usize,
    selected_mode: bcd.BootMode,
    kernel_loaded: bool,
    kernel_entry: u64,
    kernel_base: u64,
    multiboot_info_addr: u64,

    pub fn init(boot_path: BootPath) BootContext {
        var store = bcd.BcdStore.init();
        return .{
            .boot_path = boot_path,
            .boot_drive = 0x80,
            .partition_scheme = .unknown,
            .disk_info = disk.DiskInfo.init(),
            .bcd_store = store,
            .menu_state = menu.MenuState.init(&store),
            .selected_entry = 0,
            .selected_mode = .normal,
            .kernel_loaded = false,
            .kernel_entry = 0,
            .kernel_base = 0x2000000,
            .multiboot_info_addr = 0x9000,
        };
    }

    pub fn selectEntry(self: *BootContext, index: usize) void {
        self.selected_entry = index;
        self.selected_mode = self.bcd_store.getBootMode(index);
    }

    pub fn getBootPathName(self: *const BootContext) []const u8 {
        return switch (self.boot_path) {
            .bios_mbr => "BIOS/MBR",
            .bios_gpt => "BIOS/GPT (Hybrid)",
            .uefi_gpt => "UEFI/GPT",
        };
    }

    pub fn getPartitionSchemeName(self: *const BootContext) []const u8 {
        return switch (self.partition_scheme) {
            .unknown => "Unknown",
            .mbr => "MBR (Master Boot Record)",
            .gpt => "GPT (GUID Partition Table)",
        };
    }
};

// ── Boot Manager Entry Point (called from platform-specific code) ──

/// Initialize the boot manager and run the boot menu.
/// Returns the selected BCD entry index.
pub fn runBootManager(ctx: *BootContext) usize {
    // Initialize BCD store with default entries
    ctx.bcd_store = bcd.BcdStore.init();
    ctx.menu_state = menu.MenuState.init(&ctx.bcd_store);

    // The actual menu interaction is platform-specific:
    // - BIOS: Uses VGA text mode direct memory writes + INT 16h keyboard
    // - UEFI: Uses UEFI Simple Text Output/Input protocols
    // This function returns after the platform code has collected the selection.

    return ctx.menu_state.selected;
}

/// After menu selection, prepare the kernel boot.
pub fn prepareKernelBoot(ctx: *BootContext, selection: usize) void {
    ctx.selectEntry(selection);
}

// ── Multiboot2 Info Builder ──

pub const MULTIBOOT2_MAGIC: u32 = 0x36D76289;

/// Build a Multiboot2-compatible info structure at the given address.
/// This allows the kernel to use the same boot info parsing regardless
/// of whether it was booted via GRUB or ZBM.
pub fn buildMultiboot2Info(
    base_addr: u64,
    mem_lower_kb: u32,
    mem_upper_kb: u32,
    cmdline: []const u8,
    bootloader_name: []const u8,
) u32 {
    var ptr = @as([*]u8, @ptrFromInt(@as(usize, @intCast(base_addr))));
    var offset: u32 = 0;

    // Header: total_size (placeholder) + reserved
    writeU32(ptr, offset, 0); // total_size — patched at end
    offset += 4;
    writeU32(ptr, offset, 0); // reserved
    offset += 4;

    // Tag: boot loader name (type=2)
    offset = alignUp(offset, 8);
    writeU32(ptr, offset, 2); // type
    offset += 4;
    const name_tag_size: u32 = @intCast(8 + bootloader_name.len + 1);
    writeU32(ptr, offset, name_tag_size);
    offset += 4;
    for (bootloader_name) |c| {
        ptr[offset] = c;
        offset += 1;
    }
    ptr[offset] = 0;
    offset += 1;

    // Tag: command line (type=1)
    offset = alignUp(offset, 8);
    writeU32(ptr, offset, 1); // type
    offset += 4;
    const cmd_tag_size: u32 = @intCast(8 + cmdline.len + 1);
    writeU32(ptr, offset, cmd_tag_size);
    offset += 4;
    for (cmdline) |c| {
        ptr[offset] = c;
        offset += 1;
    }
    ptr[offset] = 0;
    offset += 1;

    // Tag: basic memory info (type=4)
    offset = alignUp(offset, 8);
    writeU32(ptr, offset, 4); // type
    offset += 4;
    writeU32(ptr, offset, 16); // size
    offset += 4;
    writeU32(ptr, offset, mem_lower_kb);
    offset += 4;
    writeU32(ptr, offset, mem_upper_kb);
    offset += 4;

    // Tag: end (type=0, size=8)
    offset = alignUp(offset, 8);
    writeU32(ptr, offset, 0);
    offset += 4;
    writeU32(ptr, offset, 8);
    offset += 4;

    // Patch total size
    writeU32(ptr, 0, offset);

    return offset;
}

fn writeU32(ptr: [*]u8, offset: u32, value: u32) void {
    const o: usize = offset;
    ptr[o + 0] = @intCast(value & 0xFF);
    ptr[o + 1] = @intCast((value >> 8) & 0xFF);
    ptr[o + 2] = @intCast((value >> 16) & 0xFF);
    ptr[o + 3] = @intCast((value >> 24) & 0xFF);
}

fn alignUp(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}
