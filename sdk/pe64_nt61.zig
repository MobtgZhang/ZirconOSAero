// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: sdk/pe64_nt61.zig
// Purpose: PE32+（x86_64）头与数据目录布局骨架，供后续 Ldr / NtMapViewOfSection 里程碑对齐公开 PE/COFF 规范。
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format

const std = @import("std");

pub const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D; // "MZ"
pub const IMAGE_NT_SIGNATURE: u32 = 0x00004550; // "PE\0\0"
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
/// PE32+ optional header magic.
pub const IMAGE_NT_OPTIONAL_HDR64_MAGIC: u16 = 0x20B;

/// DOS stub；`e_lfanew` 指向 `IMAGE_NT_HEADERS64`。
pub const IMAGE_DOS_HEADER = extern struct {
    e_magic: u16,
    e_cblp: u16,
    e_cp: u16,
    e_crlc: u16,
    e_cparhdr: u16,
    e_minalloc: u16,
    e_maxalloc: u16,
    e_ss: u16,
    e_sp: u16,
    e_csum: u16,
    e_ip: u16,
    e_cs: u16,
    e_lfarlc: u16,
    e_ovno: u16,
    e_res: [4]u16,
    e_oemid: u16,
    e_oeminfo: u16,
    e_res2: [10]u16,
    e_lfanew: i32,
};

/// COFF 文件头（紧跟 PE 签名之后）。
pub const IMAGE_FILE_HEADER = extern struct {
    Machine: u16,
    NumberOfSections: u16,
    TimeDateStamp: u32,
    PointerToSymbolTable: u32,
    NumberOfSymbols: u32,
    SizeOfOptionalHeader: u16,
    Characteristics: u16,
};

pub const IMAGE_DATA_DIRECTORY = extern struct {
    VirtualAddress: u32,
    Size: u32,
};

/// PE32+ 可选头（x64）；与 Windows 加载器期望的 240 字节布局一致。
pub const IMAGE_OPTIONAL_HEADER64 = extern struct {
    Magic: u16,
    MajorLinkerVersion: u8,
    MinorLinkerVersion: u8,
    SizeOfCode: u32,
    SizeOfInitializedData: u32,
    SizeOfUninitializedData: u32,
    AddressOfEntryPoint: u32,
    BaseOfCode: u32,
    ImageBase: u64,
    SectionAlignment: u32,
    FileAlignment: u32,
    MajorOperatingSystemVersion: u16,
    MinorOperatingSystemVersion: u16,
    MajorImageVersion: u16,
    MinorImageVersion: u16,
    MajorSubsystemVersion: u16,
    MinorSubsystemVersion: u16,
    Win32VersionValue: u32,
    SizeOfImage: u32,
    SizeOfHeaders: u32,
    CheckSum: u32,
    Subsystem: u16,
    DllCharacteristics: u16,
    SizeOfStackReserve: u64,
    SizeOfStackCommit: u64,
    SizeOfHeapReserve: u64,
    SizeOfHeapCommit: u64,
    LoaderFlags: u32,
    NumberOfRvaAndSizes: u32,
    DataDirectory: [16]IMAGE_DATA_DIRECTORY,
};

pub const IMAGE_NT_HEADERS64 = extern struct {
    Signature: u32,
    FileHeader: IMAGE_FILE_HEADER,
    OptionalHeader: IMAGE_OPTIONAL_HEADER64,
};

// ── 内核侧「最小映射」契约（行为在 mm/vm + section 中实现；此处仅类型与注释锚点）────────
/// 里程碑：`NtCreateSection` + `NtMapViewOfSection` 子集应能完成：
/// 1) 自文件或页文件后备创建 `SECTION_OBJECT`；
/// 2) 将节区视图映射到用户 VA（`VAD` + 页表），并按 `IMAGE_SECTION_HEADER` 应用保护；
/// 3) 若 `IMAGE_DIRECTORY_ENTRY_BASERELOC` 非空，按块重定位使 `ImageBase` 与映射基址一致。
/// 公开行为描述见 MSDN / Learn 上述 PE 文档；本仓库不参考 Windows 源码实现。
pub const NtPeMapViewMilestone = struct {
    pub const DataDirectoryExport: usize = 0;
    pub const DataDirectoryImport: usize = 1;
    pub const DataDirectoryResource: usize = 2;
    pub const DataDirectoryBaseReloc: usize = 5;
};

/// 与 `src/libs/ntdll.zig` / `src/loader/pe.zig` 中 `SEC_IMAGE` 数值一致（Learn 公开属性名）。
pub const SEC_IMAGE: u32 = 0x01000000;

test "PE32+ header sizes (public layout)" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(IMAGE_DOS_HEADER));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(IMAGE_FILE_HEADER));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(IMAGE_DATA_DIRECTORY));
    try std.testing.expectEqual(@as(usize, 240), @sizeOf(IMAGE_OPTIONAL_HEADER64));
    try std.testing.expectEqual(@as(usize, 264), @sizeOf(IMAGE_NT_HEADERS64));
}

test "SEC_IMAGE constant parity for section milestones" {
    try std.testing.expectEqual(@as(u32, 0x01000000), SEC_IMAGE);
}
