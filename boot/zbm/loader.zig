//! ZirconOS Boot Manager — Kernel Image Loader
//!
//! Loads the kernel ELF image from disk into memory and prepares
//! the entry point for execution.
//!
//! Supports:
//!   - ELF64 format (ZirconOS kernel is an ELF64 executable)
//!   - Multiboot2 header detection and validation
//!   - Program header (LOAD segment) parsing and memory mapping
//!   - Entry point extraction
//!
//! The loader operates in two modes:
//!   1. BIOS mode: Uses ATA PIO to read sectors from disk
//!   2. UEFI mode: Uses UEFI Simple File System protocol
//!
//! After loading, control is transferred to the kernel with:
//!   - EAX/RAX = Multiboot2 magic (0x36D76289)
//!   - EBX/RBX = Physical address of Multiboot2 boot info

// ── ELF64 Structures ──

pub const ELF_MAGIC: u32 = 0x464C457F; // "\x7FELF"

pub const ElfClass = enum(u8) {
    none = 0,
    elf32 = 1,
    elf64 = 2,
};

pub const ElfType = enum(u16) {
    none = 0,
    relocatable = 1,
    executable = 2,
    shared = 3,
    core = 4,
    _,
};

pub const ElfMachine = enum(u16) {
    none = 0,
    x86 = 3,
    arm = 40,
    x86_64 = 62,
    aarch64 = 183,
    riscv = 243,
    _,
};

pub const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,

    pub fn isValid(self: *const Elf64Header) bool {
        const magic: u32 = @as(*const u32, @ptrCast(&self.e_ident[0])).*;
        return magic == ELF_MAGIC and
            self.e_ident[4] == @intFromEnum(ElfClass.elf64) and
            self.e_type == @intFromEnum(ElfType.executable);
    }

    pub fn getMachine(self: *const Elf64Header) ElfMachine {
        return @enumFromInt(self.e_machine);
    }
};

pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;
pub const PT_PHDR: u32 = 6;

pub const PF_X: u32 = 0x1; // Execute
pub const PF_W: u32 = 0x2; // Write
pub const PF_R: u32 = 0x4; // Read

pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,

    pub fn isLoad(self: *const Elf64Phdr) bool {
        return self.p_type == PT_LOAD;
    }

    pub fn isExecutable(self: *const Elf64Phdr) bool {
        return (self.p_flags & PF_X) != 0;
    }

    pub fn isWritable(self: *const Elf64Phdr) bool {
        return (self.p_flags & PF_W) != 0;
    }
};

// ── Multiboot2 Header Detection ──

pub const MULTIBOOT2_HEADER_MAGIC: u32 = 0xE85250D6;

pub const Multiboot2Header = extern struct {
    magic: u32,
    architecture: u32,
    header_length: u32,
    checksum: u32,

    pub fn isValid(self: *const Multiboot2Header) bool {
        if (self.magic != MULTIBOOT2_HEADER_MAGIC) return false;
        const sum = self.magic +% self.architecture +% self.header_length +% self.checksum;
        return sum == 0;
    }
};

// ── Kernel Load Result ──

pub const LoadError = enum(u8) {
    success = 0,
    invalid_elf = 1,
    wrong_class = 2,
    wrong_machine = 3,
    no_load_segments = 4,
    memory_overlap = 5,
    disk_read_error = 6,
    file_not_found = 7,
    no_multiboot2 = 8,
};

pub const KernelInfo = struct {
    entry_point: u64,
    load_base: u64,
    load_end: u64,
    bss_end: u64,
    segment_count: u32,
    has_multiboot2: bool,
    machine: ElfMachine,

    pub fn init() KernelInfo {
        return .{
            .entry_point = 0,
            .load_base = 0xFFFFFFFFFFFFFFFF,
            .load_end = 0,
            .bss_end = 0,
            .segment_count = 0,
            .has_multiboot2 = false,
            .machine = .none,
        };
    }

    pub fn getLoadSize(self: *const KernelInfo) u64 {
        if (self.load_end > self.load_base) {
            return self.load_end - self.load_base;
        }
        return 0;
    }

    pub fn getBssSize(self: *const KernelInfo) u64 {
        if (self.bss_end > self.load_end) {
            return self.bss_end - self.load_end;
        }
        return 0;
    }
};

// ── ELF Parsing (from memory buffer) ──

/// Parse an ELF64 header from a buffer and extract kernel info.
/// The buffer must contain at least the ELF header + all program headers.
pub fn parseElfHeader(buffer: [*]const u8, buffer_size: usize) struct { info: KernelInfo, err: LoadError } {
    if (buffer_size < @sizeOf(Elf64Header)) {
        return .{ .info = KernelInfo.init(), .err = .invalid_elf };
    }

    const ehdr: *const Elf64Header = @ptrCast(@alignCast(buffer));

    if (!ehdr.isValid()) {
        return .{ .info = KernelInfo.init(), .err = .invalid_elf };
    }

    if (ehdr.e_ident[4] != @intFromEnum(ElfClass.elf64)) {
        return .{ .info = KernelInfo.init(), .err = .wrong_class };
    }

    var info = KernelInfo.init();
    info.entry_point = ehdr.e_entry;
    info.machine = ehdr.getMachine();

    // Parse program headers
    const phoff: usize = @intCast(ehdr.e_phoff);
    const phentsize: usize = ehdr.e_phentsize;
    const phnum: usize = ehdr.e_phnum;

    if (phoff + phentsize * phnum > buffer_size) {
        return .{ .info = info, .err = .invalid_elf };
    }

    var load_count: u32 = 0;

    for (0..phnum) |i| {
        const ph_offset = phoff + i * phentsize;
        const phdr: *const Elf64Phdr = @ptrCast(@alignCast(&buffer[ph_offset]));

        if (phdr.isLoad()) {
            load_count += 1;

            if (phdr.p_paddr < info.load_base) {
                info.load_base = phdr.p_paddr;
            }

            const seg_end = phdr.p_paddr + phdr.p_filesz;
            if (seg_end > info.load_end) {
                info.load_end = seg_end;
            }

            const bss_end = phdr.p_paddr + phdr.p_memsz;
            if (bss_end > info.bss_end) {
                info.bss_end = bss_end;
            }
        }
    }

    if (load_count == 0) {
        return .{ .info = info, .err = .no_load_segments };
    }

    info.segment_count = load_count;

    // Check for Multiboot2 header in first 32KB
    info.has_multiboot2 = findMultiboot2Header(buffer, if (buffer_size < 32768) buffer_size else 32768);

    return .{ .info = info, .err = .success };
}

/// Load ELF LOAD segments from buffer into physical memory.
/// The buffer contains the full ELF file.
pub fn loadElfSegments(buffer: [*]const u8, buffer_size: usize) LoadError {
    if (buffer_size < @sizeOf(Elf64Header)) return .invalid_elf;

    const ehdr: *const Elf64Header = @ptrCast(@alignCast(buffer));
    if (!ehdr.isValid()) return .invalid_elf;

    const phoff: usize = @intCast(ehdr.e_phoff);
    const phentsize: usize = ehdr.e_phentsize;
    const phnum: usize = ehdr.e_phnum;

    for (0..phnum) |i| {
        const ph_offset = phoff + i * phentsize;
        if (ph_offset + phentsize > buffer_size) return .invalid_elf;

        const phdr: *const Elf64Phdr = @ptrCast(@alignCast(&buffer[ph_offset]));

        if (!phdr.isLoad()) continue;

        const file_off: usize = @intCast(phdr.p_offset);
        const filesz: usize = @intCast(phdr.p_filesz);
        const memsz: usize = @intCast(phdr.p_memsz);
        const paddr: usize = @intCast(phdr.p_paddr);

        if (file_off + filesz > buffer_size) return .invalid_elf;

        // Copy file data to physical address
        const dest: [*]u8 = @ptrFromInt(paddr);
        const src = buffer + file_off;
        for (0..filesz) |j| {
            dest[j] = src[j];
        }

        // Zero BSS (memsz - filesz)
        if (memsz > filesz) {
            for (filesz..memsz) |j| {
                dest[j] = 0;
            }
        }
    }

    return .success;
}

// ── Multiboot2 Header Search ──

fn findMultiboot2Header(buffer: [*]const u8, search_len: usize) bool {
    if (search_len < 16) return false;
    var off: usize = 0;
    while (off + 16 <= search_len) : (off += 8) {
        const magic: u32 = @as(*const u32, @ptrCast(@alignCast(&buffer[off]))).*;
        if (magic == MULTIBOOT2_HEADER_MAGIC) {
            const hdr: *const Multiboot2Header = @ptrCast(@alignCast(&buffer[off]));
            if (hdr.isValid()) return true;
        }
    }
    return false;
}

// ── ATA PIO Disk Read (BIOS protected mode, x86 only) ──

pub const ATA_PRIMARY_IO: u16 = 0x1F0;
pub const ATA_PRIMARY_CTRL: u16 = 0x3F6;

/// Read sectors from disk using ATA PIO mode (28-bit LBA).
/// Used by the BIOS boot path when INT 13h is no longer available.
pub fn ataPioRead(lba: u32, sector_count: u8, buffer: [*]u8) bool {
    const port = ATA_PRIMARY_IO;

    // Wait for drive ready
    if (!ataWaitReady(port)) return false;

    // Select drive + LBA mode + high nibble of LBA
    outb(port + 6, 0xE0 | ((lba >> 24) & 0x0F));
    outb(port + 1, 0x00); // Features
    outb(port + 2, sector_count); // Sector count
    outb(port + 3, @intCast(lba & 0xFF)); // LBA low
    outb(port + 4, @intCast((lba >> 8) & 0xFF)); // LBA mid
    outb(port + 5, @intCast((lba >> 16) & 0xFF)); // LBA high
    outb(port + 7, 0x20); // Command: READ SECTORS

    var buf_offset: usize = 0;
    var remaining = sector_count;

    while (remaining > 0) : (remaining -= 1) {
        if (!ataWaitData(port)) return false;

        // Read 256 words (512 bytes) per sector
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const word = inw(port);
            buffer[buf_offset] = @intCast(word & 0xFF);
            buffer[buf_offset + 1] = @intCast((word >> 8) & 0xFF);
            buf_offset += 2;
        }
    }

    return true;
}

fn ataWaitReady(port: u16) bool {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = inb(port + 7);
        if ((status & 0x80) == 0 and (status & 0x40) != 0) return true;
        if ((status & 0x01) != 0) return false; // Error
    }
    return false;
}

fn ataWaitData(port: u16) bool {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = inb(port + 7);
        if ((status & 0x80) == 0 and (status & 0x08) != 0) return true;
        if ((status & 0x01) != 0) return false;
    }
    return false;
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}
