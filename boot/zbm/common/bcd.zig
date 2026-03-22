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
        store.populateDefaultEntries();
        return store;
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
