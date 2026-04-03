//! Multiboot2 boot info parsing for the handoff block built by **ZBM** (UEFI or BIOS stage).
//! Format reference (public spec): https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html

const std = @import("std");

pub const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

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
    fb_type: u8,
    pixel_bgr: u8 = 1,
};

/// GOP 线性帧缓冲占用的 **物理** 页对齐区间；须从可用 RAM 中剔除，避免当作普通页清零。
/// `fb_type == 2`（文本等）返回 `(0,0)`。`page_size` 典型为 4096。
pub fn gopPhysicalReserveRange(fb: FramebufferInfo, page_size: u64) struct { start: u64, end_exclusive: u64 } {
    if (fb.fb_type == 2 or fb.addr == 0) return .{ .start = 0, .end_exclusive = 0 };
    if (page_size == 0 or (page_size & (page_size - 1)) != 0) return .{ .start = 0, .end_exclusive = 0 };
    const ps = page_size;
    const line_bytes = @as(u64, fb.pitch) * @as(u64, fb.height);
    if (line_bytes == 0) {
        const s = fb.addr & ~(ps - 1);
        return .{ .start = s, .end_exclusive = s + ps };
    }
    if (fb.addr > std.math.maxInt(u64) - line_bytes) return .{ .start = 0, .end_exclusive = 0 };
    const end_raw = fb.addr + line_bytes;
    const start = fb.addr & ~(ps - 1);
    const end_excl = (end_raw + ps - 1) & ~(ps - 1);
    if (end_excl < start) return .{ .start = 0, .end_exclusive = 0 };
    return .{ .start = start, .end_exclusive = end_excl };
}

pub const DesktopTheme = enum {
    none,
    aero,
};

pub const BootMode = enum {
    normal,
    cmd,
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
    /// 仅当本结构由 `parseMultiboot2` 完整解析时有效：Multiboot2 信息块占用区间，供帧分配器保留，避免再次对 handoff 指针解引用（UEFI 回退路径下 `info_addr` 可能不可访问）。
    multiboot_handoff_start: usize = 0,
    multiboot_handoff_end_exclusive: usize = 0,
    /// Multiboot2 ACPI 标签（type 14/15）内嵌 RSDP 的**物理地址**（与恒等映射一致）；无标签时为 `0`。
    acpi_rsdp_phys: usize = 0,

    pub fn getMmapEntry(self: BootInfo, i: usize) ?MmapEntry {
        if (i >= self.mmap_entry_count or self.mmap_entry_size < 24) return null;
        const ptr = self.mmap_ptr + i * self.mmap_entry_size;
        return @as(*const MmapEntry, @ptrCast(@alignCast(ptr))).*;
    }
};

/// 解析位于 `phys_addr` 的 Multiboot2 信息结构（8 字节对齐）。
pub fn parseMultiboot2(phys_addr: usize) ?BootInfo {
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

        // 按原始 type 分支，避免未知 tag 经 @enumFromInt 产生未定义行为
        switch (tag.type) {
            0 => break, // end
            1 => {
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
            4 => {
                const t = @as(*const BasicMemInfoTag, @ptrFromInt(addr + offset));
                info.mem_lower_kb = t.mem_lower;
                info.mem_upper_kb = t.mem_upper;
            },
            6 => {
                const t = @as(*const MmapTag, @ptrFromInt(addr + offset));
                const entries_start = addr + offset + 16;
                const entries_len = tag_size -| 16;
                if (t.entry_size >= 24 and entries_len >= t.entry_size) {
                    info.mmap_entry_size = t.entry_size;
                    info.mmap_entry_count = entries_len / t.entry_size;
                    info.mmap_ptr = @ptrFromInt(entries_start);
                }
            },
            8 => {
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
            14, 15 => {
                const body = addr + offset + 8;
                const body_len = tag_size -| 8;
                if (body_len >= 20) {
                    const sig = @as([*]const u8, @ptrFromInt(body))[0..8];
                    if (std.mem.eql(u8, sig, "RSD PTR ")) {
                        info.acpi_rsdp_phys = body;
                    }
                }
            },
            else => {},
        }
        offset += (tag_size + 7) & ~@as(usize, 7);
    }

    {
        var total_sz: usize = @intCast(total);
        if (total_sz < 8) total_sz = 8;
        const max_total: usize = 16 * 1024 * 1024;
        if (total_sz > max_total) total_sz = max_total;
        info.multiboot_handoff_start = addr;
        info.multiboot_handoff_end_exclusive = addr + std.mem.alignForward(usize, total_sz, 4096);
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
    }
    if (parseCmdlineValue(cmdline, "desktop")) |val| {
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

test "gopPhysicalReserveRange 1600x900x32 at 2GiB page aligned" {
    const ps: u64 = 4096;
    const r = gopPhysicalReserveRange(.{
        .addr = 0x8000_0000,
        .pitch = 6400,
        .width = 1600,
        .height = 900,
        .bpp = 32,
        .fb_type = 1,
    }, ps);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), r.start);
    const line = 6400 * 900;
    const expect_end = (0x8000_0000 + line + ps - 1) & ~(ps - 1);
    try std.testing.expectEqual(expect_end, r.end_exclusive);
}

test "gopPhysicalReserveRange text mode yields empty" {
    const r = gopPhysicalReserveRange(.{
        .addr = 0xB8000,
        .pitch = 160,
        .width = 80,
        .height = 25,
        .bpp = 0,
        .fb_type = 2,
    }, 4096);
    try std.testing.expectEqual(@as(u64, 0), r.start);
    try std.testing.expectEqual(@as(u64, 0), r.end_exclusive);
}
