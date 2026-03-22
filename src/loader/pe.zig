//! PE32/PE32+ (Portable Executable) Loader
//! Phase 7-11 Enhanced: DLL loading, import resolution, relocation,
//! section mapping, process context (PEB/TEB), image management,
//! and PE32 (32-bit) support for WOW64 compatibility.

const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

pub const PE_SIGNATURE: u32 = 0x00004550;
pub const PE32_MAGIC: u16 = 0x10B;
pub const PE32PLUS_MAGIC: u16 = 0x20B;

pub const IMAGE_FILE_EXECUTABLE_IMAGE: u16 = 0x0002;
pub const IMAGE_FILE_LARGE_ADDRESS_AWARE: u16 = 0x0020;
pub const IMAGE_FILE_DLL: u16 = 0x2000;

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

pub const IMAGE_REL_BASED_ABSOLUTE: u16 = 0;
pub const IMAGE_REL_BASED_HIGH: u16 = 1;
pub const IMAGE_REL_BASED_LOW: u16 = 2;
pub const IMAGE_REL_BASED_HIGHLOW: u16 = 3;
pub const IMAGE_REL_BASED_DIR64: u16 = 10;

pub const IMAGE_FILE_MACHINE_I386: u16 = 0x014C;
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
pub const IMAGE_FILE_MACHINE_ARM64: u16 = 0xAA64;

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
        if (img.is_loaded and img.machine == IMAGE_FILE_MACHINE_AMD64) count += 1;
    }
    return count;
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
    const ntdll_result = loadDll("ntdll.dll", 0x7FFE0000);
    if (ntdll_result.image) |img| {
        img.subsystem = IMAGE_SUBSYSTEM_NATIVE;
        img.entry_point = 0x7FFE0000 + 0x1000;
        img.size_of_image = 0x1A0000;
        img.addSection(".text", 0x1000, 0x100000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE);
        img.addSection(".data", 0x101000, 0x20000, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_CNT_INITIALIZED_DATA);
        img.addSection(".rsrc", 0x121000, 0x10000, IMAGE_SCN_MEM_READ | IMAGE_SCN_CNT_INITIALIZED_DATA);

        img.addExport("NtCreateProcess", 0x1000, 1);
        img.addExport("NtTerminateProcess", 0x1020, 2);
        img.addExport("NtCreateThread", 0x1040, 3);
        img.addExport("NtCreateFile", 0x1060, 4);
        img.addExport("NtReadFile", 0x1080, 5);
        img.addExport("NtWriteFile", 0x10A0, 6);
        img.addExport("NtClose", 0x10C0, 7);
        img.addExport("NtCreatePort", 0x10E0, 8);
        img.addExport("NtRequestWaitReplyPort", 0x1100, 9);
        img.addExport("NtAllocateVirtualMemory", 0x1120, 10);
        img.addExport("NtFreeVirtualMemory", 0x1140, 11);
        img.addExport("NtQuerySystemInformation", 0x1160, 12);
        img.addExport("NtQueryInformationProcess", 0x1180, 13);
        img.addExport("NtSetInformationProcess", 0x11A0, 14);
        img.addExport("NtOpenFile", 0x11C0, 15);
        img.addExport("NtCreateEvent", 0x11E0, 16);
        img.addExport("NtWaitForSingleObject", 0x1200, 17);
        img.addExport("RtlInitUnicodeString", 0x2000, 100);
        img.addExport("RtlCopyMemory", 0x2020, 101);
        img.addExport("RtlZeroMemory", 0x2040, 102);
        img.addExport("RtlGetVersion", 0x2060, 103);
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
}

pub fn init() void {
    image_count = 0;
    initSystemDlls();

    klog.info("PE Loader: initialized (%u images, %u DLLs pre-loaded)", .{
        image_count, getDllCount(),
    });
    klog.info("PE Loader: PE32+ (64-bit) and PE32 (32-bit/WOW64) support", .{});
}
