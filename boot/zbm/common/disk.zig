//! ZirconOS Boot Manager — Disk Partition Table Parser
//!
//! Supports both MBR (Master Boot Record) and GPT (GUID Partition Table).
//! Used by the boot manager to locate the system partition and kernel image.
//!
//! GPT Layout:
//!   LBA 0: Protective MBR
//!   LBA 1: GPT Header
//!   LBA 2-33: Partition Entry Array (128 entries max)
//!   ...data partitions...
//!   LBA -33 to -2: Backup Partition Entry Array
//!   LBA -1: Backup GPT Header
//!
//! MBR Layout:
//!   Bytes 0-445: Bootstrap code
//!   Bytes 446-509: Partition table (4 entries × 16 bytes)
//!   Bytes 510-511: Boot signature (0x55AA)

// ── MBR Structures ──

pub const MBR_SIGNATURE: u16 = 0xAA55;
pub const GPT_PROTECTIVE_TYPE: u8 = 0xEE;

pub const MbrPartitionEntry = extern struct {
    status: u8,
    first_chs: [3]u8,
    partition_type: u8,
    last_chs: [3]u8,
    first_lba: u32,
    sector_count: u32,

    pub fn isActive(self: *const MbrPartitionEntry) bool {
        return (self.status & 0x80) != 0;
    }

    pub fn isEmpty(self: *const MbrPartitionEntry) bool {
        return self.partition_type == 0 and self.first_lba == 0;
    }

    pub fn isGptProtective(self: *const MbrPartitionEntry) bool {
        return self.partition_type == GPT_PROTECTIVE_TYPE;
    }

    pub fn getTypeName(self: *const MbrPartitionEntry) []const u8 {
        return switch (self.partition_type) {
            0x00 => "Empty",
            0x01 => "FAT12",
            0x04, 0x06, 0x0E => "FAT16",
            0x05, 0x0F => "Extended",
            0x07 => "NTFS/exFAT",
            0x0B, 0x0C => "FAT32",
            0x11 => "Hidden FAT12",
            0x14, 0x16, 0x1E => "Hidden FAT16",
            0x17 => "Hidden NTFS",
            0x1B, 0x1C => "Hidden FAT32",
            0x27 => "Windows RE",
            0x42 => "Dynamic Disk",
            0x82 => "Linux Swap",
            0x83 => "Linux",
            0x85 => "Linux Extended",
            0x8E => "Linux LVM",
            0xA5 => "FreeBSD",
            0xA6 => "OpenBSD",
            0xA9 => "NetBSD",
            0xEE => "GPT Protective",
            0xEF => "EFI System",
            0xFD => "Linux RAID",
            0xFE => "ZirconOS System",
            else => "Unknown",
        };
    }

    pub fn getSizeInMb(self: *const MbrPartitionEntry) u32 {
        return self.sector_count / 2048; // sectors → MB (512 * 2048 = 1MB)
    }
};

pub const MasterBootRecord = extern struct {
    bootstrap: [446]u8,
    partitions: [4]MbrPartitionEntry,
    signature: u16,

    pub fn isValid(self: *const MasterBootRecord) bool {
        return self.signature == MBR_SIGNATURE;
    }

    pub fn hasGptProtective(self: *const MasterBootRecord) bool {
        for (&self.partitions) |*p| {
            if (p.isGptProtective()) return true;
        }
        return false;
    }

    pub fn findActivePartition(self: *const MasterBootRecord) ?*const MbrPartitionEntry {
        for (&self.partitions) |*p| {
            if (p.isActive() and !p.isEmpty()) return p;
        }
        return null;
    }

    pub fn getPartitionCount(self: *const MasterBootRecord) u32 {
        var count: u32 = 0;
        for (&self.partitions) |*p| {
            if (!p.isEmpty()) count += 1;
        }
        return count;
    }
};

// ── GPT Structures ──

pub const GPT_HEADER_SIGNATURE: u64 = 0x5452415020494645; // "EFI PART"
pub const GPT_REVISION_1_0: u32 = 0x00010000;

pub const GptGuid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(self: *const GptGuid, other: *const GptGuid) bool {
        if (self.data1 != other.data1) return false;
        if (self.data2 != other.data2) return false;
        if (self.data3 != other.data3) return false;
        for (0..8) |i| {
            if (self.data4[i] != other.data4[i]) return false;
        }
        return true;
    }

    pub fn isZero(self: *const GptGuid) bool {
        return self.data1 == 0 and self.data2 == 0 and self.data3 == 0 and
            self.data4[0] == 0 and self.data4[1] == 0 and
            self.data4[2] == 0 and self.data4[3] == 0 and
            self.data4[4] == 0 and self.data4[5] == 0 and
            self.data4[6] == 0 and self.data4[7] == 0;
    }
};

// Well-known GPT partition type GUIDs
pub const GUID_EFI_SYSTEM: GptGuid = .{
    .data1 = 0xC12A7328,
    .data2 = 0xF81F,
    .data3 = 0x11D2,
    .data4 = .{ 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B },
};

pub const GUID_MICROSOFT_BASIC_DATA: GptGuid = .{
    .data1 = 0xEBD0A0A2,
    .data2 = 0xB9E5,
    .data3 = 0x4433,
    .data4 = .{ 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 },
};

pub const GUID_MICROSOFT_RESERVED: GptGuid = .{
    .data1 = 0xE3C9E316,
    .data2 = 0x0B5C,
    .data3 = 0x4DB8,
    .data4 = .{ 0x81, 0x7D, 0xF9, 0x2D, 0xF0, 0x02, 0x15, 0xAE },
};

pub const GUID_WINDOWS_RECOVERY: GptGuid = .{
    .data1 = 0xDE94BBA4,
    .data2 = 0x06D1,
    .data3 = 0x4D40,
    .data4 = .{ 0xA1, 0x6A, 0xBF, 0xD5, 0x01, 0x79, 0xD6, 0xAC },
};

pub const GUID_LINUX_FILESYSTEM: GptGuid = .{
    .data1 = 0x0FC63DAF,
    .data2 = 0x8483,
    .data3 = 0x4772,
    .data4 = .{ 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 },
};

// ZirconOS-specific partition type GUID
pub const GUID_ZIRCONOS_SYSTEM: GptGuid = .{
    .data1 = 0x5A52434E,
    .data2 = 0x4F53,
    .data3 = 0x0001,
    .data4 = .{ 0x5A, 0x49, 0x52, 0x43, 0x4F, 0x4E, 0x4F, 0x53 },
};

pub const GUID_ZIRCONOS_BOOT: GptGuid = .{
    .data1 = 0x5A52434E,
    .data2 = 0x4F53,
    .data3 = 0x0002,
    .data4 = .{ 0x42, 0x4F, 0x4F, 0x54, 0x5A, 0x42, 0x4D, 0x00 },
};

pub const GUID_ZIRCONOS_DATA: GptGuid = .{
    .data1 = 0x5A52434E,
    .data2 = 0x4F53,
    .data3 = 0x0003,
    .data4 = .{ 0x44, 0x41, 0x54, 0x41, 0x5A, 0x42, 0x4D, 0x00 },
};

pub const GptHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    my_lba: u64,
    alternate_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: GptGuid,
    partition_entry_lba: u64,
    number_of_entries: u32,
    entry_size: u32,
    partition_entry_crc32: u32,

    pub fn isValid(self: *const GptHeader) bool {
        return self.signature == GPT_HEADER_SIGNATURE and
            self.header_size >= 92 and
            self.entry_size >= 128;
    }

    pub fn getDiskSizeInMb(self: *const GptHeader) u64 {
        return (self.last_usable_lba - self.first_usable_lba + 1) / 2048;
    }
};

pub const GPT_ATTR_PLATFORM_REQUIRED: u64 = (1 << 0);
pub const GPT_ATTR_EFI_IGNORE: u64 = (1 << 1);
pub const GPT_ATTR_LEGACY_BIOS_BOOTABLE: u64 = (1 << 2);

pub const GptPartitionEntry = extern struct {
    type_guid: GptGuid,
    unique_guid: GptGuid,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    name: [72]u8, // UTF-16LE, 36 chars

    pub fn isEmpty(self: *const GptPartitionEntry) bool {
        return self.type_guid.isZero();
    }

    pub fn getSizeInMb(self: *const GptPartitionEntry) u64 {
        if (self.ending_lba <= self.starting_lba) return 0;
        return (self.ending_lba - self.starting_lba + 1) / 2048;
    }

    pub fn isEfiSystem(self: *const GptPartitionEntry) bool {
        return self.type_guid.eql(&GUID_EFI_SYSTEM);
    }

    pub fn isZirconOSSystem(self: *const GptPartitionEntry) bool {
        return self.type_guid.eql(&GUID_ZIRCONOS_SYSTEM);
    }

    pub fn isZirconOSBoot(self: *const GptPartitionEntry) bool {
        return self.type_guid.eql(&GUID_ZIRCONOS_BOOT);
    }

    pub fn isPlatformRequired(self: *const GptPartitionEntry) bool {
        return (self.attributes & GPT_ATTR_PLATFORM_REQUIRED) != 0;
    }

    pub fn isBiosBootable(self: *const GptPartitionEntry) bool {
        return (self.attributes & GPT_ATTR_LEGACY_BIOS_BOOTABLE) != 0;
    }

    pub fn getTypeName(self: *const GptPartitionEntry) []const u8 {
        if (self.type_guid.eql(&GUID_EFI_SYSTEM)) return "EFI System";
        if (self.type_guid.eql(&GUID_MICROSOFT_BASIC_DATA)) return "Basic Data";
        if (self.type_guid.eql(&GUID_MICROSOFT_RESERVED)) return "Microsoft Reserved";
        if (self.type_guid.eql(&GUID_WINDOWS_RECOVERY)) return "Windows Recovery";
        if (self.type_guid.eql(&GUID_LINUX_FILESYSTEM)) return "Linux Filesystem";
        if (self.type_guid.eql(&GUID_ZIRCONOS_SYSTEM)) return "ZirconOS System";
        if (self.type_guid.eql(&GUID_ZIRCONOS_BOOT)) return "ZirconOS Boot";
        if (self.type_guid.eql(&GUID_ZIRCONOS_DATA)) return "ZirconOS Data";
        return "Unknown";
    }
};

// ── Partition Detection Result ──

pub const MAX_PARTITIONS: usize = 32;

pub const PartitionInfo = struct {
    index: u32,
    start_lba: u64,
    size_sectors: u64,
    is_active: bool,
    type_name: []const u8,

    // Scheme-specific
    scheme: PartitionScheme,
    mbr_type: u8,
    gpt_type_guid: GptGuid,
};

pub const PartitionScheme = enum(u8) {
    unknown = 0,
    mbr = 1,
    gpt = 2,
};

pub const DiskInfo = struct {
    scheme: PartitionScheme,
    partition_count: usize,
    partitions: [MAX_PARTITIONS]PartitionInfo,

    // GPT-specific
    disk_guid: GptGuid,
    total_size_mb: u64,

    // MBR-specific
    mbr_disk_signature: u32,

    pub fn init() DiskInfo {
        return DiskInfo{
            .scheme = .unknown,
            .partition_count = 0,
            .partitions = undefined,
            .disk_guid = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
            .total_size_mb = 0,
            .mbr_disk_signature = 0,
        };
    }

    pub fn findBootPartition(self: *const DiskInfo) ?*const PartitionInfo {
        for (self.partitions[0..self.partition_count]) |*p| {
            if (self.scheme == .gpt) {
                if (p.gpt_type_guid.eql(&GUID_ZIRCONOS_BOOT) or
                    p.gpt_type_guid.eql(&GUID_ZIRCONOS_SYSTEM))
                    return p;
            } else {
                if (p.is_active) return p;
            }
        }
        return null;
    }

    pub fn findEfiSystemPartition(self: *const DiskInfo) ?*const PartitionInfo {
        for (self.partitions[0..self.partition_count]) |*p| {
            if (p.gpt_type_guid.eql(&GUID_EFI_SYSTEM)) return p;
        }
        return null;
    }

    /// Parse an MBR from a raw 512-byte sector buffer
    pub fn parseMbr(self: *DiskInfo, sector: *const [512]u8) bool {
        const mbr: *const MasterBootRecord = @ptrCast(@alignCast(sector));
        if (!mbr.isValid()) return false;

        if (mbr.hasGptProtective()) {
            self.scheme = .gpt;
            return true; // Caller should then parse GPT
        }

        self.scheme = .mbr;
        self.mbr_disk_signature = @as(*const u32, @ptrCast(@alignCast(&sector[440]))).*;
        self.partition_count = 0;

        for (&mbr.partitions, 0..) |*p, i| {
            if (p.isEmpty()) continue;
            if (self.partition_count >= MAX_PARTITIONS) break;

            var info = &self.partitions[self.partition_count];
            info.index = @intCast(i);
            info.start_lba = p.first_lba;
            info.size_sectors = p.sector_count;
            info.is_active = p.isActive();
            info.type_name = p.getTypeName();
            info.scheme = .mbr;
            info.mbr_type = p.partition_type;
            info.gpt_type_guid = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } };

            self.partition_count += 1;
        }

        return true;
    }

    /// Parse GPT header from a raw 512-byte sector (LBA 1)
    pub fn parseGptHeader(self: *DiskInfo, sector: *const [512]u8) bool {
        const header: *const GptHeader = @ptrCast(@alignCast(sector));
        if (!header.isValid()) return false;

        self.scheme = .gpt;
        self.disk_guid = header.disk_guid;
        self.total_size_mb = header.getDiskSizeInMb();

        return true;
    }

    /// Parse a single GPT partition entry (128 bytes)
    pub fn addGptPartition(self: *DiskInfo, entry: *const GptPartitionEntry) bool {
        if (entry.isEmpty()) return false;
        if (self.partition_count >= MAX_PARTITIONS) return false;

        var info = &self.partitions[self.partition_count];
        info.index = @intCast(self.partition_count);
        info.start_lba = entry.starting_lba;
        info.size_sectors = entry.ending_lba - entry.starting_lba + 1;
        info.is_active = entry.isBiosBootable() or entry.isZirconOSBoot();
        info.type_name = entry.getTypeName();
        info.scheme = .gpt;
        info.mbr_type = 0;
        info.gpt_type_guid = entry.type_guid;

        self.partition_count += 1;
        return true;
    }
};
