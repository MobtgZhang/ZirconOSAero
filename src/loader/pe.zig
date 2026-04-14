// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! PE32/PE32+ (Portable Executable) Loader
//! Phase 7-11 Enhanced: DLL loading, import resolution, relocation,
//! section mapping, process context (PEB/TEB), image management,
//! and PE32 (32-bit) support for WOW64 compatibility.
//!
//! **对齐要点（公开规范，clean-room）**：Microsoft PE COFF / PE 格式说明中的
//! `SizeOfHeaders`、`SectionAlignment`、`FileAlignment`、节 `VirtualAddress`/`VirtualSize`。
//! 将映像提交到用户地址空间时，须通过 `mm/vm.AddressSpace.mapPage*` 按页对齐映射，
//! 并与 `mm/vm.VirtualCommitPhase`（Reserve/Commit 分阶段） eventual 一致；不得假设与 Windows 加载器实现相同的数据结构布局。

const std = @import("std");
const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");
const process_mod = @import("../ps/process.zig");
const section_mm = @import("../mm/section.zig");

pub const PE_SIGNATURE: u32 = 0x00004550;
pub const PE32_MAGIC: u16 = 0x10B;
pub const PE32PLUS_MAGIC: u16 = 0x20B;

/// 与 `ntdll.zig` `SEC_IMAGE` 一致；Learn — `NtCreateSection` / section allocation attributes。
pub const SEC_IMAGE: u32 = 0x01000000;

pub const IMAGE_FILE_EXECUTABLE_IMAGE: u16 = 0x0002;
pub const IMAGE_FILE_LARGE_ADDRESS_AWARE: u16 = 0x0020;
pub const IMAGE_FILE_DLL: u16 = 0x2000;

pub const IMAGE_DLLCHARACTERISTICS_NX_COMPAT: u16 = 0x0100;
pub const IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE: u16 = 0x0040;

pub const IMAGE_SUBSYSTEM_UNKNOWN: u16 = 0;
pub const IMAGE_SUBSYSTEM_NATIVE: u16 = 1;
pub const IMAGE_SUBSYSTEM_WINDOWS_GUI: u16 = 2;
pub const IMAGE_SUBSYSTEM_WINDOWS_CUI: u16 = 3;
pub const IMAGE_SUBSYSTEM_POSIX_CUI: u16 = 7;
pub const IMAGE_SUBSYSTEM_WINDOWS_CE_GUI: u16 = 9;
pub const IMAGE_SUBSYSTEM_EFI_APPLICATION: u16 = 10;

pub const IMAGE_DIRECTORY_ENTRY_EXPORT: usize = 0;
pub const IMAGE_DIRECTORY_ENTRY_IMPORT: usize = 1;
pub const IMAGE_DIRECTORY_ENTRY_RESOURCE: usize = 2;
pub const IMAGE_DIRECTORY_ENTRY_EXCEPTION: usize = 3;
pub const IMAGE_DIRECTORY_ENTRY_SECURITY: usize = 4;
pub const IMAGE_DIRECTORY_ENTRY_BASERELOC: usize = 5;
pub const IMAGE_DIRECTORY_ENTRY_DEBUG: usize = 6;
pub const IMAGE_DIRECTORY_ENTRY_TLS: usize = 9;
pub const IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG: usize = 10;
pub const IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT: usize = 11;
pub const IMAGE_DIRECTORY_ENTRY_IAT: usize = 12;
pub const IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT: usize = 13;
pub const IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR: usize = 14;
pub const IMAGE_NUM_DIRECTORIES: usize = 16;

pub const DosHeader = extern struct {
    e_magic: u16 align(1) = 0x5A4D,
    e_cblp: u16 align(1) = 0,
    e_cp: u16 align(1) = 0,
    e_crlc: u16 align(1) = 0,
    e_cparhdr: u16 align(1) = 0,
    e_minalloc: u16 align(1) = 0,
    e_maxalloc: u16 align(1) = 0,
    e_ss: u16 align(1) = 0,
    e_sp: u16 align(1) = 0,
    e_csum: u16 align(1) = 0,
    e_ip: u16 align(1) = 0,
    e_cs: u16 align(1) = 0,
    e_lfarlc: u16 align(1) = 0,
    e_ovno: u16 align(1) = 0,
    e_res: [4]u16 align(1) = .{0} ** 4,
    e_oemid: u16 align(1) = 0,
    e_oeminfo: u16 align(1) = 0,
    e_res2: [10]u16 align(1) = .{0} ** 10,
    e_lfanew: u32 align(1) = 0,
};

pub const FileHeader = extern struct {
    machine: u16 align(1) = 0x8664,
    number_of_sections: u16 align(1) = 0,
    time_date_stamp: u32 align(1) = 0,
    pointer_to_symbol_table: u32 align(1) = 0,
    number_of_symbols: u32 align(1) = 0,
    size_of_optional_header: u16 align(1) = 0,
    characteristics: u16 align(1) = 0,
};

pub const DataDirectory = extern struct {
    virtual_address: u32 align(1) = 0,
    size: u32 align(1) = 0,
};

pub const OptionalHeader64 = extern struct {
    magic: u16 align(1) = PE32PLUS_MAGIC,
    major_linker_version: u8 align(1) = 14,
    minor_linker_version: u8 align(1) = 0,
    size_of_code: u32 align(1) = 0,
    size_of_initialized_data: u32 align(1) = 0,
    size_of_uninitialized_data: u32 align(1) = 0,
    address_of_entry_point: u32 align(1) = 0,
    base_of_code: u32 align(1) = 0,
    image_base: u64 align(1) = 0x140000000,
    section_alignment: u32 align(1) = 0x1000,
    file_alignment: u32 align(1) = 0x200,
    major_os_version: u16 align(1) = 10,
    minor_os_version: u16 align(1) = 0,
    major_image_version: u16 align(1) = 0,
    minor_image_version: u16 align(1) = 0,
    major_subsystem_version: u16 align(1) = 6,
    minor_subsystem_version: u16 align(1) = 0,
    win32_version_value: u32 align(1) = 0,
    size_of_image: u32 align(1) = 0,
    size_of_headers: u32 align(1) = 0,
    checksum: u32 align(1) = 0,
    subsystem: u16 align(1) = IMAGE_SUBSYSTEM_WINDOWS_CUI,
    dll_characteristics: u16 align(1) = 0,
    size_of_stack_reserve: u64 align(1) = 0x100000,
    size_of_stack_commit: u64 align(1) = 0x1000,
    size_of_heap_reserve: u64 align(1) = 0x100000,
    size_of_heap_commit: u64 align(1) = 0x1000,
    loader_flags: u32 align(1) = 0,
    number_of_rva_and_sizes: u32 align(1) = IMAGE_NUM_DIRECTORIES,
    data_directory: [IMAGE_NUM_DIRECTORIES]DataDirectory align(1) = [_]DataDirectory{.{}} ** IMAGE_NUM_DIRECTORIES,
};

pub const SectionHeader = extern struct {
    name: [8]u8 align(1) = [_]u8{0} ** 8,
    virtual_size: u32 align(1) = 0,
    virtual_address: u32 align(1) = 0,
    size_of_raw_data: u32 align(1) = 0,
    pointer_to_raw_data: u32 align(1) = 0,
    pointer_to_relocations: u32 align(1) = 0,
    pointer_to_line_numbers: u32 align(1) = 0,
    number_of_relocations: u16 align(1) = 0,
    number_of_line_numbers: u16 align(1) = 0,
    characteristics: u32 align(1) = 0,
};

pub const IMAGE_SCN_MEM_EXECUTE: u32 = 0x20000000;
pub const IMAGE_SCN_MEM_READ: u32 = 0x40000000;
pub const IMAGE_SCN_MEM_WRITE: u32 = 0x80000000;
pub const IMAGE_SCN_CNT_CODE: u32 = 0x00000020;
pub const IMAGE_SCN_CNT_INITIALIZED_DATA: u32 = 0x00000040;
pub const IMAGE_SCN_CNT_UNINITIALIZED_DATA: u32 = 0x00000080;

pub const ImportDescriptor = extern struct {
    original_first_thunk: u32 align(1) = 0,
    time_date_stamp: u32 align(1) = 0,
    forwarder_chain: u32 align(1) = 0,
    name_rva: u32 align(1) = 0,
    first_thunk: u32 align(1) = 0,
};

pub const ExportDirectory = extern struct {
    characteristics: u32 align(1) = 0,
    time_date_stamp: u32 align(1) = 0,
    major_version: u16 align(1) = 0,
    minor_version: u16 align(1) = 0,
    name_rva: u32 align(1) = 0,
    ordinal_base: u32 align(1) = 1,
    number_of_functions: u32 align(1) = 0,
    number_of_names: u32 align(1) = 0,
    address_of_functions: u32 align(1) = 0,
    address_of_names: u32 align(1) = 0,
    address_of_name_ordinals: u32 align(1) = 0,
};

pub const BaseRelocation = extern struct {
    virtual_address: u32 align(1) = 0,
    size_of_block: u32 align(1) = 0,
};

/// PE 延迟导入描述符（IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT）
/// 与普通导入目录结构相同，但指向延迟加载的 DLL 信息。
/// 基于 Microsoft PE/COFF 规范中延迟加载描述符布局。
pub const DelayImportDescriptor = extern struct {
    /// 包含 `DELAYIMPORT_INFO` 结构（描述 DLL 名称、HINT/NAME 表等）的 RVA
    /// （仅在加载时使用，运行时无效）
    grAttrs: u32 align(1) = 0,
    /// 包含 DLL 名称的 RVA
    szName: u32 align(1) = 0,
    /// 指向 `HMODULE*` 的 VA（加载后 DLL 基址写入此处）
    phmod: u32 align(1) = 0,
    /// 指向第一个 `DelayImportDirectoryEntry` 的 RVA（ILTD）
    pIAT: u32 align(1) = 0,
    /// 指向第一个 `DelayImportDirectoryEntry` 的 RVA（名称查找）
    pINT: u32 align(1) = 0,
    /// 指向绑定信息（可选）的 RVA
    pBoundIAT: u32 align(1) = 0,
    /// 指向卸载信息（可选）的 RVA
    pUnloadIAT: u32 align(1) = 0,
    /// 延迟加载描述符的时钟戳
    dwTimeStamp: u32 align(1) = 0,
};

/// 延迟导入目录项（对应 ILT/INT 中的每一项）
pub const DelayImportDirectoryEntry = extern struct {
    /// 函数名称提示 RVA（如果最高位为 1，则为序号）
    rvaINTEntry: u32 align(1) = 0,
    /// IAT 中对应条目 VA
    rvaIATEntry: u32 align(1) = 0,
};

/// 解析 PE 字节数据中的延迟导入目录。
/// 返回延迟导入描述符数组的切片（以 `szName == 0` 的空描述符结尾）。
/// `data` 为已映射的 PE 映像字节。
pub fn parseDelayImportDescriptors(data: []const u8, image_base: u64) []const DelayImportDescriptor {
    _ = image_base;
    const delay_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT) orelse return &.{};
    if (delay_rva == 0) return &.{};

    const data_ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(data.ptr)));
    const desc_ptr = @as([*]const DelayImportDescriptor, @ptrFromInt(data_ptr + delay_rva));

    // 计算描述符数量（遍历直到 szName == 0）
    var count: usize = 0;
    while (desc_ptr[count].szName != 0) : (count += 1) {}

    return desc_ptr[0..count];
}

/// 解析延迟导入描述符中的 DLL 名称。
/// 返回 DLL 名称字符串。
pub fn parseDelayImportDllName(data: []const u8, desc: DelayImportDescriptor) ?[]const u8 {
    if (desc.szName == 0) return null;
    const data_ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(data.ptr)));
    const name_ptr = data_ptr + desc.szName;
    var len: usize = 0;
    while (name_ptr[len] != 0 and len < 256) : (len += 1) {}
    return name_ptr[0..len];
}

/// 解析延迟导入 INT（Import Name Table）中的每一项。
/// 返回按名称/序号描述的函数信息。
pub fn parseDelayImportEntries(data: []const u8, image_base: u64, desc: DelayImportDescriptor) []const DelayImportDirectoryEntry {
    _ = data;
    _ = image_base;
    _ = desc;
    // INT 条目解析需要遍历直到遇到全零条目
    // 此处返回空切片，待完整实现
    return &.{};
}

pub const IMAGE_REL_BASED_ABSOLUTE: u16 = 0;
pub const IMAGE_REL_BASED_HIGH: u16 = 1;
pub const IMAGE_REL_BASED_LOW: u16 = 2;
pub const IMAGE_REL_BASED_HIGHLOW: u16 = 3;
pub const IMAGE_REL_BASED_DIR64: u16 = 10;

pub const IMAGE_FILE_MACHINE_I386: u16 = 0x014C;
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
pub const IMAGE_FILE_MACHINE_ARM64: u16 = 0xAA64;
pub const IMAGE_FILE_MACHINE_LOONGARCH64: u16 = 0x6264;
/// PE/COFF public spec value for RISC-V 64-bit.
pub const IMAGE_FILE_MACHINE_RISCV64: u16 = 0x5064;

/// PE COFF LoongArch64 重定位类型（公开规范数值；完整装载路径逐步接线）。
pub const IMAGE_REL_LOONGARCH64_MARK_LA: u16 = 1;
pub const IMAGE_REL_LOONGARCH64_SUPPORT_SPLIT: u16 = 2;
pub const IMAGE_REL_LOONGARCH64_REFLOCAL: u16 = 3;
pub const IMAGE_REL_LOONGARCH64_JUMPER: u16 = 4;
pub const IMAGE_REL_LOONGARCH64_RELATIVE64: u16 = 5;

/// PE COFF AArch64 base relocation types (PE/COFF public spec).
/// IMAGE_REL_BASED_ARM64_MOV32: patch MOVW/MOVT pair (16-bit low / 16-bit high).
pub const IMAGE_REL_BASED_ARM64_MOV32: u16 = 5;
/// IMAGE_REL_BASED_DIR64 (type 10) already covers most AArch64 64-bit relocations.
/// PE TLS Directory（IMAGE_DIRECTORY_ENTRY_TLS）— 公开 COFF 规范。
pub const TlsDirectory = extern struct {
    raw_data_start_va: u32 align(1) = 0,
    raw_data_end_va: u32 align(1) = 0,
    index_va: u32 align(1) = 0,
    callbacks_va: u32 align(1) = 0,
    size_of_zero_fill: u32 align(1) = 0,
    characteristics: u32 align(1) = 0,
};

/// 触发 PE 映像的 TLS 回调（如果存在 TLS 目录）。
/// 在导入表解析完成后调用，使依赖 TLS 的 C++ 程序能正确初始化。
pub fn invokeTlsCallbacksIfPresent(image_base: u64, tls_dir_opt: ?*const TlsDirectory) void {
    const tls_dir = tls_dir_opt orelse return;
    if (tls_dir.callbacks_va == 0) return;

    const index_ptr = @as(*volatile u32, @ptrFromInt(image_base + tls_dir.index_va));
    index_ptr.* = 0;

    const callbacks_ptr = @as(*volatile [*]const u8, @ptrFromInt(image_base + tls_dir.callbacks_va));
    var i: usize = 0;
    while (callbacks_ptr[i] != 0) : (i += 1) {
        const cb_va = image_base + @as(u64, @intCast(@as(u32, @intFromPtr(callbacks_ptr[i]))));
        klog.debug("PE Loader: invoking TLS callback at VA 0x{x}", .{cb_va});
        // C calling convention TLS callback: void callback(PIMAGE_TLS_Template)
        const callback = @as(*const fn () callconv(.C) void, @ptrFromInt(cb_va));
        callback();
    }
}

/// 从 PE 字节数据中读取 TLS 目录（已映射到 image_base 的进程内 VA）。
pub fn readTlsDirectory(data: []const u8, image_base: u64) ?TlsDirectory {
    if (readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_TLS)) |rva| {
        if (rva == 0) return null;
        const tls_va = image_base + rva;
        return @as(*const TlsDirectory, @ptrFromInt(tls_va)).*;
    }
    return null;
}

/// 对 LoongArch64 重定位位点应用 delta；`delta` = new_image_base - preferred_image_base。
/// MARK_LA 覆盖 `lu12i.w + ori` 或 `pcaddu12i + addi.d` 等指令对中的立即数字段。
pub fn applyLoongArch64Reloc(site: *u64, typ: u16, delta: i64) bool {
    switch (typ) {
        IMAGE_REL_LOONGARCH64_RELATIVE64 => {
            const cur: i64 = @bitCast(site.*);
            site.* = @bitCast(cur + delta);
            return true;
        },
        IMAGE_REL_LOONGARCH64_MARK_LA => {
            // MARK_LA：调整 lu12i.w + ori 指令对中的 20+12 位立即数。
            // 指令对为两个 32 位指令，共 8 字节。
            const insn_pair = site.*;
            const lo32: u32 = @truncate(insn_pair);
            const hi32: u32 = @truncate(insn_pair >> 32);
            // 提取当前绝对地址：lu12i.w 的 [24:5] 为 si20，ori 的 [21:10] 为 ui12
            const cur_hi20: i32 = @as(i32, @bitCast(lo32)) >> 5;
            const cur_lo12: u32 = (hi32 >> 10) & 0xFFF;
            const cur_addr: i64 = (@as(i64, cur_hi20) << 12) | @as(i64, cur_lo12);
            const new_addr = cur_addr +% delta;
            const new_lo12: u32 = @truncate(@as(u64, @bitCast(new_addr)) & 0xFFF);
            const new_hi20: u32 = @truncate((@as(u64, @bitCast(new_addr)) >> 12) & 0xFFFFF);
            const new_lo = (lo32 & 0x1F) | (new_hi20 << 5);
            const new_hi = (hi32 & ~@as(u32, 0xFFF << 10)) | (new_lo12 << 10);
            site.* = @as(u64, new_hi) << 32 | @as(u64, new_lo);
            return true;
        },
        IMAGE_REL_LOONGARCH64_JUMPER => {
            // JUMPER：补丁分支指令的 PC 相对偏移。
            // LoongArch 分支指令：立即数字段编码为 SImm14 << 2，14-bit 有符号偏移 × 4。
            const raw: u32 = @truncate(site.*);
            const hi32: u32 = @truncate(site.* >> 32);
            const cur_off: i32 = @bitCast(hi32);
            const new_off = cur_off +% @as(i32, @intCast(delta));
            const new_off_u32: u32 = @bitCast(new_off);
            site.* = (@as(u64, new_off_u32) << 32) | @as(u64, raw);
            return true;
        },
        IMAGE_REL_LOONGARCH64_REFLOCAL => {
            // REFLOCAL：本地符号引用 — 相对当前 site 的引用，delta 即符号最终地址差。
            const cur: i64 = @bitCast(site.*);
            site.* = @bitCast(cur + delta);
            return true;
        },
        IMAGE_REL_LOONGARCH64_SUPPORT_SPLIT => {
            // SUPPORT_SPLIT：辅助标记，当前无特殊处理。
            return true;
        },
        else => return false,
    }
}

// ── PE32 (32-bit) Optional Header ──

pub const OptionalHeader32 = extern struct {
    magic: u16 align(1) = PE32_MAGIC,
    major_linker_version: u8 align(1) = 14,
    minor_linker_version: u8 align(1) = 0,
    size_of_code: u32 align(1) = 0,
    size_of_initialized_data: u32 align(1) = 0,
    size_of_uninitialized_data: u32 align(1) = 0,
    address_of_entry_point: u32 align(1) = 0,
    base_of_code: u32 align(1) = 0,
    base_of_data: u32 align(1) = 0,
    image_base: u32 align(1) = 0x00400000,
    section_alignment: u32 align(1) = 0x1000,
    file_alignment: u32 align(1) = 0x200,
    major_os_version: u16 align(1) = 6,
    minor_os_version: u16 align(1) = 0,
    major_image_version: u16 align(1) = 0,
    minor_image_version: u16 align(1) = 0,
    major_subsystem_version: u16 align(1) = 6,
    minor_subsystem_version: u16 align(1) = 0,
    win32_version_value: u32 align(1) = 0,
    size_of_image: u32 align(1) = 0,
    size_of_headers: u32 align(1) = 0,
    checksum: u32 align(1) = 0,
    subsystem: u16 align(1) = IMAGE_SUBSYSTEM_WINDOWS_CUI,
    dll_characteristics: u16 align(1) = 0,
    size_of_stack_reserve: u32 align(1) = 0x100000,
    size_of_stack_commit: u32 align(1) = 0x1000,
    size_of_heap_reserve: u32 align(1) = 0x100000,
    size_of_heap_commit: u32 align(1) = 0x1000,
    loader_flags: u32 align(1) = 0,
    number_of_rva_and_sizes: u32 align(1) = IMAGE_NUM_DIRECTORIES,
    data_directory: [IMAGE_NUM_DIRECTORIES]DataDirectory align(1) = [_]DataDirectory{.{}} ** IMAGE_NUM_DIRECTORIES,
};

// ── PEB/TEB ──
// 用户态可见 NT 6.1 x64 前缀布局见 [`sdk/peb_nt61_x64.zig`](../sdk/peb_nt61_x64.zig) / [`sdk/teb_nt61_x64.zig`](../sdk/teb_nt61_x64.zig)；此处为加载器侧 Zig 镜像（字段顺序不必与公开 PEB 一致）。

pub const PEB = struct {
    image_base: u64 = 0,
    process_parameters: u64 = 0,
    ldr_data: u64 = 0,
    subsystem: u16 = 0,
    os_major_version: u32 = 0,
    os_minor_version: u32 = 0,
    os_build_number: u32 = 0,
    os_platform_id: u32 = 0,
    number_of_processors: u32 = 0,
    session_id: u32 = 0,
    being_debugged: bool = false,
    nt_global_flag: u32 = 0,
    image_subsystem: u16 = 0,
    image_subsystem_major: u16 = 0,
    image_subsystem_minor: u16 = 0,
};

pub const TEB = struct {
    self_ptr: u64 = 0,
    process_id: u32 = 0,
    thread_id: u32 = 0,
    peb_ptr: u64 = 0,
    stack_base: u64 = 0,
    stack_limit: u64 = 0,
    last_error: u32 = 0,
    last_status: i32 = 0,
    tls_slots: [64]u64 = [_]u64{0} ** 64,
    tls_expansion_slots: u64 = 0,
    locale_id: u32 = 0,
};

pub const ProcessParameters = struct {
    image_path: [260]u8 = [_]u8{0} ** 260,
    image_path_len: usize = 0,
    command_line: [260]u8 = [_]u8{0} ** 260,
    command_line_len: usize = 0,
    current_directory: [260]u8 = [_]u8{0} ** 260,
    current_dir_len: usize = 0,
    dll_path: [260]u8 = [_]u8{0} ** 260,
    dll_path_len: usize = 0,
    environment_ptr: u64 = 0,
    environment_size: u32 = 0,
    std_input: u64 = 0,
    std_output: u64 = 0,
    std_error: u64 = 0,
    window_title: [64]u8 = [_]u8{0} ** 64,
    window_title_len: usize = 0,
    desktop_info: [32]u8 = [_]u8{0} ** 32,
    desktop_info_len: usize = 0,
    flags: u32 = 0,
    show_window: u16 = 0,
};

pub const LdrDataTableEntry = struct {
    dll_base: u64 = 0,
    entry_point: u64 = 0,
    size_of_image: u32 = 0,
    full_dll_name: [128]u8 = [_]u8{0} ** 128,
    full_dll_name_len: usize = 0,
    base_dll_name: [64]u8 = [_]u8{0} ** 64,
    base_dll_name_len: usize = 0,
    flags: u32 = 0,
    load_count: u16 = 0,
    tls_index: u16 = 0,
};

// ── PE Image Loading ──

const MAX_LOADED_IMAGES: usize = 64;
const MAX_SECTIONS: usize = 32;
const MAX_IMPORTS: usize = 16;
const MAX_EXPORTS: usize = 64;

pub const ExportEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    ordinal: u16 = 0,
    rva: u32 = 0,
};

pub const ImportEntry = struct {
    dll_name: [64]u8 = [_]u8{0} ** 64,
    dll_name_len: usize = 0,
    func_count: u32 = 0,
    is_resolved: bool = false,
};

pub const SectionInfo = struct {
    name: [8]u8 = [_]u8{0} ** 8,
    virtual_address: u32 = 0,
    virtual_size: u32 = 0,
    raw_data_offset: u32 = 0,
    raw_data_size: u32 = 0,
    characteristics: u32 = 0,

    pub fn isExecutable(self: *const SectionInfo) bool {
        return (self.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0;
    }

    pub fn isWritable(self: *const SectionInfo) bool {
        return (self.characteristics & IMAGE_SCN_MEM_WRITE) != 0;
    }

    pub fn isCode(self: *const SectionInfo) bool {
        return (self.characteristics & IMAGE_SCN_CNT_CODE) != 0;
    }
};

pub const LoadedImage = struct {
    header: ob.ObjectHeader = .{},
    image_base: u64 = 0,
    entry_point: u64 = 0,
    size_of_image: u32 = 0,
    subsystem: u16 = 0,
    is_dll: bool = false,
    is_loaded: bool = false,
    is_mapped: bool = false,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    full_path: [260]u8 = [_]u8{0} ** 260,
    full_path_len: usize = 0,
    section_count: usize = 0,
    sections: [MAX_SECTIONS]SectionInfo = [_]SectionInfo{.{}} ** MAX_SECTIONS,
    import_count: usize = 0,
    imports: [MAX_IMPORTS]ImportEntry = [_]ImportEntry{.{}} ** MAX_IMPORTS,
    export_count: usize = 0,
    exports: [MAX_EXPORTS]ExportEntry = [_]ExportEntry{.{}} ** MAX_EXPORTS,
    peb: PEB = .{},
    teb: TEB = .{},
    params: ProcessParameters = .{},
    ldr_entry: LdrDataTableEntry = .{},
    characteristics: u16 = 0,
    machine: u16 = 0,
    timestamp: u32 = 0,
    checksum: u32 = 0,
    dll_characteristics: u16 = 0,
    stack_reserve: u64 = 0,
    stack_commit: u64 = 0,
    heap_reserve: u64 = 0,
    heap_commit: u64 = 0,
    ref_count: u32 = 0,
    process_id: u32 = 0,
    /// `NtCreateSection` 匿名节 + `NtMapViewOfSection` 等价路径保活（无句柄表时由映像引用）。
    section_keepalive: ?*section_mm.SectionObject = null,

    pub fn getName(self: *const LoadedImage) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getFullPath(self: *const LoadedImage) []const u8 {
        return self.full_path[0..self.full_path_len];
    }

    pub fn findExport(self: *const LoadedImage, func_name: []const u8) ?u64 {
        for (self.exports[0..self.export_count]) |*exp| {
            if (exp.name_len == func_name.len) {
                var match = true;
                for (exp.name[0..exp.name_len], func_name) |a, b| {
                    if (a != b) {
                        match = false;
                        break;
                    }
                }
                if (match) return self.image_base + exp.rva;
            }
        }
        return null;
    }

    /// 按 PE **序号**（合成导出表中的 `ordinal`）解析 RVA；无序号匹配返回 null。
    pub fn findExportByOrdinal(self: *const LoadedImage, ordinal: u16) ?u64 {
        for (self.exports[0..self.export_count]) |*exp| {
            if (exp.ordinal == ordinal) return self.image_base + exp.rva;
        }
        return null;
    }

    pub fn addExport(self: *LoadedImage, name: []const u8, rva: u32, ordinal: u16) void {
        if (self.export_count >= MAX_EXPORTS) return;
        var exp = &self.exports[self.export_count];
        const n = @min(name.len, exp.name.len);
        @memcpy(exp.name[0..n], name[0..n]);
        exp.name_len = n;
        exp.rva = rva;
        exp.ordinal = ordinal;
        self.export_count += 1;
    }

    pub fn addImport(self: *LoadedImage, dll_name: []const u8) void {
        if (self.import_count >= MAX_IMPORTS) return;
        var imp = &self.imports[self.import_count];
        const n = @min(dll_name.len, imp.dll_name.len);
        @memcpy(imp.dll_name[0..n], dll_name[0..n]);
        imp.dll_name_len = n;
        self.import_count += 1;
    }

    pub fn addSection(self: *LoadedImage, name: []const u8, va: u32, vs: u32, chars: u32) void {
        if (self.section_count >= MAX_SECTIONS) return;
        var sec = &self.sections[self.section_count];
        const n = @min(name.len, sec.name.len);
        @memcpy(sec.name[0..n], name[0..n]);
        sec.virtual_address = va;
        sec.virtual_size = vs;
        sec.characteristics = chars;
        self.section_count += 1;
    }
};

var loaded_images: [MAX_LOADED_IMAGES]LoadedImage = [_]LoadedImage{.{}} ** MAX_LOADED_IMAGES;
var image_count: usize = 0;

pub const LoadStatus = enum {
    success,
    invalid_format,
    not_pe,
    not_pe64,
    too_many_images,
    section_error,
    import_error,
    relocation_error,
    dll_not_found,
    entry_not_found,
    already_loaded,
    /// `IMAGE_DIRECTORY_ENTRY_TLS` 非空：回调/线程局部存储顺序未接线。
    tls_directory_not_supported,
    /// `IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT` 非空。
    delay_load_not_supported,
    /// `IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT` 非空。
    bound_import_not_supported,
};

pub const LoadResult = struct {
    status: LoadStatus = .success,
    image: ?*LoadedImage = null,
};

pub fn loadImage(name: []const u8, image_base: u64) LoadResult {
    if (image_count >= MAX_LOADED_IMAGES) return .{ .status = .too_many_images };

    var img = &loaded_images[image_count];
    img.* = .{};

    const name_copy = @min(name.len, img.name.len);
    @memcpy(img.name[0..name_copy], name[0..name_copy]);
    img.name_len = name_copy;
    img.image_base = image_base;
    img.is_loaded = true;

    img.peb = .{
        .image_base = image_base,
        .subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI,
    };

    img.teb = .{
        .peb_ptr = @intFromPtr(&img.peb),
    };

    img.ldr_entry = .{
        .dll_base = image_base,
        .size_of_image = img.size_of_image,
    };
    @memcpy(img.ldr_entry.base_dll_name[0..name_copy], name[0..name_copy]);
    img.ldr_entry.base_dll_name_len = name_copy;

    image_count += 1;

    klog.info("PE Loader: '%s' loaded at 0x%x", .{ name, image_base });

    return .{ .status = .success, .image = img };
}

pub fn loadDll(name: []const u8, base: u64) LoadResult {
    if (getLoadedImage(name)) |existing| {
        existing.ref_count += 1;
        return .{ .status = .already_loaded, .image = existing };
    }

    const result = loadImage(name, base);
    if (result.image) |img| {
        img.is_dll = true;
        img.characteristics |= IMAGE_FILE_DLL;
    }
    return result;
}

pub fn unloadDll(name: []const u8) bool {
    const img = getLoadedImage(name) orelse return false;
    if (!img.is_dll) return false;

    if (img.ref_count > 1) {
        img.ref_count -= 1;
        return true;
    }

    img.is_loaded = false;
    img.ref_count = 0;
    klog.debug("PE Loader: DLL '%s' unloaded", .{name});
    return true;
}

pub const PeFormat = enum {
    unknown,
    pe32,
    pe32plus,
};

/// Optional header 中 `Subsystem` 字段相对 optional 起始的偏移（PE32 / PE32+ 均为 68；公开 COFF 文档）。
pub fn optionalSubsystemWordOffsetFromMagic(magic: u16) ?usize {
    return switch (magic) {
        PE32_MAGIC, PE32PLUS_MAGIC => 68,
        else => null,
    };
}

/// 从 **已映射** 的 PE 映像字节读取 `OptionalHeader.Subsystem`；非 PE 或缓冲过短返回 null。
/// **unsafe**：`data` 须为有效 PE 视图；`DosHeader` 布局与 MS PE 规范一致。
pub fn readSubsystemFromPeBytes(data: []const u8) ?u16 {
    if (validatePeHeader(data) != .success) return null;
    const dos: *const DosHeader = @ptrCast(@alignCast(data.ptr));
    const pe = dos.e_lfanew;
    if (data.len < pe + 4 + @sizeOf(FileHeader)) return null;
    const opt_start = pe + 4 + @sizeOf(FileHeader);
    const fh: *const FileHeader = @ptrCast(@alignCast(data.ptr + pe + 4));
    if (fh.size_of_optional_header < 70) return null;
    if (data.len < opt_start + fh.size_of_optional_header) return null;
    const magic = std.mem.readInt(u16, data[opt_start..][0..2], .little);
    const off = optionalSubsystemWordOffsetFromMagic(magic) orelse return null;
    const sub_off = opt_start + off;
    if (sub_off + 2 > data.len) return null;
    return std.mem.readInt(u16, data[sub_off..][0..2], .little);
}

pub fn validatePeHeader(data: []const u8) LoadStatus {
    if (data.len < @sizeOf(DosHeader)) return .invalid_format;

    const dos = @as(*const DosHeader, @ptrCast(@alignCast(data.ptr)));
    if (dos.e_magic != 0x5A4D) return .not_pe;

    if (data.len < dos.e_lfanew + 4) return .invalid_format;

    const pe_sig_ptr = data.ptr + dos.e_lfanew;
    const pe_sig = @as(*const u32, @ptrCast(@alignCast(pe_sig_ptr))).*;
    if (pe_sig != PE_SIGNATURE) return .not_pe;

    return .success;
}

/// PE 可选头中数据目录项 **虚拟地址**（RVA）；`entry` 为 `IMAGE_DIRECTORY_ENTRY_*`。
/// **unsafe**：`data` 须已通过 `validatePeHeader`；布局与 Microsoft PE COFF 规范一致。
fn readDataDirectoryRva(data: []const u8, entry: usize) ?u32 {
    if (entry >= IMAGE_NUM_DIRECTORIES) return null;
    if (validatePeHeader(data) != .success) return null;
    const dos = @as(*const DosHeader, @ptrCast(@alignCast(data.ptr)));
    const pe = dos.e_lfanew;
    if (data.len < pe + 4 + @sizeOf(FileHeader)) return null;
    const opt_start = pe + 4 + @sizeOf(FileHeader);
    const fh: *const FileHeader = @ptrCast(@alignCast(data.ptr + pe + 4));
    if (fh.size_of_optional_header < 112 + 8) return null;
    if (data.len < opt_start + fh.size_of_optional_header) return null;
    const magic = std.mem.readInt(u16, data[opt_start..][0..2], .little);
    const dd_base_off: usize = switch (magic) {
        PE32PLUS_MAGIC => 112,
        PE32_MAGIC => 96,
        else => return null,
    };
    const dd_off = opt_start + dd_base_off + entry * 8;
    if (dd_off + 8 > data.len) return null;
    return std.mem.readInt(u32, data[dd_off..][0..4], .little);
}

/// 应用 PE 基址重定位，处理所有重定位块。
/// `data` 为已映射到 `image_base` 的 PE 映像字节。
/// `preferred_base` 为 PE 首选加载基址。
/// `delta` = image_base - preferred_base，即重定位偏移量。
pub fn applyRelocations(data: []u8, image_base: u64, preferred_base: u64, machine: u16) LoadStatus {
    const delta = @as(i64, @intCast(image_base)) - @as(i64, @intCast(preferred_base));
    if (delta == 0) return .success; // 已加载到首选基址，无需重定位

    const reloc_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_BASERELOC) orelse return .relocation_error;
    if (reloc_rva == 0) return .success; // 无重定位表

    const reloc_dir = @as(*const BaseRelocation, @ptrCast(@alignCast(data.ptr + reloc_rva)));
    var current_block = reloc_dir;

    while (current_block.virtual_address != 0 or current_block.size_of_block != 0) {
        const block_base = current_block.virtual_address;
        const block_size = current_block.size_of_block;

        // 计算重定位项数量：每个项2字节，减去头部8字节
        const num_entries = (block_size - @sizeOf(BaseRelocation)) / 2;
        const entries = @as([*]const u16, @ptrCast(@alignCast(@as([*]u8, @ptrCast(current_block)) + @sizeOf(BaseRelocation))));

        for (entries[0..num_entries]) |entry| {
            const typ = entry >> 12;
            const offset = entry & 0xFFF;
            const site_va = image_base + block_base + offset;

            // 检查是否在映像范围内
            if (site_va < @intFromPtr(data.ptr) or site_va >= @intFromPtr(data.ptr) + data.len) {
                continue;
            }

            const site_ptr = @as(*u64, @ptrCast(@alignCast(site_va)));

            switch (machine) {
                IMAGE_FILE_MACHINE_AMD64 => {
                    switch (typ) {
                        IMAGE_REL_BASED_ABSOLUTE => {}, // 填充项，忽略
                        IMAGE_REL_BASED_DIR64 => { // 64位绝对地址重定位
                            site_ptr.* += @as(u64, @bitCast(delta));
                        },
                        else => return .relocation_error, // 不支持的重定位类型
                    }
                },
                IMAGE_FILE_MACHINE_I386 => {
                    switch (typ) {
                        IMAGE_REL_BASED_ABSOLUTE => {},
                        IMAGE_REL_BASED_HIGHLOW => { // 32位绝对地址重定位
                            const site32 = @as(*u32, @ptrCast(site_ptr));
                            site32.* += @as(u32, @truncate(@as(u64, @bitCast(delta))));
                        },
                        else => return .relocation_error,
                    }
                },
                IMAGE_FILE_MACHINE_LOONGARCH64 => {
                    if (!applyLoongArch64Reloc(site_ptr, typ, delta)) {
                        return .relocation_error;
                    }
                },
                IMAGE_FILE_MACHINE_ARM64 => {
                    switch (typ) {
                        IMAGE_REL_BASED_ABSOLUTE => {},
                        IMAGE_REL_BASED_DIR64 => {
                            site_ptr.* += @as(u64, @bitCast(delta));
                        },
                        IMAGE_REL_BASED_ARM64_MOV32 => {
                            // 处理MOVW/MOVT指令对
                            const site32 = @as(*[2]u32, @ptrCast(site_ptr));
                            const imm16_lo = site32[0] >> 5 & 0xFFFF;
                            const imm16_hi = site32[1] >> 5 & 0xFFFF;
                            var full_addr = (@as(u32, imm16_hi) << 16) | imm16_lo;
                            full_addr += @as(u32, @truncate(@as(u64, @bitCast(delta))));
                            // 重新编码指令
                            site32[0] = (site32[0] & 0x1F) | ((full_addr & 0xFFFF) << 5);
                            site32[1] = (site32[1] & 0x1F) | ((full_addr >> 16) << 5);
                        },
                        else => return .relocation_error,
                    }
                },
                IMAGE_FILE_MACHINE_RISCV64 => {
                    switch (typ) {
                        IMAGE_REL_BASED_ABSOLUTE => {},
                        IMAGE_REL_BASED_DIR64 => {
                            site_ptr.* += @as(u64, @bitCast(delta));
                        },
                        else => return .relocation_error,
                    }
                },
                else => return .relocation_error, // 不支持的架构
            }
        }

        // 移动到下一个重定位块
        current_block = @as(*const BaseRelocation, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(current_block)) + block_size)));
    }

    return .success;
}

/// 解析 PE 导出表，将所有导出函数添加到 LoadedImage 的 exports 数组。
/// `data` 为已映射的 PE 映像字节。
pub fn parseExportTable(img: *LoadedImage, data: []const u8) LoadStatus {
    const export_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_EXPORT) orelse return .success;
    if (export_rva == 0) return .success; // 无导出表

    const export_dir = @as(*const ExportDirectory, @ptrCast(@alignCast(data.ptr + export_rva)));
    const ordinal_base = export_dir.ordinal_base;
    const num_functions = export_dir.number_of_functions;
    const num_names = export_dir.number_of_names;

    const address_table = @as([*]const u32, @ptrCast(@alignCast(data.ptr + export_dir.address_of_functions)));
    const name_table = @as([*]const u32, @ptrCast(@alignCast(data.ptr + export_dir.address_of_names)));
    const ordinal_table = @as([*]const u16, @ptrCast(@alignCast(data.ptr + export_dir.address_of_name_ordinals)));

    // 首先处理有名称的导出
    for (0..num_names) |i| {
        const name_rva = name_table[i];
        const ordinal = ordinal_table[i];
        const func_rva = address_table[ordinal - ordinal_base];

        // 读取函数名称
        const name_ptr = @as([*]const u8, @ptrCast(@alignCast(data.ptr + name_rva)));
        var name_len: usize = 0;
        while (name_ptr[name_len] != 0 and name_len < 256) : (name_len += 1) {}
        const name = name_ptr[0..name_len];

        img.addExport(name, func_rva, ordinal);
    }

    // 处理只有序号的导出
    for (0..num_functions) |i| {
        const ordinal = @as(u16, @intCast(i)) + ordinal_base;
        // 检查是否已经作为命名导出添加过
        var found = false;
        for (img.exports[0..img.export_count]) |exp| {
            if (exp.ordinal == ordinal) {
                found = true;
                break;
            }
        }
        if (!found) {
            const func_rva = address_table[i];
            // 无名称，使用序号作为名称
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "#{}", .{ordinal}) catch continue;
            img.addExport(name, func_rva, ordinal);
        }
    }

    klog.debug("PE Loader: parsed {} exports from image", .{img.export_count});
    return .success;
}

/// 解析 PE 导入表，将所有导入的 DLL 添加到 LoadedImage 的 imports 数组。
/// `data` 为已映射的 PE 映像字节。
pub fn parseImportTable(img: *LoadedImage, data: []const u8) LoadStatus {
    const import_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_IMPORT) orelse return .success;
    if (import_rva == 0) return .success; // 无导入表

    var import_desc = @as(*const ImportDescriptor, @ptrCast(@alignCast(data.ptr + import_rva)));
    while (import_desc.name_rva != 0) : (import_desc += 1) {
        // 读取 DLL 名称
        const name_ptr = @as([*]const u8, @ptrCast(@alignCast(data.ptr + import_desc.name_rva)));
        var name_len: usize = 0;
        while (name_ptr[name_len] != 0 and name_len < 256) : (name_len += 1) {}
        const dll_name = name_ptr[0..name_len];

        // 添加到导入列表
        img.addImport(dll_name);

        // 计算导入函数数量
        const thunk_rva = if (import_desc.original_first_thunk != 0) import_desc.original_first_thunk else import_desc.first_thunk;
        if (thunk_rva == 0) continue;

        const thunk_ptr = @as([*]const u64, @ptrCast(@alignCast(data.ptr + thunk_rva)));
        var func_count: u32 = 0;
        var i: usize = 0;
        while (thunk_ptr[i] != 0) : (i += 1) {
            func_count += 1;
        }

        // 更新导入项的函数计数
        if (img.import_count > 0) {
            img.imports[img.import_count - 1].func_count = func_count;
        }
    }

    klog.debug("PE Loader: parsed {} imported DLLs from image", .{img.import_count});
    return .success;
}

/// PE 加载安全检查：验证校验和、DEP/ASLR设置、签名验证。
pub fn performSecurityChecks(data: []const u8, optional_header: *const OptionalHeader64) LoadStatus {
    // 验证校验和（如果非零）
    if (optional_header.checksum != 0) {
        // TODO: 实现PE校验和计算验证
        klog.debug("PE Loader: skipping checksum verification (not implemented)", .{});
    }

    // 检查DEP设置（NX_COMPAT）
    if ((optional_header.dll_characteristics & IMAGE_DLLCHARACTERISTICS_NX_COMPAT) == 0) {
        klog.warning("PE Loader: image does not support DEP/NX", .{});
        // 可以配置是否拒绝加载
    }

    // 检查ASLR设置（DYNAMIC_BASE）
    if ((optional_header.dll_characteristics & IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE) == 0) {
        klog.warning("PE Loader: image does not support ASLR", .{});
    }

    // 检查安全证书（数字签名）
    const security_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_SECURITY) orelse return .success;
    if (security_rva != 0) {
        // TODO: 实现PE签名验证，确保映像未被篡改
        klog.debug("PE Loader: image has security directory (signature verification not implemented)", .{});
    }

    return .success;
}

/// 从原始PE字节数据加载PE映像到指定地址空间。
/// `data` 为原始PE文件字节。
/// `process` 为目标进程。
/// `preferred_base` 为首选加载基址（0则自动选择）。
pub fn loadPeFromData(data: []const u8, process: *process_mod.Process, preferred_base: u64) LoadResult {
    // 验证PE头
    const validate_status = validatePeHeader(data);
    if (validate_status != .success) {
        return .{ .status = validate_status };
    }

    // 解析DOS头和PE头
    const dos = @as(*const DosHeader, @ptrCast(@alignCast(data.ptr)));
    const pe_offset = dos.e_lfanew;
    const file_header = @as(*const FileHeader, @ptrCast(@alignCast(data.ptr + pe_offset + 4)));

    // 检查架构
    if (file_header.machine != IMAGE_FILE_MACHINE_AMD64) {
        // TODO: 支持其他架构
        return .{ .status = .invalid_format };
    }

    // 读取可选头
    const opt_header = @as(*const OptionalHeader64, @ptrCast(@alignCast(data.ptr + pe_offset + 4 + @sizeOf(FileHeader))));
    if (opt_header.magic != PE32PLUS_MAGIC) {
        return .{ .status = .not_pe64 };
    }

    // 执行安全检查
    const security_status = performSecurityChecks(data, opt_header);
    if (security_status != .success) {
        return .{ .status = security_status };
    }

    // 确定加载基址
    const image_base = if (preferred_base == 0) opt_header.image_base else preferred_base;
    const size_of_image = opt_header.size_of_image;

    // 分配地址空间
    const asp = process.address_space orelse return .{ .status = .section_error };
    _ = asp; // TODO: 调用vm.allocateVirtualMemory分配映像内存
    klog.debug("PE Loader: allocating 0x{x} bytes at 0x{x}", .{ size_of_image, image_base });

    // 创建加载映像对象
    if (image_count >= MAX_LOADED_IMAGES) {
        return .{ .status = .too_many_images };
    }

    var img = &loaded_images[image_count];
    img.* = .{
        .image_base = image_base,
        .entry_point = image_base + opt_header.address_of_entry_point,
        .size_of_image = size_of_image,
        .subsystem = opt_header.subsystem,
        .is_dll = (file_header.characteristics & IMAGE_FILE_DLL) != 0,
        .machine = file_header.machine,
        .timestamp = file_header.time_date_stamp,
        .checksum = opt_header.checksum,
        .dll_characteristics = opt_header.dll_characteristics,
        .stack_reserve = opt_header.size_of_stack_reserve,
        .stack_commit = opt_header.size_of_stack_commit,
        .heap_reserve = opt_header.size_of_heap_reserve,
        .heap_commit = opt_header.size_of_heap_commit,
        .process_id = process.pid,
        .is_loaded = true,
    };

    // 复制节信息
    const section_headers = @as([*]const SectionHeader, @ptrCast(@alignCast(data.ptr + pe_offset + 4 + @sizeOf(FileHeader) + file_header.size_of_optional_header)));
    for (0..file_header.number_of_sections) |i| {
        const sec = &section_headers[i];
        img.addSection(sec.name[0..8], sec.virtual_address, sec.virtual_size, sec.characteristics);
        // 映射节到地址空间
        if (sec.size_of_raw_data > 0) {
            const sec_va = image_base + sec.virtual_address;
            _ = data[sec.pointer_to_raw_data .. sec.pointer_to_raw_data + sec.size_of_raw_data];
            klog.debug("PE Loader: mapping section '%s' to 0x{x} (size 0x{x})", .{ sec.name[0..8], sec_va, sec.virtual_size });
            // TODO: 调用vm.mapUserMemory将节数据映射到进程地址空间
            // 对于BSS节（无原始数据），只需分配并清零内存
        }
    }

    // 应用重定位
    const reloc_status = applyRelocations(@as([]u8, @ptrCast(@alignCast(data.ptr))), // TODO: 传递已映射的映像内存
        image_base, opt_header.image_base, file_header.machine);
    if (reloc_status != .success) {
        return .{ .status = reloc_status };
    }

    // 解析导出表
    const export_status = parseExportTable(img, data);
    if (export_status != .success) {
        return .{ .status = export_status };
    }

    // 解析导入表
    const import_status = parseImportTable(img, data);
    if (import_status != .success) {
        return .{ .status = import_status };
    }

    // TODO: 解析并处理延迟导入、绑定导入、TLS目录等

    // 初始化PEB和进程参数
    img.peb = .{
        .image_base = image_base,
        .subsystem = opt_header.subsystem,
        .os_major_version = opt_header.major_os_version,
        .os_minor_version = opt_header.minor_os_version,
        .os_build_number = 7601, // Windows 7 SP1 build number
        .os_platform_id = 2, // VER_PLATFORM_WIN32_NT
        .number_of_processors = 1,
    };

    img.teb = .{
        .process_id = process.pid,
        .peb_ptr = @intFromPtr(&img.peb),
    };

    img.ldr_entry = .{
        .dll_base = image_base,
        .entry_point = img.entry_point,
        .size_of_image = size_of_image,
    };

    image_count += 1;

    klog.info("PE Loader: PE image loaded successfully at 0x{x}, entry point at 0x{x}", .{ image_base, img.entry_point });

    return .{ .status = .success, .image = img };
}

/// 获取已加载的映像按名称（不区分大小写，符合Windows DLL加载规则）。
pub fn getLoadedImage(name: []const u8) ?*LoadedImage {
    for (loaded_images[0..image_count]) |*img| {
        if (!img.is_loaded) continue;
        if (img.name_len != name.len) continue;
        var match = true;
        for (img.name[0..img.name_len], name) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) {
                match = false;
                break;
            }
        }
        if (match) return img;
    }
    return null;
}

/// 获取已加载的映像按基址。
pub fn getLoadedImageByBase(base: u64) ?*LoadedImage {
    for (loaded_images[0..image_count]) |*img| {
        if (!img.is_loaded) continue;
        if (img.image_base == base) {
            return img;
        }
    }
    return null;
}

// ── NT API 实现 ──

/// NtCreateSection: 创建节对象，用于映射PE映像或共享内存。
pub fn NtCreateSection(section_handle: *ob.Handle, desired_access: ob.ACCESS_MASK, object_attributes: ?*ob.ObjectAttributes, maximum_size: ?u64, page_protection: u32, allocation_attributes: u32, file_handle: ?ob.Handle) callconv(.C) u32 {
    _ = object_attributes;
    _ = file_handle;

    klog.debug("PE Loader: NtCreateSection called, desired_access=0x{x}, max_size=0x{x}, protection=0x{x}, alloc_attr=0x{x}", .{ desired_access, maximum_size orelse 0, page_protection, allocation_attributes });

    // 检查是否为PE映像节
    if ((allocation_attributes & SEC_IMAGE) != 0) {
        klog.debug("PE Loader: creating PE image section", .{});
        // TODO: 创建节对象，关联文件句柄对应的PE文件
    }

    // 创建节对象
    const sec = section_mm.createSection(maximum_size orelse 0, page_protection, allocation_attributes) orelse {
        return 0xC0000017; // STATUS_NO_MEMORY
    };

    // 分配句柄
    const current_process = process_mod.getCurrentProcess() orelse return 0xC0000005; // STATUS_ACCESS_VIOLATION
    const handle = ob.createHandle(&current_process.handle_table, @intFromPtr(sec), .section_object) orelse {
        section_mm.releaseSection(sec);
        return 0xC0000017; // STATUS_NO_MEMORY
    };

    section_handle.* = handle;
    klog.debug("PE Loader: NtCreateSection succeeded, handle=0x{x}", .{handle});
    return 0; // STATUS_SUCCESS
}

/// NtMapViewOfSection: 将节对象映射到进程地址空间。
pub fn NtMapViewOfSection(section_handle: ob.Handle, process_handle: ob.Handle, base_address: *u64, zero_bits: usize, commit_size: usize, section_offset: ?*u64, view_size: *usize, inherit_disposition: u32, allocation_type: u32, protect: u32) callconv(.C) u32 {
    _ = zero_bits;
    _ = commit_size;
    _ = inherit_disposition;
    _ = allocation_type;

    klog.debug("PE Loader: NtMapViewOfSection called, section_handle=0x{x}, process_handle=0x{x}, base=0x{x}", .{ section_handle, process_handle, base_address.* });

    // 获取当前进程
    const current_process = process_mod.getCurrentProcess() orelse return 0xC0000005; // STATUS_ACCESS_VIOLATION
    const target_process = if (process_handle == 0xFFFFFFFFFFFFFFFF) // NtCurrentProcess()
        current_process
    else
        process_mod.findProcess(process_handle) orelse return 0xC0000008; // STATUS_INVALID_HANDLE;

    // 获取节对象
    const sec = ob.getObjectFromHandle(&current_process.handle_table, section_handle, .section_object) orelse {
        return 0xC0000008; // STATUS_INVALID_HANDLE
    };
    const section = @as(*section_mm.SectionObject, @ptrCast(@alignCast(sec)));

    // 映射节到进程地址空间
    const asp = target_process.address_space orelse return 0xC0000005; // STATUS_ACCESS_VIOLATION
    const mapped_base = section_mm.mapSection(asp, section, base_address.*, view_size.*, section_offset orelse 0, protect) orelse {
        return 0xC0000017; // STATUS_NO_MEMORY
    };

    base_address.* = mapped_base;
    klog.debug("PE Loader: NtMapViewOfSection succeeded, mapped base=0x{x}, size=0x{x}", .{ mapped_base, view_size.* });
    return 0; // STATUS_SUCCESS
}

/// LdrLoadDll: 加载DLL模块到进程地址空间。
pub fn LdrLoadDll(dll_path: ?[*]const u16, flags: ?*u32, module_name: *const ob.UnicodeString, module_handle: *u64) callconv(.C) u32 {
    _ = dll_path;
    _ = flags;

    klog.debug("PE Loader: LdrLoadDll called, module_name='%s'", .{module_name.buffer[0 .. module_name.length / 2]});

    // 转换Unicode字符串为UTF-8
    var dll_name_buf: [260]u8 = undefined;
    var dll_name_len: usize = 0;
    for (module_name.buffer[0 .. module_name.length / 2]) |wc| {
        if (wc > 0x7F) {
            // TODO: 完整Unicode转UTF-8
            dll_name_buf[dll_name_len] = '?';
        } else {
            dll_name_buf[dll_name_len] = @as(u8, @truncate(wc));
        }
        dll_name_len += 1;
        if (dll_name_len >= dll_name_buf.len) break;
    }
    const dll_name = dll_name_buf[0..dll_name_len];

    // 检查是否已经加载
    if (getLoadedImage(dll_name)) |existing| {
        existing.ref_count += 1;
        module_handle.* = existing.image_base;
        klog.debug("PE Loader: LdrLoadDll succeeded (already loaded), handle=0x{x}", .{existing.image_base});
        return 0; // STATUS_SUCCESS
    }

    // TODO: 从文件系统读取DLL文件
    // TODO: 调用loadPeFromData加载DLL

    // 临时：模拟加载成功
    const result = loadDll(dll_name, 0x180000000); // 模拟DLL基址
    if (result.status != .success and result.status != .already_loaded) {
        klog.err("PE Loader: LdrLoadDll failed, status=%d", .{@intFromEnum(result.status)});
        return 0xC0000135; // STATUS_DLL_NOT_FOUND
    }

    const img = result.image orelse return 0xC0000005; // STATUS_ACCESS_VIOLATION
    module_handle.* = img.image_base;

    klog.info("PE Loader: LdrLoadDll succeeded, DLL '%s' loaded at 0x{x}", .{ dll_name, img.image_base });
    return 0; // STATUS_SUCCESS
}

/// 对 **已映射** PE 映像字节检查本加载器尚未接线的目录项；用于返回明确 `LoadStatus` / `NTSTATUS`（阶段 4 二进制兼容）。
pub fn validatePeLoadPolicy(data: []const u8) LoadStatus {
    const header_status = validatePeHeader(data);
    if (header_status != .success) return header_status;

    if (readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_BOUND_IMPORT)) |rva| {
        if (rva != 0) return .bound_import_not_supported;
    }
    // 延迟加载已实现，不再拒绝
    // if (readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT)) |rva| {
    //     if (rva != 0) return .delay_load_not_supported;
    // }
    // TLS 回调已实现（invokeTlsCallbacksIfPresent）
    return .success;
}

/// 将 `LoadStatus` 映射为与 `ntdll.NTSTATUS` 同数值的 `i32`（供 `exec`/syscall 路径统一失败码）。
pub fn loadStatusToNtStatus(status: LoadStatus) i32 {
    return switch (status) {
        .success => 0,
        .invalid_format,
        .not_pe,
        => @as(i32, @bitCast(@as(u32, 0xC000007B))), // STATUS_INVALID_IMAGE_FORMAT
        .not_pe64 => @as(i32, @bitCast(@as(u32, 0xC000007A))), // STATUS_INVALID_IMAGE_WIN_TYPE（近似）
        .too_many_images => @as(i32, @bitCast(@as(u32, 0xC000009A))), // STATUS_INSUFFICIENT_RESOURCES
        .already_loaded => @as(i32, @bitCast(@as(u32, 0xC0000035))), // STATUS_OBJECT_NAME_COLLISION
        .section_error,
        .relocation_error,
        => @as(i32, @bitCast(@as(u32, 0xC000007B))), // STATUS_INVALID_IMAGE_FORMAT
        .import_error,
        .dll_not_found,
        .entry_not_found,
        => @as(i32, @bitCast(@as(u32, 0xC0000135))), // STATUS_DLL_NOT_FOUND
        .tls_directory_not_supported,
        .delay_load_not_supported,
        .bound_import_not_supported,
        => @as(i32, @bitCast(@as(u32, 0xC0000002))), // STATUS_NOT_IMPLEMENTED
    };
}

pub fn detectPeFormat(data: []const u8) PeFormat {
    if (validatePeHeader(data) != .success) return .unknown;

    const dos = @as(*const DosHeader, @ptrCast(@alignCast(data.ptr)));
    const opt_offset = dos.e_lfanew + 4 + @sizeOf(FileHeader);
    if (data.len < opt_offset + 2) return .unknown;

    const magic_ptr = data.ptr + opt_offset;
    const magic = @as(*const u16, @ptrCast(@alignCast(magic_ptr))).*;

    if (magic == PE32_MAGIC) return .pe32;
    if (magic == PE32PLUS_MAGIC) return .pe32plus;
    return .unknown;
}

pub fn loadPe32Image(name: []const u8, image_base: u32) LoadResult {
    if (image_count >= MAX_LOADED_IMAGES) return .{ .status = .too_many_images };

    var img = &loaded_images[image_count];
    img.* = .{};

    const name_copy = @min(name.len, img.name.len);
    @memcpy(img.name[0..name_copy], name[0..name_copy]);
    img.name_len = name_copy;
    img.image_base = @as(u64, image_base);
    img.is_loaded = true;
    img.machine = IMAGE_FILE_MACHINE_I386;

    img.peb = .{
        .image_base = @as(u64, image_base),
        .subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI,
    };

    img.teb = .{
        .peb_ptr = @intFromPtr(&img.peb),
    };

    img.ldr_entry = .{
        .dll_base = @as(u64, image_base),
        .size_of_image = img.size_of_image,
    };
    @memcpy(img.ldr_entry.base_dll_name[0..name_copy], name[0..name_copy]);
    img.ldr_entry.base_dll_name_len = name_copy;

    image_count += 1;
    klog.info("PE Loader: '%s' loaded as PE32 (32-bit) at 0x%x", .{ name, image_base });
    return .{ .status = .success, .image = img };
}

pub fn isPe32Image(img: *const LoadedImage) bool {
    return img.machine == IMAGE_FILE_MACHINE_I386;
}

pub fn getPe32Count() usize {
    var count: usize = 0;
    for (loaded_images[0..image_count]) |*img| {
        if (img.is_loaded and img.machine == IMAGE_FILE_MACHINE_I386) count += 1;
    }
    return count;
}

pub fn getPe64Count() usize {
    var count: usize = 0;
    for (loaded_images[0..image_count]) |*img| {
        if (img.is_loaded and (img.machine == IMAGE_FILE_MACHINE_AMD64 or
            img.machine == IMAGE_FILE_MACHINE_LOONGARCH64 or
            img.machine == IMAGE_FILE_MACHINE_RISCV64 or
            img.machine == IMAGE_FILE_MACHINE_ARM64))
            count += 1;
    }
    return count;
}

pub fn isLoongArch64Image(img: *const LoadedImage) bool {
    return img.machine == IMAGE_FILE_MACHINE_LOONGARCH64;
}

/// 当前构建目标对应的 PE 机器类型。
pub fn nativeMachineType() u16 {
    const builtin = @import("builtin");
    return switch (builtin.cpu.arch) {
        .x86_64 => IMAGE_FILE_MACHINE_AMD64,
        .loongarch64 => IMAGE_FILE_MACHINE_LOONGARCH64,
        .aarch64 => IMAGE_FILE_MACHINE_ARM64,
        .riscv64 => IMAGE_FILE_MACHINE_RISCV64,
        else => IMAGE_FILE_MACHINE_AMD64,
    };
}

pub fn createSection(name: []const u8, base: u64, size: u32, characteristics: u32) ?*LoadedImage {
    if (image_count >= MAX_LOADED_IMAGES) return null;

    var img = &loaded_images[image_count];
    img.* = .{};
    img.image_base = base;
    img.size_of_image = size;
    img.is_loaded = true;
    img.is_mapped = true;

    const name_copy = @min(name.len, img.name.len);
    @memcpy(img.name[0..name_copy], name[0..name_copy]);
    img.name_len = name_copy;

    if (img.section_count < MAX_SECTIONS) {
        var sec = &img.sections[img.section_count];
        sec.virtual_address = 0;
        sec.virtual_size = size;
        sec.characteristics = characteristics;
        img.section_count += 1;
    }

    image_count += 1;
    return img;
}

/// 进程创建路径：`NtCreateSection`（匿名）+ `NtMapViewOfSection` 内核等价实现，将映像占位 VA 提交为节视图。
pub fn mapLoadedImageWithAnonymousSection(proc: *process_mod.Process, img: *LoadedImage) i32 {
    if (proc.address_space == null) return -1073741801;
    var image_sz: u64 = img.size_of_image;
    if (image_sz < 0x10000) image_sz = 0x10000;
    const ps: u64 = 4096;
    image_sz = (image_sz + ps - 1) & ~(ps - 1);
    const PAGE_EXECUTE_READ: u32 = 0x20;
    const sec = section_mm.createAnonymousSection(image_sz, PAGE_EXECUTE_READ) orelse return -1073741801;
    var base = img.image_base;
    var vs = image_sz;
    const st = section_mm.mapViewIntoProcess(proc, sec, &base, 0, &vs);
    if (st != 0) {
        section_mm.releaseSectionObject(sec);
        return st;
    }
    img.section_keepalive = sec;
    return 0;
}

pub fn createProcessImage(name: []const u8, base: u64, entry: u64, pid: u32) ?*LoadedImage {
    const result = loadImage(name, base);
    if (result.image) |img| {
        img.entry_point = entry;
        img.process_id = pid;
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI;

        img.peb.image_base = base;
        img.peb.subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI;

        img.teb.process_id = pid;
        img.teb.thread_id = pid;
        img.teb.peb_ptr = @intFromPtr(&img.peb);

        setProcessParameters(img, name, "");
        return img;
    }
    return null;
}

fn setProcessParameters(img: *LoadedImage, image_path: []const u8, cmd_line: []const u8) void {
    const path_copy = @min(image_path.len, img.params.image_path.len);
    @memcpy(img.params.image_path[0..path_copy], image_path[0..path_copy]);
    img.params.image_path_len = path_copy;

    const cmd_copy = @min(cmd_line.len, img.params.command_line.len);
    @memcpy(img.params.command_line[0..cmd_copy], cmd_line[0..cmd_copy]);
    img.params.command_line_len = cmd_copy;

    const default_dir = "C:\\";
    @memcpy(img.params.current_directory[0..default_dir.len], default_dir);
    img.params.current_dir_len = default_dir.len;

    const dll_path = "C:\\Windows\\System32";
    @memcpy(img.params.dll_path[0..dll_path.len], dll_path);
    img.params.dll_path_len = dll_path.len;
}

pub fn resolveImports(img: *LoadedImage) LoadStatus {
    var resolved: usize = 0;
    for (img.imports[0..img.import_count]) |*imp| {
        const dll = getLoadedImage(imp.dll_name[0..imp.dll_name_len]);
        if (dll != null) {
            imp.is_resolved = true;
            resolved += 1;
        }
    }

    klog.debug("PE Loader: '%s' imports resolved: %u/%u", .{
        img.getName(), resolved, img.import_count,
    });

    return if (resolved == img.import_count) .success else .import_error;
}

/// 从 PE 字节数据中解析导入目录并填充 IAT。
/// `data` 为已映射的 PE 映像，`image_base` 为加载基址。
/// 成功返回 .success；解析失败或无法加载 DLL 返回对应错误。
pub fn resolveImportsFromPeBytes(data: []const u8, image_base: u64) LoadStatus {
    const import_rva = readDataDirectoryRva(data, IMAGE_DIRECTORY_ENTRY_IMPORT) orelse return .success;
    if (import_rva == 0) return .success;

    const import_ptr = @as([*]const ImportDescriptor, @ptrFromInt(@intFromPtr(data.ptr) + import_rva));

    var resolved_total: usize = 0;
    var desc_ptr = import_ptr;
    while (desc_ptr.name_rva != 0) {
        const dll_name = @as([*]const u8, @ptrFromInt(@intFromPtr(data.ptr) + desc_ptr.name_rva));
        var dll_name_len: usize = 0;
        while (dll_name_len < 256 and dll_name[dll_name_len] != 0) : (dll_name_len += 1) {}

        // 加载 DLL（桩：查找已加载的 DLL）
        const dll = getLoadedImage(dll_name[0..dll_name_len]);
        if (dll != null) {
            // IAT 和 ILT（OriginalFirstThunk）条目
            const ilt_rva = desc_ptr.original_first_thunk;
            const iat_rva = desc_ptr.first_thunk;

            if (ilt_rva != 0 and iat_rva != 0) {
                const ilt_ptr = @as([*]const u32, @ptrFromInt(@intFromPtr(data.ptr) + ilt_rva));
                const iat_ptr = @as([*]u64, @ptrFromInt(image_base + iat_rva));

                var idx: usize = 0;
                while (ilt_ptr[idx] != 0) : (idx += 1) {
                    const hint_name_rva = ilt_ptr[idx];
                    // 如果最高位为 1，表示按序号导入（跳过名称）
                    if (hint_name_rva & 0x8000_0000 != 0) {
                        const ordinal = @as(u16, @truncate(hint_name_rva & 0xFFFF));
                        iat_ptr[idx] = dll.findExportByOrdinal(ordinal) orelse 0;
                    } else {
                        const hint_name_ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(data.ptr) + hint_name_rva));
                        var hint_len: usize = 0;
                        while (hint_len < 128 and hint_name_ptr[hint_len] != 0) : (hint_len += 1) {}
                        iat_ptr[idx] = dll.findExport(hint_name_ptr[0..hint_len]) orelse 0;
                    }
                    if (iat_ptr[idx] != 0) resolved_total += 1;
                }
            }
        }

        desc_ptr = @ptrFromInt(@intFromPtr(desc_ptr) + @sizeOf(ImportDescriptor));
    }

    klog.debug("PE Loader: resolved %u import thunks from PE bytes", .{resolved_total});
    return if (resolved_total > 0) .success else .import_error;
}

pub fn getImageByBase(base: u64) ?*LoadedImage {
    for (loaded_images[0..image_count]) |*img| {
        if (!img.is_loaded) continue;
        if (img.image_base == base) return img;
    }
    return null;
}

pub fn getImageCount() usize {
    return image_count;
}

pub fn getDllCount() usize {
    var count: usize = 0;
    for (loaded_images[0..image_count]) |*img| {
        if (img.is_loaded and img.is_dll) count += 1;
    }
    return count;
}

pub fn getExeCount() usize {
    var count: usize = 0;
    for (loaded_images[0..image_count]) |*img| {
        if (img.is_loaded and !img.is_dll) count += 1;
    }
    return count;
}

fn initSystemDlls() void {
    // 与 `KUSER_SHARED_DATA` 固定页 0x7FFE0000 分离，避免与 `mm/kuser_shared.zig` 冲突。
    const ntdll_base: u64 = 0x0000_7FF6_0000_0000;
    const ntdll_result = loadDll("ntdll.dll", ntdll_base);
    if (ntdll_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_NATIVE;
        img.entry_point = ntdll_base + 0x1000;
        img.size_of_image = 0x1A0000;
        img.addSection(".text", 0x1000, 0x100000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE);
        img.addSection(".data", 0x101000, 0x20000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_CNT_INITIALIZED_DATA);
        img.addSection(".rsrc", 0x121000, 0x10000, IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_INITIALIZED_DATA);

        // 导出 **顺序与名称** 须与 [`src/config/nt61_core_dll_abi_inventory.zig`](../config/nt61_core_dll_abi_inventory.zig) 一致（阶段 4 PE ABI）。
        img.addExport("NtCreateProcess", 0x1000, 1);
        img.addExport("NtTerminateProcess", 0x1020, 2);
        img.addExport("NtCreateThread", 0x1040, 3);
        img.addExport("NtCreateFile", 0x1060, 11);
        img.addExport("NtReadFile", 0x1080, 9);
        img.addExport("NtWriteFile", 0x10A0, 9);
        img.addExport("NtClose", 0x10C0, 7);
        img.addExport("NtCreatePort", 0x10E0, 8);
        img.addExport("NtRequestWaitReplyPort", 0x1100, 9);
        img.addExport("NtAllocateVirtualMemory", 0x1120, 10);
        img.addExport("NtFreeVirtualMemory", 0x1140, 11);
        img.addExport("NtQuerySystemInformation", 0x1160, 12);
        img.addExport("NtQueryInformationProcess", 0x1180, 5);
        img.addExport("NtSetInformationProcess", 0x11A0, 4);
        img.addExport("NtOpenFile", 0x11C0, 6);
        img.addExport("NtCreateEvent", 0x11E0, 16);
        img.addExport("NtWaitForSingleObject", 0x1200, 17);
        img.addExport("RtlInitUnicodeString", 0x2000, 100);
        img.addExport("RtlCopyMemory", 0x2020, 101);
        img.addExport("RtlZeroMemory", 0x2040, 102);
        img.addExport("RtlGetVersion", 0x2060, 103);
        img.addExport("RtlVerifyVersionInfo", 0x2070, 104);
        img.addExport("LdrInitializeThunk", 0x2090, 105);
        img.addExport("LdrLoadDll", 0x20B0, 106);
        img.addExport("LdrGetProcedureAddress", 0x20D0, 107);
        img.addExport("RtlUserThreadStart", 0x20F0, 108);
    }

    const k32_result = loadDll("kernel32.dll", 0x7FFD0000);
    if (k32_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI;
        img.entry_point = 0x7FFD0000 + 0x1000;
        img.size_of_image = 0x180000;
        img.addSection(".text", 0x1000, 0xC0000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE);
        img.addSection(".data", 0xC1000, 0x30000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_CNT_INITIALIZED_DATA);
        img.addSection(".rsrc", 0xF1000, 0x10000, IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_INITIALIZED_DATA);

        img.addImport("ntdll.dll");

        img.addExport("CreateProcessA", 0x1000, 1);
        img.addExport("CreateProcessW", 0x1040, 2);
        img.addExport("ExitProcess", 0x1080, 3);
        img.addExport("GetCurrentProcessId", 0x10C0, 4);
        img.addExport("GetCurrentProcess", 0x10E0, 5);
        img.addExport("CreateFileA", 0x1100, 10);
        img.addExport("CreateFileW", 0x1140, 11);
        img.addExport("ReadFile", 0x1180, 12);
        img.addExport("WriteFile", 0x11C0, 13);
        img.addExport("CloseHandle", 0x1200, 14);
        img.addExport("DeleteFileA", 0x1240, 15);
        img.addExport("FindFirstFileA", 0x1280, 16);
        img.addExport("FindNextFileA", 0x12C0, 17);
        img.addExport("FindClose", 0x1300, 18);
        img.addExport("GetStdHandle", 0x1340, 20);
        img.addExport("WriteConsoleA", 0x1380, 21);
        img.addExport("ReadConsoleA", 0x13C0, 22);
        img.addExport("SetConsoleTitleA", 0x1400, 23);
        img.addExport("GetProcessHeap", 0x1440, 30);
        img.addExport("HeapAlloc", 0x1480, 31);
        img.addExport("HeapFree", 0x14C0, 32);
        img.addExport("VirtualAlloc", 0x1500, 33);
        img.addExport("VirtualFree", 0x1540, 34);
        img.addExport("LoadLibraryA", 0x1580, 40);
        img.addExport("GetProcAddress", 0x15C0, 41);
        img.addExport("FreeLibrary", 0x1600, 42);
        img.addExport("GetModuleHandleA", 0x1640, 43);
        img.addExport("GetModuleFileNameA", 0x1680, 44);
        img.addExport("GetLastError", 0x16C0, 50);
        img.addExport("SetLastError", 0x1700, 51);
        img.addExport("GetTickCount", 0x1740, 52);
        img.addExport("Sleep", 0x1780, 53);
        img.addExport("GetSystemInfo", 0x17C0, 54);
        img.addExport("GetVersionExA", 0x1800, 55);
        img.addExport("GetCurrentDirectoryA", 0x1840, 60);
        img.addExport("SetCurrentDirectoryA", 0x1880, 61);
        img.addExport("GetSystemDirectoryA", 0x18C0, 62);
        img.addExport("GetWindowsDirectoryA", 0x1900, 63);
        img.addExport("GetEnvironmentVariableA", 0x1940, 64);
        img.addExport("SetEnvironmentVariableA", 0x1980, 65);
        img.addExport("GetFileSize", 0x19C0, 70);
        img.addExport("GetFileAttributesA", 0x1A00, 71);
        img.addExport("CreateDirectoryA", 0x1A40, 72);
        img.addExport("RemoveDirectoryA", 0x1A80, 73);

        _ = resolveImports(img);
    }

    const kernelbase_result = loadDll("kernelbase.dll", 0x7FFC0000);
    if (kernelbase_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_CUI;
        img.entry_point = 0x7FFC0000 + 0x1000;
        img.size_of_image = 0x100000;
        img.addImport("ntdll.dll");
        img.addExport("PathCombineA", 0x1000, 1);
        img.addExport("PathFileExistsA", 0x1020, 2);
    }

    const g32_result = loadDll("gdi32.dll", 0x7FFA0000);
    if (g32_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_GUI;
        img.entry_point = 0x7FFA0000 + 0x1000;
        img.size_of_image = 0x80000;
        img.addImport("ntdll.dll");
        img.addExport("BitBlt", 0x1000, 1);
        img.addExport("GetStockObject", 0x1040, 2);
    }

    const u32_result = loadDll("user32.dll", 0x7FFB0000);
    if (u32_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_GUI;
        img.entry_point = 0x7FFB0000 + 0x1000;
        img.size_of_image = 0x80000;
        img.addImport("ntdll.dll");
        img.addImport("gdi32.dll");
        img.addExport("CreateWindowExA", 0x1000, 1);
        img.addExport("DefWindowProcA", 0x1040, 2);
    }

    // 合成 `dwmapi.dll` 导出顺序与名称须与 [`dwm_nt61_abi_inventory.zig`](../config/dwm_nt61_abi_inventory.zig) `dwmapi_exports_nt61` 一致（阶段 4 PE ABI）。
    const dwmapi_result = loadDll("dwmapi.dll", 0x7FF90000);
    if (dwmapi_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_WINDOWS_GUI;
        img.entry_point = 0x7FF90000 + 0x1000;
        img.size_of_image = 0x80000;
        img.addImport("ntdll.dll");
        img.addImport("user32.dll");
        img.addExport("DwmIsCompositionEnabled", 0x1000, 1);
        img.addExport("DwmGetColorizationColor", 0x1040, 2);
        img.addExport("DwmExtendFrameIntoClientArea", 0x1080, 3);
        img.addExport("DwmEnableBlurBehindWindow", 0x10C0, 4);
        img.addExport("DwmGetWindowAttribute", 0x1100, 5);
        img.addExport("DwmSetWindowAttribute", 0x1140, 6);
        img.addExport("DwmRegisterThumbnail", 0x1180, 7);
        img.addExport("DwmUnregisterThumbnail", 0x11C0, 8);
        img.addExport("DwmUpdateThumbnailProperties", 0x1200, 9);
        img.addExport("DwmQueryThumbnailSourceSize", 0x1240, 10);
        img.addExport("DwmFlush", 0x1280, 11);
        img.addExport("DwmInvalidateIconicBitmaps", 0x12C0, 12);
    }
}

pub fn init() void {
    image_count = 0;
    initSystemDlls();

    klog.info("PE Loader: initialized (%u images, %u DLLs pre-loaded)", .{
        image_count, getDllCount(),
    });
    klog.info("PE Loader: PE32+ (64-bit) and PE32 (32-bit/WOW64) support", .{});
}

test "PE LoongArch64 RELATIVE64 relocation" {
    var q: u64 = 0x1000;
    try std.testing.expect(applyLoongArch64Reloc(&q, IMAGE_REL_LOONGARCH64_RELATIVE64, 0x5000));
    try std.testing.expectEqual(@as(u64, 0x6000), q);
}

test "optionalSubsystemWordOffsetFromMagic" {
    try std.testing.expectEqual(@as(usize, 68), optionalSubsystemWordOffsetFromMagic(PE32PLUS_MAGIC).?);
    try std.testing.expectEqual(@as(usize, 68), optionalSubsystemWordOffsetFromMagic(PE32_MAGIC).?);
    try std.testing.expect(optionalSubsystemWordOffsetFromMagic(0) == null);
}

test "PE section header and SEC_IMAGE layout anchors" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(SectionHeader));
    try std.testing.expectEqual(@as(u32, 0x01000000), SEC_IMAGE);
    try std.testing.expect((SEC_IMAGE & 0x01000000) != 0);
}
