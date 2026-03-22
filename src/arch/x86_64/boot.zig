//! Multiboot2 header and boot info parsing for x86_64
//! Reference: https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html

pub const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

extern const multiboot2_header: [48]u8;

pub const BootInfoHeader = struct {
    total_size: u32,
    reserved: u32,
};

pub const TagHeader = struct {
    type: u32,
    size: u32,
};

pub const TagType = enum(u32) {
    end = 0,
    cmdline = 1,
    boot_loader_name = 2,
    module = 3,
    basic_meminfo = 4,
    bootdev = 5,
    mmap = 6,
    vbe = 7,
    framebuffer = 8,
    elf_sections = 9,
    apm = 10,
    efi32 = 11,
    efi64 = 12,
    smbios = 13,
    acpi_old = 14,
    acpi_new = 15,
    network = 16,
    efi_mmap = 17,
    efi_bs_not_term = 18,
    efi32_ih = 19,
    efi64_ih = 20,
    load_base_addr = 21,
};

pub const BasicMemInfoTag = struct {
    type: u32,
    size: u32,
    mem_lower: u32,
    mem_upper: u32,
};

pub const MmapEntryType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    nvs = 4,
    bad = 5,
    _,
};

pub const MmapEntry = struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
};

pub const MmapTag = struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

pub const FramebufferInfo = struct {
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8, // 0=indexed, 1=RGB, 2=EGA text
    /// 与 multiboot2 标签字节 30 一致：1=BGR（首字节蓝），0=RGB（首字节红）
    pixel_bgr: u8 = 1,
};

pub const DesktopTheme = enum {
    none,
    aero,
};

pub const BootMode = enum {
    normal,
    cmd,
    powershell,
    desktop,
};

pub const BootInfo = struct {
    mem_lower_kb: u32,
    mem_upper_kb: u32,
    mmap_ptr: [*]const u8,
    mmap_entry_count: usize,
    mmap_entry_size: u32,
    cmdline_ptr: ?[*]const u8 = null,
    cmdline_len: usize = 0,
    boot_mode: BootMode = .normal,
    desktop_theme: DesktopTheme = .none,
    fb_info: ?FramebufferInfo = null,

    pub fn getMmapEntry(self: BootInfo, i: usize) ?MmapEntry {
        if (i >= self.mmap_entry_count or self.mmap_entry_size < 24) return null;
        const ptr = self.mmap_ptr + i * self.mmap_entry_size;
        return @as(*const MmapEntry, @ptrCast(@alignCast(ptr))).*;
    }
};

pub fn parse(_: u32, phys_addr: usize) ?BootInfo {
    const addr = phys_addr & ~@as(usize, 7);
    const header = @as(*const BootInfoHeader, @ptrFromInt(addr));
    if (header.total_size < 8) return null;

    var info: BootInfo = .{
        .mem_lower_kb = 0,
        .mem_upper_kb = 0,
        .mmap_ptr = undefined,
        .mmap_entry_count = 0,
        .mmap_entry_size = 0,
    };

    var offset: usize = 8;
    const total = header.total_size;

    while (offset + 8 <= total) {
        const tag = @as(*const TagHeader, @ptrFromInt(addr + offset));
        const tag_size = @max(tag.size, 8);
        if (offset + tag_size > total) break;

        switch (@as(TagType, @enumFromInt(tag.type))) {
            .end => break,
            .cmdline => {
                const str_start = addr + offset + 8;
                const str_len = tag_size - 8;
                if (str_len > 0) {
                    info.cmdline_ptr = @ptrFromInt(str_start);
                    info.cmdline_len = str_len;
                    const cmdline = @as([*]const u8, @ptrFromInt(str_start))[0..str_len];
                    info.boot_mode = parseCmdlineBootMode(cmdline);
                    info.desktop_theme = parseCmdlineDesktop(cmdline);
                }
            },
            .basic_meminfo => {
                const t = @as(*const BasicMemInfoTag, @ptrFromInt(addr + offset));
                info.mem_lower_kb = t.mem_lower;
                info.mem_upper_kb = t.mem_upper;
            },
            .mmap => {
                const t = @as(*const MmapTag, @ptrFromInt(addr + offset));
                info.mmap_entry_size = t.entry_size;
                const entries_start = addr + offset + 16;
                const entries_len = tag_size - 16;
                info.mmap_entry_count = entries_len / t.entry_size;
                info.mmap_ptr = @ptrFromInt(entries_start);
            },
            .framebuffer => {
                // Read fields at fixed byte offsets to avoid Zig struct layout issues.
                // Multiboot2 framebuffer tag layout (byte offsets from tag start):
                //   0: type(u32) 4: size(u32) 8: addr(u64) 16: pitch(u32)
                //   20: width(u32) 24: height(u32) 28: bpp(u8) 29: fb_type(u8)
                const base = addr + offset;
                const p8 = @as([*]const u8, @ptrFromInt(base));
                const fb_addr_lo = @as(*const u32, @ptrCast(@alignCast(p8 + 8))).*;
                const fb_addr_hi = @as(*const u32, @ptrCast(@alignCast(p8 + 12))).*;
                const fb_pitch = @as(*const u32, @ptrCast(@alignCast(p8 + 16))).*;
                const fb_width = @as(*const u32, @ptrCast(@alignCast(p8 + 20))).*;
                const fb_height = @as(*const u32, @ptrCast(@alignCast(p8 + 24))).*;
                const fb_bpp = p8[28];
                const fb_type_val = p8[29];
                const ext_valid = p8[31] == 0x5A;
                const pixel_bgr: u8 = if (ext_valid) (if (p8[30] != 0) 1 else 0) else 1;
                info.fb_info = .{
                    .addr = @as(u64, fb_addr_hi) << 32 | @as(u64, fb_addr_lo),
                    .pitch = fb_pitch,
                    .width = fb_width,
                    .height = fb_height,
                    .bpp = fb_bpp,
                    .fb_type = fb_type_val,
                    .pixel_bgr = pixel_bgr,
                };
            },
            else => {},
        }
        offset += (tag_size + 7) & ~@as(usize, 7);
    }

    return info;
}

fn parseCmdlineValue(cmdline: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 1 <= cmdline.len) {
        var match = true;
        for (key, 0..) |ch, k| {
            if (cmdline[i + k] != ch) {
                match = false;
                break;
            }
        }
        if (match and cmdline[i + key.len] == '=') {
            const val_start = i + key.len + 1;
            var val_end = val_start;
            while (val_end < cmdline.len and cmdline[val_end] != ' ' and cmdline[val_end] != 0) {
                val_end += 1;
            }
            return cmdline[val_start..val_end];
        }
        i += 1;
    }
    return null;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn parseCmdlineBootMode(cmdline: []const u8) BootMode {
    if (parseCmdlineValue(cmdline, "shell")) |val| {
        if (strEql(val, "cmd")) return .cmd;
        if (strEql(val, "powershell")) return .powershell;
    }
    if (parseCmdlineValue(cmdline, "desktop")) |val| {
        // desktop=none means "no graphical shell" — stay in normal text path, not GUI session.
        if (strEql(val, "none")) return .normal;
        return .desktop;
    }
    return .normal;
}

fn parseCmdlineDesktop(cmdline: []const u8) DesktopTheme {
    if (parseCmdlineValue(cmdline, "desktop")) |val| {
        if (strEql(val, "none")) return .none;
        return .aero;
    }
    return .none;
}
