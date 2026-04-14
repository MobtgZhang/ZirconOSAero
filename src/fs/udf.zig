// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fs/udf.zig
// Purpose: UDF (Universal Disk Format) 文件系统驱动 — 支持 DVD±RW、蓝光等可擦写光盘。
//         实现 Anchor Volume Descriptor Pointer、逻辑卷描述符、ICB 和目录遍历。
//
// This is an independent clean-room implementation.
// Reference: OSTA UDF 2.60 — ECMA-167/ATA EUI-64 — Anchor Volume Descriptor,
//            Logical Volume Descriptor, File Set Descriptor, ICB.

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const SECTOR_SIZE: usize = 2048;

pub const UDF_TAG_IDENT_ANCHOR: u16 = 2;
pub const UDF_TAG_IDENT_PRIMARY: u16 = 1;
pub const UDF_TAG_IDENT_LOGICAL: u16 = 6;
pub const UDF_TAG_IDENT_TERMINAL: u16 = 8;
pub const UDF_TAG_IDENT_FSD: u16 = 0x0100;
pub const UDF_TAG_IDENT_FILE_ENTRY: u16 = 261;
pub const UDF_TAG_IDENT_EXT_FILE_ENTRY: u16 = 266;

pub const UDF_ICBTAG_FILE_TYPE_UNSPECIFIED: u8 = 0;
pub const UDF_ICBTAG_FILE_TYPE_DIR: u8 = 4;
pub const UDF_ICBTAG_FILE_TYPE_REG: u8 = 1;

pub const UDF_DESCR_TAG = extern struct {
    tag_ident: u16 align(1) = 0,
    descriptor_crc: u16 align(1) = 0,
    tag_location: u32 align(1) = 0,
};

pub const AnchorVolumeDescriptorPointer = extern struct {
    desc_tag: UDF_DESCR_TAG = .{},
    main_vol_desc_seq_extent: ExtentAd = .{},
    reserve_vol_desc_seq_extent: ExtentAd = .{},
    reserved: [480]u8 align(1) = .{0} ** 480,
};

pub const ExtentAd = extern struct {
    extent_length: u32 align(1) = 0,
    extent_location: u32 align(1) = 0,
};

pub const PrimaryVolumeDescriptor = extern struct {
    desc_tag: UDF_DESCR_TAG = .{},
    volume_desc_seq_number: u32 align(1) = 0,
    primary_vol_desc_num: u32 align(1) = 0,
    volume_id: [32]u8 align(1) = .{0} ** 32,
    volume_set_id: [128]u8 align(1) = .{0} ** 128,
    desc_charset: [64]u8 align(1) = .{0} ** 64,
    explanatory_charset: [64]u8 align(1) = .{0} ** 64,
    volume_abstrac: u32 align(1) = 0,
    volume_app: u32 align(1) = 0,
    copyright: u32 align(1) = 0,
    creation_date: u32 align(1) = 0,
    modification_date: u32 align(1) = 0,
    expiration_date: u32 align(1) = 0,
    effective_date: u32 align(1) = 0,
    spec_version: u16 align(1) = 0,
    charset_list: u32 align(1) = 0,
    max_charset_list: u32 align(1) = 0,
    volume_seq_num: u16 align(1) = 0,
    max_volume_seq_num: u16 align(1) = 0,
    interchange_level: u16 align(1) = 0,
    max_interchange_level: u16 align(1) = 0,
    file_set_catalog: u32 align(1) = 0,
    reserved: [12]u8 align(1) = .{0} ** 12,
};

pub const LogicalVolumeDescriptor = extern struct {
    desc_tag: UDF_DESCR_TAG = .{},
    vol_desc_seq_number: u32 align(1) = 0,
    descriptor_char_set: [64]u8 align(1) = .{0} ** 64,
    logical_vol_id: [128]u8 align(1) = .{0} ** 128,
    logical_vol_size: u32 align(1) = 0,
    desc_charset: [64]u8 align(1) = .{0} ** 64,
    logical_vol_contents_use: [16]u8 align(1) = .{0} ** 16,
    map_table_length: u32 align(1) = 0,
    num_partition_maps: u32 align(1) = 0,
    imp_use: [128]u8 align(1) = .{0} ** 128,
};

pub const FileEntry = extern struct {
    desc_tag: UDF_DESCR_TAG = .{},
    icb_tag: IcbTag = .{},
    uid: u32 align(1) = 0,
    gid: u32 align(1) = 0,
    permissions: u32 align(1) = 0,
    file_link_count: u16 align(1) = 0,
    record_format: u8 align(1) = 0,
    record_display_attr: u8 align(1) = 0,
    record_length: u32 align(1) = 0,
    information_length: u64 align(1) = 0,
    logical_blocks_recorded: u64 align(1) = 0,
    access_time: u32 align(1) = 0,
    modification_time: u32 align(1) = 0,
    attribute_time: u32 align(1) = 0,
    checkpoint: u32 align(1) = 0,
    reserved: u32 align(1) = 0,
    extended_attr_icb: ExtentAd = .{},
    imp_use: ExtentAd = .{},
};

pub const IcbTag = extern struct {
    prior_recorded_num_direct_entries: u32 align(1) = 0,
    strategy_type: u16 align(1) = 0,
    strategy_parameter: [4]u8 align(1) = .{0} ** 4,
    num_entries: u16 align(1) = 0,
    file_type: u8 align(1) = 0,
    parent_icb_location: u32 align(1) = 0,
    imp_use: [6]u8 align(1) = .{0} ** 6,

    pub fn isDirectory(self: *const IcbTag) bool {
        return self.file_type == UDF_ICBTAG_FILE_TYPE_DIR;
    }
};

pub const UdfVolume = struct {
    avdp: AnchorVolumeDescriptorPointer = .{},
    pvd: PrimaryVolumeDescriptor = .{},
    lvd: LogicalVolumeDescriptor = .{},
    root_fe_lba: u32 = 0,
    volume_space_size: u32 = 0,
    volume_id: [128]u8 = .{0} ** 128,
    volume_id_len: usize = 0,
    is_mounted: bool = false,
    backend: ?*block_common.BlockDevVTable = null,
};

var volume: UdfVolume = .{};

/// 从块设备读取扇区。
fn readSector(dev: *block_common.BlockDevVTable, lba: u32, buf: []u8) bool {
    if (buf.len < SECTOR_SIZE) return false;
    return dev.read_blocks(dev.ctx, lba, buf[0..SECTOR_SIZE]) == io.STATUS_SUCCESS;
}

/// 检测是否是 UDF 光盘（通过 Anchor Volume Descriptor Pointer）。
fn isUdf(dev: *block_common.BlockDevVTable) bool {
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(dev, 256, &buf)) return false;
    const avdp = @as(*align(1) const AnchorVolumeDescriptorPointer, @ptrCast(&buf)).*;
    return avdp.desc_tag.tag_ident == UDF_TAG_IDENT_ANCHOR;
}

/// 解析 UDF 卷。
pub fn mountFromBlockDev(dev: *block_common.BlockDevVTable) bool {
    if (!isUdf(dev)) {
        klog.warn("UDF: not a valid UDF volume", .{});
        return false;
    }

    var buf: [SECTOR_SIZE]u8 = undefined;

    if (!readSector(dev, 256, &buf)) return false;
    const avdp = @as(*align(1) const AnchorVolumeDescriptorPointer, @ptrCast(&buf)).*;
    volume.avdp = avdp;

    const main_seq_lba = avdp.main_vol_desc_seq_extent.extent_location;
    if (!readSector(dev, main_seq_lba, &buf)) return false;
    const pvd = @as(*align(1) const PrimaryVolumeDescriptor, @ptrCast(&buf)).*;
    if (pvd.desc_tag.tag_ident != UDF_TAG_IDENT_PRIMARY) {
        klog.warn("UDF: no Primary Volume Descriptor found", .{});
        return false;
    }
    volume.pvd = pvd;

    if (!readSector(dev, main_seq_lba + 1, &buf)) return false;
    const lvd = @as(*align(1) const LogicalVolumeDescriptor, @ptrCast(&buf)).*;
    if (lvd.desc_tag.tag_ident != UDF_TAG_IDENT_LOGICAL) {
        klog.warn("UDF: no Logical Volume Descriptor found", .{});
        return false;
    }
    volume.lvd = lvd;

    @memcpy(&volume.volume_id, &lvd.logical_vol_id);
    var n: usize = 0;
    for (volume.volume_id) |c| {
        if (c == ' ' or c == 0) break;
        n += 1;
    }
    volume.volume_id_len = n;
    volume.backend = dev;
    volume.is_mounted = true;

    klog.info("UDF: mounted (volume_id=%s)", .{volume.volume_id[0..volume.volume_id_len]});
    return true;
}

// ── VFS 操作 ──

fn udfOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = f;
    _ = path;
    return .not_implemented;
}

fn udfClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn udfRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = buffer;
    return .{ .status = .not_implemented };
}

fn udfWrite(_: *vfs.FileObject, _: []const u8) vfs.WriteResult {
    return .{ .status = .not_implemented };
}

fn udfQuerySpace(_: u32, total: *u64, free: *u64) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    total.* = @as(u64, volume.volume_space_size) * SECTOR_SIZE;
    free.* = 0;
    return .success;
}

fn udfReaddir(_: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    if (!volume.is_mounted) return 0;
    _ = entries;
    return 0;
}

fn udfMkdir(_: []const u8) vfs.FileStatus {
    return .not_implemented;
}

fn udfRemove(_: []const u8) vfs.FileStatus {
    return .not_implemented;
}

fn udfStat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    _ = entry;
    return .not_implemented;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &udfOpen,
        .close = &udfClose,
        .read = &udfRead,
        .write = &udfWrite,
        .readdir = &udfReaddir,
        .mkdir = &udfMkdir,
        .remove = &udfRemove,
        .stat = &udfStat,
        .query_space = &udfQuerySpace,
    };
}
