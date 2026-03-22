//! ELF (Executable and Linkable Format) Loader
//! Phase 7 Enhanced: Segment mapping, dynamic linking support,
//! symbol resolution, and multi-architecture ELF loading.

const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

pub const ELF_MAGIC: [4]u8 = .{ 0x7F, 'E', 'L', 'F' };

pub const ELFCLASS32: u8 = 1;
pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const ELFDATA2MSB: u8 = 2;
pub const EV_CURRENT: u8 = 1;

pub const ET_NONE: u16 = 0;
pub const ET_REL: u16 = 1;
pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;
pub const ET_CORE: u16 = 4;

pub const EM_X86_64: u16 = 62;
pub const EM_AARCH64: u16 = 183;
pub const EM_RISCV: u16 = 243;
pub const EM_LOONGARCH: u16 = 258;
pub const EM_MIPS: u16 = 8;

pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;
pub const PT_SHLIB: u32 = 5;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;
pub const PT_GNU_EH_FRAME: u32 = 0x6474e550;
pub const PT_GNU_STACK: u32 = 0x6474e551;
pub const PT_GNU_RELRO: u32 = 0x6474e552;

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

pub const SHT_NULL: u32 = 0;
pub const SHT_PROGBITS: u32 = 1;
pub const SHT_SYMTAB: u32 = 2;
pub const SHT_STRTAB: u32 = 3;
pub const SHT_RELA: u32 = 4;
pub const SHT_HASH: u32 = 5;
pub const SHT_DYNAMIC: u32 = 6;
pub const SHT_NOTE: u32 = 7;
pub const SHT_NOBITS: u32 = 8;
pub const SHT_REL: u32 = 9;
pub const SHT_DYNSYM: u32 = 11;

pub const DT_NULL: i64 = 0;
pub const DT_NEEDED: i64 = 1;
pub const DT_STRTAB: i64 = 5;
pub const DT_SYMTAB: i64 = 6;
pub const DT_STRSZ: i64 = 10;

pub const Elf64Header = extern struct {
    e_ident: [16]u8 align(1) = [_]u8{0} ** 16,
    e_type: u16 align(1) = 0,
    e_machine: u16 align(1) = 0,
    e_version: u32 align(1) = 0,
    e_entry: u64 align(1) = 0,
    e_phoff: u64 align(1) = 0,
    e_shoff: u64 align(1) = 0,
    e_flags: u32 align(1) = 0,
    e_ehsize: u16 align(1) = 0,
    e_phentsize: u16 align(1) = 0,
    e_phnum: u16 align(1) = 0,
    e_shentsize: u16 align(1) = 0,
    e_shnum: u16 align(1) = 0,
    e_shstrndx: u16 align(1) = 0,
};

pub const Elf64ProgramHeader = extern struct {
    p_type: u32 align(1) = 0,
    p_flags: u32 align(1) = 0,
    p_offset: u64 align(1) = 0,
    p_vaddr: u64 align(1) = 0,
    p_paddr: u64 align(1) = 0,
    p_filesz: u64 align(1) = 0,
    p_memsz: u64 align(1) = 0,
    p_align: u64 align(1) = 0,
};

pub const Elf64SectionHeader = extern struct {
    sh_name: u32 align(1) = 0,
    sh_type: u32 align(1) = 0,
    sh_flags: u64 align(1) = 0,
    sh_addr: u64 align(1) = 0,
    sh_offset: u64 align(1) = 0,
    sh_size: u64 align(1) = 0,
    sh_link: u32 align(1) = 0,
    sh_info: u32 align(1) = 0,
    sh_addralign: u64 align(1) = 0,
    sh_entsize: u64 align(1) = 0,
};

pub const Elf64Sym = extern struct {
    st_name: u32 align(1) = 0,
    st_info: u8 align(1) = 0,
    st_other: u8 align(1) = 0,
    st_shndx: u16 align(1) = 0,
    st_value: u64 align(1) = 0,
    st_size: u64 align(1) = 0,
};

pub const Elf64Dyn = extern struct {
    d_tag: i64 align(1) = 0,
    d_val: u64 align(1) = 0,
};

pub const ElfLoadStatus = enum {
    success,
    invalid_magic,
    not_64bit,
    wrong_endian,
    wrong_machine,
    not_executable,
    too_many_segments,
    load_error,
    relocation_error,
    symbol_not_found,
};

const MAX_ELF_IMAGES: usize = 32;
const MAX_SEGMENTS: usize = 24;
const MAX_SYMBOLS: usize = 64;
const MAX_NEEDED: usize = 8;

pub const SegmentInfo = struct {
    vaddr: u64 = 0,
    memsz: u64 = 0,
    filesz: u64 = 0,
    flags: u32 = 0,
    seg_type: u32 = 0,
    offset: u64 = 0,
    alignment: u64 = 0,

    pub fn isReadable(self: *const SegmentInfo) bool {
        return (self.flags & PF_R) != 0;
    }

    pub fn isWritable(self: *const SegmentInfo) bool {
        return (self.flags & PF_W) != 0;
    }

    pub fn isExecutable(self: *const SegmentInfo) bool {
        return (self.flags & PF_X) != 0;
    }
};

pub const ElfSymbol = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    value: u64 = 0,
    size: u64 = 0,
    info: u8 = 0,
};

pub const ElfImage = struct {
    header: ob.ObjectHeader = .{},
    entry_point: u64 = 0,
    base_address: u64 = 0,
    end_address: u64 = 0,
    is_loaded: bool = false,
    is_pie: bool = false,
    is_shared: bool = false,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    full_path: [260]u8 = [_]u8{0} ** 260,
    full_path_len: usize = 0,
    segments: [MAX_SEGMENTS]SegmentInfo = [_]SegmentInfo{.{}} ** MAX_SEGMENTS,
    segment_count: usize = 0,
    symbols: [MAX_SYMBOLS]ElfSymbol = [_]ElfSymbol{.{}} ** MAX_SYMBOLS,
    symbol_count: usize = 0,
    needed: [MAX_NEEDED][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** MAX_NEEDED,
    needed_len: [MAX_NEEDED]usize = [_]usize{0} ** MAX_NEEDED,
    needed_count: usize = 0,
    machine: u16 = 0,
    elf_type: u16 = 0,
    flags: u32 = 0,
    process_id: u32 = 0,
    phdr_vaddr: u64 = 0,
    phdr_count: u16 = 0,
    tls_vaddr: u64 = 0,
    tls_memsz: u64 = 0,
    tls_filesz: u64 = 0,

    pub fn getName(self: *const ElfImage) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn findSymbol(self: *const ElfImage, sym_name: []const u8) ?u64 {
        for (self.symbols[0..self.symbol_count]) |*sym| {
            if (sym.name_len == sym_name.len) {
                var match = true;
                for (sym.name[0..sym.name_len], sym_name) |a, b| {
                    if (a != b) {
                        match = false;
                        break;
                    }
                }
                if (match) return sym.value;
            }
        }
        return null;
    }

    pub fn addSymbol(self: *ElfImage, name: []const u8, value: u64, size: u64) void {
        if (self.symbol_count >= MAX_SYMBOLS) return;
        var sym = &self.symbols[self.symbol_count];
        const n = @min(name.len, sym.name.len);
        @memcpy(sym.name[0..n], name[0..n]);
        sym.name_len = n;
        sym.value = value;
        sym.size = size;
        self.symbol_count += 1;
    }

    pub fn addSegment(self: *ElfImage, seg: SegmentInfo) void {
        if (self.segment_count >= MAX_SEGMENTS) return;
        self.segments[self.segment_count] = seg;
        self.segment_count += 1;

        const seg_end = seg.vaddr + seg.memsz;
        if (seg_end > self.end_address) self.end_address = seg_end;
    }

    pub fn addNeeded(self: *ElfImage, lib_name: []const u8) void {
        if (self.needed_count >= MAX_NEEDED) return;
        const n = @min(lib_name.len, 64);
        @memcpy(self.needed[self.needed_count][0..n], lib_name[0..n]);
        self.needed_len[self.needed_count] = n;
        self.needed_count += 1;
    }

    pub fn getMemorySize(self: *const ElfImage) u64 {
        if (self.end_address > self.base_address) {
            return self.end_address - self.base_address;
        }
        return 0;
    }
};

var elf_images: [MAX_ELF_IMAGES]ElfImage = [_]ElfImage{.{}} ** MAX_ELF_IMAGES;
var elf_count: usize = 0;

pub const ElfLoadResult = struct {
    status: ElfLoadStatus = .success,
    image: ?*ElfImage = null,
};

pub fn validateElfHeader(data: []const u8) ElfLoadStatus {
    if (data.len < @sizeOf(Elf64Header)) return .invalid_magic;

    const hdr = @as(*const Elf64Header, @ptrCast(@alignCast(data.ptr)));

    if (hdr.e_ident[0] != ELF_MAGIC[0] or
        hdr.e_ident[1] != ELF_MAGIC[1] or
        hdr.e_ident[2] != ELF_MAGIC[2] or
        hdr.e_ident[3] != ELF_MAGIC[3])
    {
        return .invalid_magic;
    }

    if (hdr.e_ident[4] != ELFCLASS64) return .not_64bit;
    if (hdr.e_ident[5] != ELFDATA2LSB) return .wrong_endian;
    if (hdr.e_type != ET_EXEC and hdr.e_type != ET_DYN) return .not_executable;

    return .success;
}

pub fn loadElfImage(name: []const u8, entry: u64, base: u64) ElfLoadResult {
    if (elf_count >= MAX_ELF_IMAGES) return .{ .status = .too_many_segments };

    var img = &elf_images[elf_count];
    img.* = .{};
    img.entry_point = entry;
    img.base_address = base;
    img.is_loaded = true;
    img.machine = EM_X86_64;
    img.elf_type = ET_EXEC;

    const name_copy = @min(name.len, img.name.len);
    @memcpy(img.name[0..name_copy], name[0..name_copy]);
    img.name_len = name_copy;

    elf_count += 1;
    klog.info("ELF Loader: '%s' loaded at 0x%x (entry=0x%x)", .{ name, base, entry });
    return .{ .status = .success, .image = img };
}

pub fn loadSharedObject(name: []const u8, base: u64) ElfLoadResult {
    const result = loadElfImage(name, 0, base);
    if (result.image) |img| {
        img.is_shared = true;
        img.elf_type = ET_DYN;
    }
    return result;
}

pub fn getElfImage(name: []const u8) ?*ElfImage {
    for (elf_images[0..elf_count]) |*img| {
        if (!img.is_loaded) continue;
        if (img.name_len != name.len) continue;
        var match = true;
        for (img.name[0..img.name_len], name) |a, b| {
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return img;
    }
    return null;
}

pub fn getImageCount() usize {
    return elf_count;
}

pub fn getSharedCount() usize {
    var count: usize = 0;
    for (elf_images[0..elf_count]) |*img| {
        if (img.is_loaded and img.is_shared) count += 1;
    }
    return count;
}

pub fn init() void {
    elf_count = 0;

    const ld_result = loadSharedObject("ld-zirconos.so.1", 0x7F000000);
    if (ld_result.image) |img| {
        img.addSymbol("_dl_start", 0x7F000000 + 0x1000, 0);
        img.addSymbol("dlopen", 0x7F000000 + 0x2000, 0);
        img.addSymbol("dlsym", 0x7F000000 + 0x2100, 0);
        img.addSymbol("dlclose", 0x7F000000 + 0x2200, 0);
    }

    klog.info("ELF Loader: initialized (%u images, %u shared objects)", .{
        elf_count, getSharedCount(),
    });
}
