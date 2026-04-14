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

//! ZirconOS Boot Configuration Data (BCD)
//!
//! Modeled after Windows Boot Configuration Data store.
//! BCD is a firmware-independent database for boot-time configuration.
//!
//! Structure:
//!   BCD Store → BCD Objects → BCD Elements
//!
//! Object types:
//!   - Application (bootmgr, osloader, resume, etc.)
//!   - Inherited (settings shared across objects)
//!   - Device (disk/partition/file references)
//!
//! This is an in-memory representation used by both BIOS and UEFI paths.

const std = @import("std");

pub const BCD_MAGIC: u32 = 0x42434430; // 'BCD0'
pub const BCD_VERSION: u16 = 0x0100;

// ── BCD Object Types ──

pub const ObjectType = enum(u32) {
    application = 0x10100001,
    inherited = 0x10200001,
    device = 0x10300001,
    boot_manager = 0x10100002,
    os_loader = 0x10200002,
    resume_loader = 0x10200003,
    memory_tester = 0x10200004,
    _,
};

// ── BCD Element Types ──

pub const ElementType = enum(u32) {
    // Application elements
    device = 0x11000001,
    path = 0x12000002,
    description = 0x12000004,
    locale = 0x12000005,
    inherit = 0x14000006,
    truncate_memory = 0x15000007,
    recovery_sequence = 0x14000008,
    recovery_enabled = 0x16000009,
    display_order = 0x24000001,
    boot_sequence = 0x24000002,
    default_object = 0x23000003,
    timeout = 0x25000004,
    resume_object = 0x23000006,
    tools_display_order = 0x24000010,

    // OS Loader elements
    os_device = 0x21000001,
    system_root = 0x22000002,
    associated_resume = 0x23000003,
    detect_hal = 0x26000010,
    kernel_path = 0x22000013,
    debug_transport = 0x25000020,
    debug_port = 0x25000021,
    debug_baudrate = 0x25000022,

    // Boot environment
    graphics_mode = 0x25000040,
    no_integrity_checks = 0x26000048,
    test_signing = 0x26000049,
    safe_boot = 0x25000080,
    safe_boot_alt_shell = 0x26000081,
    nx_policy = 0x25000020,

    // Display
    graphics_resolution = 0x25000050,
    boot_ux_policy = 0x25000065,

    _,
};

// ── Boot Mode ──

pub const BootMode = enum(u8) {
    normal = 0,
    debug = 1,
    safe_mode = 2,
    safe_mode_networking = 3,
    safe_mode_cmdprompt = 4,
    recovery = 5,
    last_known_good = 6,
};

// ── Partition Type ──

pub const PartitionScheme = enum(u8) {
    mbr = 0,
    gpt = 1,
};

// ── Device Descriptor ──

pub const DeviceDescriptor = struct {
    partition_scheme: PartitionScheme,
    disk_number: u8,
    partition_number: u8,

    // MBR-specific
    mbr_signature: u32,

    // GPT-specific
    gpt_partition_guid: [16]u8,

    pub fn isMbr(self: DeviceDescriptor) bool {
        return self.partition_scheme == .mbr;
    }

    pub fn isGpt(self: DeviceDescriptor) bool {
        return self.partition_scheme == .gpt;
    }
};

// ── BCD Element ──

pub const BcdElement = struct {
    element_type: ElementType,
    data_type: DataType,
    data: ElementData,

    pub const DataType = enum(u8) {
        integer = 1,
        boolean = 2,
        string = 3,
        object_ref = 4,
        object_list = 5,
        device = 6,
    };

    pub const ElementData = union {
        integer: u64,
        boolean: bool,
        string: [128]u8,
        device: DeviceDescriptor,
    };
};

// ── BCD Object ──

pub const MAX_ELEMENTS: usize = 16;

pub const BcdObject = struct {
    object_type: ObjectType,
    identifier: [16]u8, // GUID
    description: [64]u8,
    element_count: usize,
    elements: [MAX_ELEMENTS]BcdElement,

    pub fn getDescription(self: *const BcdObject) []const u8 {
        var len: usize = 0;
        while (len < self.description.len and self.description[len] != 0) : (len += 1) {}
        return self.description[0..len];
    }

    pub fn findElement(self: *const BcdObject, elem_type: ElementType) ?*const BcdElement {
        for (self.elements[0..self.element_count]) |*elem| {
            if (elem.element_type == elem_type) return elem;
        }
        return null;
    }
};

// ── BCD Store ──

pub const MAX_OBJECTS: usize = 16;

pub const BcdStore = struct {
    magic: u32,
    version: u16,
    object_count: usize,
    objects: [MAX_OBJECTS]BcdObject,
    default_index: usize,
    timeout_seconds: u32,

    pub fn init() BcdStore {
        var store = BcdStore{
            .magic = BCD_MAGIC,
            .version = BCD_VERSION,
            .object_count = 0,
            .objects = undefined,
            .default_index = 0,
            .timeout_seconds = 10,
        };
        // 默认情况下使用内置默认条目
        store.populateDefaultEntries();
        return store;
    }

    /// 初始化并尝试从文件加载配置（UEFI 路径使用）
    /// 如果文件加载失败，使用默认配置
    pub fn initWithFileLoad(comptime RootType: type) fn (root: *RootType) BcdStore {
        return struct {
            fn initFn(root: *RootType) BcdStore {
                var store = BcdStore{
                    .magic = BCD_MAGIC,
                    .version = BCD_VERSION,
                    .object_count = 0,
                    .objects = undefined,
                    .default_index = 0,
                    .timeout_seconds = 10,
                };
                // 默认配置
                store.populateDefaultEntries();
                // 尝试从文件加载
                if (loadFromFile(&store, root)) {
                    // 成功从文件加载
                }
                return store;
            }
        }.initFn;
    }

    fn populateDefaultEntries(self: *BcdStore) void {
        // Entry 0: ZirconOS Normal Boot
        self.addOsLoaderEntry(
            "ZirconOS v1.0",
            .normal,
            "console=serial,vga debug=0",
        );

        // Entry 1: Debug Mode
        self.addOsLoaderEntry(
            "ZirconOS v1.0 [Debug Mode]",
            .debug,
            "console=serial,vga debug=1 verbose=1",
        );

        // Entry 2: Safe Mode
        self.addOsLoaderEntry(
            "ZirconOS v1.0 [Safe Mode]",
            .safe_mode,
            "safe_mode=1 debug=0 minimal=1",
        );

        // Entry 3: Safe Mode with Networking
        self.addOsLoaderEntry(
            "ZirconOS v1.0 [Safe Mode with Networking]",
            .safe_mode_networking,
            "safe_mode=1 debug=0 network=1",
        );

        // Entry 4: Recovery Console
        self.addOsLoaderEntry(
            "ZirconOS v1.0 [Recovery Console]",
            .recovery,
            "recovery=1 console=serial,vga debug=1",
        );

        // Entry 5: Last Known Good Configuration
        self.addOsLoaderEntry(
            "ZirconOS v1.0 [Last Known Good Configuration]",
            .last_known_good,
            "lastknowngood=1",
        );
    }

    fn addOsLoaderEntry(
        self: *BcdStore,
        description: []const u8,
        mode: BootMode,
        cmdline: []const u8,
    ) void {
        if (self.object_count >= MAX_OBJECTS) return;

        var obj = &self.objects[self.object_count];
        obj.object_type = .os_loader;
        obj.element_count = 0;
        obj.identifier = [_]u8{0} ** 16;
        obj.description = [_]u8{0} ** 64;

        const copy_len = if (description.len < 64) description.len else 63;
        for (0..copy_len) |i| {
            obj.description[i] = description[i];
        }

        // Path element
        if (obj.element_count < MAX_ELEMENTS) {
            var elem = &obj.elements[obj.element_count];
            elem.element_type = .path;
            elem.data_type = .string;
            elem.data = .{ .string = [_]u8{0} ** 128 };
            const path = "/boot/kernel.elf";
            for (path, 0..) |c, i| {
                elem.data.string[i] = c;
            }
            obj.element_count += 1;
        }

        // Boot mode element
        if (obj.element_count < MAX_ELEMENTS) {
            var elem = &obj.elements[obj.element_count];
            elem.element_type = .safe_boot;
            elem.data_type = .integer;
            elem.data = .{ .integer = @intFromEnum(mode) };
            obj.element_count += 1;
        }

        // Command line element
        if (obj.element_count < MAX_ELEMENTS) {
            var elem = &obj.elements[obj.element_count];
            elem.element_type = .kernel_path;
            elem.data_type = .string;
            elem.data = .{ .string = [_]u8{0} ** 128 };
            const copy_cmd = if (cmdline.len < 128) cmdline.len else 127;
            for (0..copy_cmd) |i| {
                elem.data.string[i] = cmdline[i];
            }
            obj.element_count += 1;
        }

        self.object_count += 1;
    }

    pub fn getDefaultEntry(self: *const BcdStore) ?*const BcdObject {
        if (self.default_index < self.object_count) {
            return &self.objects[self.default_index];
        }
        return null;
    }

    pub fn getEntry(self: *const BcdStore, index: usize) ?*const BcdObject {
        if (index < self.object_count) {
            return &self.objects[index];
        }
        return null;
    }

    pub fn getBootMode(self: *const BcdStore, index: usize) BootMode {
        if (self.getEntry(index)) |obj| {
            if (obj.findElement(.safe_boot)) |elem| {
                return @enumFromInt(@as(u8, @truncate(elem.data.integer)));
            }
        }
        return .normal;
    }

    pub fn getCommandLine(self: *const BcdStore, index: usize) []const u8 {
        if (self.getEntry(index)) |obj| {
            if (obj.findElement(.kernel_path)) |elem| {
                var len: usize = 0;
                while (len < 128 and elem.data.string[len] != 0) : (len += 1) {}
                return elem.data.string[0..len];
            }
        }
        return "console=serial,vga debug=0";
    }
};

// ── BCD 持久化存储 ──

/// BCD 文件头（用于持久化存储）
const BcdFileHeader = packed struct {
    magic: u32,
    version: u16,
    reserved: u16,
    checksum: u32,
    object_count: u16,
    data_size: u32,
};

/// BCD 持久化签名（用于验证）
const BCD_PERSIST_MAGIC: u32 = 0x42434450; // 'BCDP'

/// 计算 BCD 数据的简单校验和
fn calculateBcdChecksum(data: []const u8) u32 {
    var sum: u32 = 0;
    for (data) |byte| {
        sum = sum +% @as(u32, byte);
    }
    return sum;
}

/// 从 UEFI 文件系统加载 BCD 配置
/// 返回 true 表示成功加载，false 表示使用默认配置
pub fn loadFromFile(
    store: *BcdStore,
    root: anytype,
) bool {
    const BCD_FILE_PATH = "/EFI/ZirconOS/bcd.dat";

    const file = root.open(
        BCD_FILE_PATH,
        .read,
        .{},
    ) catch return false;
    defer { _ = file.close(); }

    // 读取文件头
    var header_buf: [@sizeOf(BcdFileHeader)]u8 align(8) = undefined;
    const header_bytes = file.read(&header_buf) catch return false;
    if (header_bytes < @sizeOf(BcdFileHeader)) return false;

    const header = @as(*const BcdFileHeader, @ptrCast(&header_buf)).*;

    // 验证文件头
    if (header.magic != BCD_PERSIST_MAGIC) return false;
    if (header.version != BCD_VERSION) return false;

    // 读取数据
    const data_size: usize = @intCast(header.data_size);
    const data = file.readAlloc(.loader_data, data_size) catch return false;

    // 验证校验和
    const checksum = calculateBcdChecksum(data);
    if (checksum != header.checksum) return false;

    // 解析数据
    if (!parseBcdData(store, data)) return false;

    return true;
}

/// 解析 BCD 数据
fn parseBcdData(store: *BcdStore, data: []const u8) bool {
    var offset: usize = 0;

    // 解析对象计数
    if (offset + 2 > data.len) return false;
    const obj_count = @as(u16, @bitCast(std.mem.readInt(u16, data[offset..][0..2], .little)));
    offset += 2;

    store.object_count = @min(obj_count, MAX_OBJECTS);

    // 解析每个对象
    var i: usize = 0;
    while (i < store.object_count) : (i += 1) {
        if (offset + 16 > data.len) return false;

        var obj = &store.objects[i];
        obj.* = .{};

        // 解析对象类型
        obj.object_type = @as(ObjectType, @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)));
        offset += 4;

        // 跳过 GUID
        offset += 16;

        // 解析描述
        const desc_len = @min(64, data.len - offset);
        @memcpy(obj.description[0..desc_len], data[offset..][0..desc_len]);
        offset += desc_len;

        // 解析元素计数
        if (offset + 1 > data.len) return false;
        obj.element_count = @as(u8, data[offset]);
        offset += 1;
        obj.element_count = @min(obj.element_count, MAX_ELEMENTS);

        // 解析元素
        var j: usize = 0;
        while (j < obj.element_count) : (j += 1) {
            if (offset + 8 > data.len) break;

            var elem = &obj.elements[j];
            elem.element_type = @as(ElementType, @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)));
            offset += 4;

            elem.data_type = @as(BcdElement.DataType, @bitCast(data[offset]));
            offset += 1;

            // 跳过填充
            offset += 3;

            // 解析数据
            switch (elem.data_type) {
                .integer => {
                    if (offset + 8 > data.len) break;
                    elem.data = .{ .integer = std.mem.readInt(u64, data[offset..][0..8], .little) };
                    offset += 8;
                },
                .boolean => {
                    if (offset + 1 > data.len) break;
                    elem.data = .{ .boolean = data[offset] != 0 };
                    offset += 1;
                },
                .string => {
                    const str_len = @min(128, data.len - offset);
                    @memcpy(elem.data.string[0..str_len], data[offset..][0..str_len]);
                    offset += str_len;
                },
                else => break,
            }
        }
        obj.element_count = j;
    }

    store.object_count = i;
    return true;
}

/// 将 BCD 配置保存到 UEFI 文件系统
/// 返回 true 表示成功保存
pub fn saveToFile(
    store: *const BcdStore,
    root: anytype,
) bool {
    const BCD_FILE_PATH = "/EFI/ZirconOS/bcd.dat";
    const BCD_BACKUP_PATH = "/EFI/ZirconOS/bcd.bak";

    // 先备份旧文件
    _ = root.delete(BCD_BACKUP_PATH);
    _ = root.rename(
        BCD_FILE_PATH,
        BCD_BACKUP_PATH,
    );

    // 序列化 BCD 数据
    var data_buf: [4096]u8 = undefined;
    const data_len = serializeBcdData(store, &data_buf);

    // 写入文件
    const file = root.open(
        BCD_FILE_PATH,
        .write,
        .{ .create = true, .truncate = true },
    ) catch return false;
    defer { _ = file.close(); }

    // 写入文件头
    var header: BcdFileHeader = .{
        .magic = BCD_PERSIST_MAGIC,
        .version = BCD_VERSION,
        .reserved = 0,
        .checksum = calculateBcdChecksum(data_buf[0..data_len]),
        .object_count = @as(u16, @intCast(store.object_count)),
        .data_size = @as(u32, @intCast(data_len)),
    };

    var header_buf: [@sizeOf(BcdFileHeader)]u8 align(8) = undefined;
    @memcpy(header_buf[0..@sizeOf(BcdFileHeader)], @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BcdFileHeader)]);
    file.write(&header_buf) catch return false;

    // 写入数据
    file.write(data_buf[0..data_len]) catch return false;

    return true;
}

/// 序列化 BCD 数据
fn serializeBcdData(store: *const BcdStore, dest: []u8) usize {
    var offset: usize = 0;

    // 写入对象计数
    std.mem.writeInt(u16, dest[offset..][0..2], @as(u16, @intCast(store.object_count)), .little);
    offset += 2;

    // 写入每个对象
    var i: usize = 0;
    while (i < store.object_count) : (i += 1) {
        const obj = &store.objects[i];

        // 写入对象类型
        std.mem.writeInt(u32, dest[offset..][0..4], @intFromEnum(obj.object_type), .little);
        offset += 4;

        // 写入 GUID（全零）
        @memset(dest[offset..][0..16], 0);
        offset += 16;

        // 写入描述
        const desc_len = @min(64, dest.len - offset);
        @memcpy(dest[offset..][0..desc_len], obj.description[0..desc_len]);
        offset += desc_len;

        // 写入元素计数
        if (offset < dest.len) dest[offset] = @as(u8, @intCast(obj.element_count));
        offset += 1;

        // 写入元素
        var j: usize = 0;
        while (j < obj.element_count) : (j += 1) {
            const elem = &obj.elements[j];

            // 检查空间
            if (offset + 8 > dest.len) break;

            std.mem.writeInt(u32, dest[offset..][0..4], @intFromEnum(elem.element_type), .little);
            offset += 4;

            dest[offset] = @intFromEnum(elem.data_type);
            offset += 1;

            // 填充
            dest[offset] = 0;
            dest[offset + 1] = 0;
            dest[offset + 2] = 0;
            offset += 3;

            switch (elem.data_type) {
                .integer => {
                    if (offset + 8 > dest.len) break;
                    std.mem.writeInt(u64, dest[offset..][0..8], elem.data.integer, .little);
                    offset += 8;
                },
                .boolean => {
                    if (offset + 1 > dest.len) break;
                    dest[offset] = if (elem.data.boolean) 1 else 0;
                    offset += 1;
                },
                .string => {
                    const str_len = @min(128, dest.len - offset);
                    @memcpy(dest[offset..][0..str_len], elem.data.string[0..str_len]);
                    offset += str_len;
                },
                else => break,
            }
        }
    }

    return offset;
}
