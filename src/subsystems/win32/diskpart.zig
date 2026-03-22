//! DiskPart - Disk Partition Utility
//! NT-compatible disk partitioning tool.
//! Supports: list disk/volume/partition, select, detail, create, delete,
//! format, assign, clean, extend, shrink, active, inactive, etc.

const console = @import("console.zig");
const vfs = @import("../../fs/vfs.zig");
const fat32 = @import("../../fs/fat32.zig");
const ntfs = @import("../../fs/ntfs.zig");
const klog = @import("../../rtl/klog.zig");

pub const DISKPART_VERSION = "DiskPart version 1.0.0 (ZirconOS)";
pub const DISKPART_COPYRIGHT = "Copyright (C) ZirconOS Project.";

const MAX_CMD_LEN: usize = 256;

pub const PartitionStyle = enum(u8) {
    mbr = 0,
    gpt = 1,
    raw = 2,
};

pub const PartitionType = enum(u8) {
    primary = 0,
    extended = 1,
    logical = 2,
    efi_system = 3,
    msr = 4,
    recovery = 5,
};

pub const PartitionStatus = enum(u8) {
    healthy = 0,
    at_risk = 1,
    failed = 2,
    unknown = 3,
    no_media = 4,
    online = 5,
};

pub const Partition = struct {
    number: u32 = 0,
    part_type: PartitionType = .primary,
    size_mb: u32 = 0,
    offset_mb: u32 = 0,
    fs_type: vfs.FsType = .unknown,
    is_active: bool = false,
    is_system: bool = false,
    is_boot: bool = false,
    drive_letter: u8 = 0,
    label: [16]u8 = [_]u8{0} ** 16,
    label_len: usize = 0,
    status: PartitionStatus = .healthy,
    in_use: bool = false,
};

pub const Disk = struct {
    number: u32 = 0,
    size_mb: u32 = 0,
    free_mb: u32 = 0,
    style: PartitionStyle = .mbr,
    status: PartitionStatus = .online,
    is_boot: bool = false,
    is_system: bool = false,
    model: [32]u8 = [_]u8{0} ** 32,
    model_len: usize = 0,
    partitions: [8]Partition = [_]Partition{.{}} ** 8,
    partition_count: u32 = 0,
    in_use: bool = false,
};

pub const Volume = struct {
    number: u32 = 0,
    drive_letter: u8 = 0,
    label: [16]u8 = [_]u8{0} ** 16,
    label_len: usize = 0,
    fs_type: vfs.FsType = .unknown,
    size_mb: u32 = 0,
    free_mb: u32 = 0,
    status: PartitionStatus = .healthy,
    info: [16]u8 = [_]u8{0} ** 16,
    info_len: usize = 0,
    in_use: bool = false,
};

const MAX_DISKS: usize = 8;
const MAX_VOLUMES: usize = 16;

pub const DiskPartState = struct {
    console_id: u32 = 0,
    disks: [MAX_DISKS]Disk = [_]Disk{.{}} ** MAX_DISKS,
    disk_count: u32 = 0,
    volumes: [MAX_VOLUMES]Volume = [_]Volume{.{}} ** MAX_VOLUMES,
    volume_count: u32 = 0,
    selected_disk: ?u32 = null,
    selected_volume: ?u32 = null,
    selected_partition: ?u32 = null,
    running: bool = false,

    pub fn init(self: *DiskPartState) void {
        self.disk_count = 0;
        self.volume_count = 0;
        self.selected_disk = null;
        self.selected_volume = null;
        self.selected_partition = null;
        self.running = true;
        self.populateFromSystem();
    }

    fn populateFromSystem(self: *DiskPartState) void {
        // Disk 0: System disk (contains C: and D:)
        {
            var d = &self.disks[0];
            d.* = .{};
            d.number = 0;
            d.size_mb = 256;
            d.free_mb = 64;
            d.style = .mbr;
            d.status = .online;
            d.is_boot = true;
            d.is_system = true;
            d.in_use = true;
            const model = "QEMU HARDDISK";
            @memcpy(d.model[0..model.len], model);
            d.model_len = model.len;

            // Partition 1: C: (FAT32)
            var p1 = &d.partitions[0];
            p1.* = .{};
            p1.number = 1;
            p1.part_type = .primary;
            p1.size_mb = 128;
            p1.offset_mb = 1;
            p1.fs_type = .fat32;
            p1.is_active = true;
            p1.is_system = true;
            p1.is_boot = true;
            p1.drive_letter = 'C';
            p1.status = .healthy;
            p1.in_use = true;
            const l1 = "ZIRCONOS";
            @memcpy(p1.label[0..l1.len], l1);
            p1.label_len = l1.len;

            // Partition 2: D: (NTFS)
            var p2 = &d.partitions[1];
            p2.* = .{};
            p2.number = 2;
            p2.part_type = .primary;
            p2.size_mb = 64;
            p2.offset_mb = 129;
            p2.fs_type = .ntfs;
            p2.is_active = false;
            p2.drive_letter = 'D';
            p2.status = .healthy;
            p2.in_use = true;
            const l2 = "Data";
            @memcpy(p2.label[0..l2.len], l2);
            p2.label_len = l2.len;

            d.partition_count = 2;
            self.disk_count = 1;
        }

        // Disk 1: Secondary disk (unpartitioned)
        {
            var d = &self.disks[1];
            d.* = .{};
            d.number = 1;
            d.size_mb = 512;
            d.free_mb = 512;
            d.style = .raw;
            d.status = .online;
            d.in_use = true;
            const model = "QEMU HARDDISK";
            @memcpy(d.model[0..model.len], model);
            d.model_len = model.len;
            d.partition_count = 0;
            self.disk_count = 2;
        }

        // Volume 0: C:
        {
            var v = &self.volumes[0];
            v.* = .{};
            v.number = 0;
            v.drive_letter = 'C';
            v.fs_type = .fat32;
            v.size_mb = 128;
            const fc = fat32.getVolume().getFreeClusters();
            v.free_mb = @intCast((fc * fat32.CLUSTER_SIZE) / (1024 * 1024));
            if (v.free_mb == 0) v.free_mb = 112;
            v.status = .healthy;
            v.in_use = true;
            const l1 = "ZIRCONOS";
            @memcpy(v.label[0..l1.len], l1);
            v.label_len = l1.len;
            const inf = "Boot";
            @memcpy(v.info[0..inf.len], inf);
            v.info_len = inf.len;
        }

        // Volume 1: D:
        {
            var v = &self.volumes[1];
            v.* = .{};
            v.number = 1;
            v.drive_letter = 'D';
            v.fs_type = .ntfs;
            v.size_mb = 64;
            v.free_mb = 48;
            v.status = .healthy;
            v.in_use = true;
            const l2 = "Data";
            @memcpy(v.label[0..l2.len], l2);
            v.label_len = l2.len;
        }

        self.volume_count = 2;
    }

    pub fn showBanner(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine(DISKPART_VERSION);
        con.writeLine(DISKPART_COPYRIGHT);
        con.writeLine("");
    }

    pub fn showPrompt(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        _ = con.writeOutput("DISKPART> ");
    }

    pub fn executeCommand(self: *DiskPartState, input: []const u8) void {
        const trimmed = trim(input);
        if (trimmed.len == 0) return;

        var cmd_end: usize = 0;
        while (cmd_end < trimmed.len and trimmed[cmd_end] != ' ') cmd_end += 1;
        const cmd = trimmed[0..cmd_end];
        const args_start = if (cmd_end < trimmed.len) cmd_end + 1 else trimmed.len;
        const args = trimmed[args_start..];

        if (strEqlI(cmd, "list")) {
            self.cmdList(args);
        } else if (strEqlI(cmd, "select") or strEqlI(cmd, "sel")) {
            self.cmdSelect(args);
        } else if (strEqlI(cmd, "detail")) {
            self.cmdDetail(args);
        } else if (strEqlI(cmd, "create")) {
            self.cmdCreate(args);
        } else if (strEqlI(cmd, "delete")) {
            self.cmdDelete(args);
        } else if (strEqlI(cmd, "format")) {
            self.cmdFormat(args);
        } else if (strEqlI(cmd, "assign")) {
            self.cmdAssign(args);
        } else if (strEqlI(cmd, "remove")) {
            self.cmdRemove(args);
        } else if (strEqlI(cmd, "clean")) {
            self.cmdClean();
        } else if (strEqlI(cmd, "active")) {
            self.cmdActive();
        } else if (strEqlI(cmd, "inactive")) {
            self.cmdInactive();
        } else if (strEqlI(cmd, "extend")) {
            self.cmdExtend(args);
        } else if (strEqlI(cmd, "shrink")) {
            self.cmdShrink(args);
        } else if (strEqlI(cmd, "convert")) {
            self.cmdConvert(args);
        } else if (strEqlI(cmd, "rescan")) {
            self.cmdRescan();
        } else if (strEqlI(cmd, "online")) {
            self.cmdOnline(args);
        } else if (strEqlI(cmd, "offline")) {
            self.cmdOffline(args);
        } else if (strEqlI(cmd, "attributes")) {
            self.cmdAttributes(args);
        } else if (strEqlI(cmd, "help")) {
            self.cmdHelp();
        } else if (strEqlI(cmd, "exit")) {
            self.running = false;
        } else {
            const con = console.getConsole(self.console_id) orelse return;
            con.writeLine("");
            _ = con.writeOutput("The command \"");
            _ = con.writeOutput(cmd);
            con.writeLine("\" is not recognized.");
            con.writeLine("Type HELP for a list of available commands.");
        }
    }

    fn cmdList(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        if (strEqlI(what, "disk")) {
            con.writeLine("");
            con.writeLine("  Disk ###  Status         Size     Free     Dyn  Gpt");
            con.writeLine("  --------  -------------  -------  -------  ---  ---");
            var i: u32 = 0;
            while (i < self.disk_count) : (i += 1) {
                const d = &self.disks[i];
                if (!d.in_use) continue;
                if (self.selected_disk != null and self.selected_disk.? == i) {
                    _ = con.writeOutput("* ");
                } else {
                    _ = con.writeOutput("  ");
                }
                _ = con.writeOutput("Disk ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, i));
                padTo(con, 16);
                _ = con.writeOutput(statusStr(d.status));
                padTo(con, 31);
                _ = con.writeOutput(formatUint(&buf, d.size_mb));
                _ = con.writeOutput(" MB");
                padTo(con, 40);
                _ = con.writeOutput(formatUint(&buf, d.free_mb));
                _ = con.writeOutput(" MB");
                padTo(con, 49);
                _ = con.writeOutput("     ");
                if (d.style == .gpt) {
                    _ = con.writeOutput("*");
                }
                con.writeLine("");
            }
            con.writeLine("");
        } else if (strEqlI(what, "volume") or strEqlI(what, "vol")) {
            con.writeLine("");
            con.writeLine("  Volume ###  Ltr  Label        Fs     Type        Size     Status     Info");
            con.writeLine("  ----------  ---  -----------  -----  ----------  -------  ---------  --------");
            var i: u32 = 0;
            while (i < self.volume_count) : (i += 1) {
                const v = &self.volumes[i];
                if (!v.in_use) continue;
                if (self.selected_volume != null and self.selected_volume.? == i) {
                    _ = con.writeOutput("* ");
                } else {
                    _ = con.writeOutput("  ");
                }
                _ = con.writeOutput("Volume ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, i));
                padTo(con, 14);
                if (v.drive_letter != 0) {
                    _ = con.writeOutput(&[_]u8{v.drive_letter});
                } else {
                    _ = con.writeOutput(" ");
                }
                padTo(con, 19);
                _ = con.writeOutput(v.label[0..v.label_len]);
                padTo(con, 32);
                _ = con.writeOutput(fsTypeStr(v.fs_type));
                padTo(con, 39);
                _ = con.writeOutput("Partition");
                padTo(con, 51);
                _ = con.writeOutput(formatUint(&buf, v.size_mb));
                _ = con.writeOutput(" MB");
                padTo(con, 60);
                _ = con.writeOutput(statusStr(v.status));
                padTo(con, 71);
                _ = con.writeOutput(v.info[0..v.info_len]);
                con.writeLine("");
            }
            con.writeLine("");
        } else if (strEqlI(what, "partition") or strEqlI(what, "part")) {
            if (self.selected_disk == null) {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("Select a disk and try again.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            con.writeLine("");
            con.writeLine("  Partition ###  Type              Size     Offset");
            con.writeLine("  -------------  ----------------  -------  -------");
            var i: u32 = 0;
            while (i < d.partition_count) : (i += 1) {
                const p = &d.partitions[i];
                if (!p.in_use) continue;
                if (self.selected_partition != null and self.selected_partition.? == i) {
                    _ = con.writeOutput("* ");
                } else {
                    _ = con.writeOutput("  ");
                }
                _ = con.writeOutput("Partition ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, p.number));
                padTo(con, 17);
                _ = con.writeOutput(partTypeStr(p.part_type));
                padTo(con, 35);
                _ = con.writeOutput(formatUint(&buf, p.size_mb));
                _ = con.writeOutput(" MB");
                padTo(con, 44);
                _ = con.writeOutput(formatUint(&buf, p.offset_mb));
                _ = con.writeOutput(" MB");
                con.writeLine("");
            }
            con.writeLine("");
        } else {
            con.writeLine("");
            con.writeLine("The argument is incorrect. Use LIST DISK, LIST VOLUME, or LIST PARTITION.");
            con.writeLine("");
        }
    }

    fn cmdSelect(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        var type_end: usize = 0;
        while (type_end < what.len and what[type_end] != ' ') type_end += 1;
        const obj_type = what[0..type_end];
        const num_start = if (type_end < what.len) type_end + 1 else what.len;
        const num_str = trim(what[num_start..]);

        const number = parseUint(num_str) orelse {
            con.writeLine("");
            con.writeLine("The argument is not valid.");
            con.writeLine("");
            return;
        };

        if (strEqlI(obj_type, "disk")) {
            if (number < self.disk_count and self.disks[number].in_use) {
                self.selected_disk = number;
                self.selected_partition = null;
                con.writeLine("");
                _ = con.writeOutput("Disk ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, number));
                con.writeLine(" is now the selected disk.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("The disk number is not valid.");
                con.writeLine("");
            }
        } else if (strEqlI(obj_type, "volume") or strEqlI(obj_type, "vol")) {
            if (number < self.volume_count and self.volumes[number].in_use) {
                self.selected_volume = number;
                con.writeLine("");
                _ = con.writeOutput("Volume ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, number));
                con.writeLine(" is now the selected volume.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("The volume number is not valid.");
                con.writeLine("");
            }
        } else if (strEqlI(obj_type, "partition") or strEqlI(obj_type, "part")) {
            if (self.selected_disk == null) {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            if (number > 0 and number <= d.partition_count) {
                self.selected_partition = number - 1;
                con.writeLine("");
                _ = con.writeOutput("Partition ");
                var buf: [16]u8 = undefined;
                _ = con.writeOutput(formatUint(&buf, number));
                con.writeLine(" is now the selected partition.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("The partition number is not valid.");
                con.writeLine("");
            }
        } else {
            con.writeLine("");
            con.writeLine("Use SELECT DISK, SELECT VOLUME, or SELECT PARTITION.");
            con.writeLine("");
        }
    }

    fn cmdDetail(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        if (strEqlI(what, "disk")) {
            if (self.selected_disk == null) {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            var buf: [16]u8 = undefined;
            con.writeLine("");
            _ = con.writeOutput("Disk ID: ");
            _ = con.writeOutput(formatUint(&buf, d.number));
            con.writeLine("");
            _ = con.writeOutput("Type   : ");
            con.writeLine(if (d.style == .gpt) "GPT" else if (d.style == .mbr) "MBR" else "RAW");
            _ = con.writeOutput("Status : ");
            con.writeLine(statusStr(d.status));
            _ = con.writeOutput("Size   : ");
            _ = con.writeOutput(formatUint(&buf, d.size_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Free   : ");
            _ = con.writeOutput(formatUint(&buf, d.free_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Model  : ");
            con.writeLine(d.model[0..d.model_len]);
            _ = con.writeOutput("Boot   : ");
            con.writeLine(if (d.is_boot) "Yes" else "No");
            _ = con.writeOutput("System : ");
            con.writeLine(if (d.is_system) "Yes" else "No");
            _ = con.writeOutput("Partitions: ");
            con.writeLine(formatUint(&buf, d.partition_count));
            con.writeLine("");
        } else if (strEqlI(what, "volume") or strEqlI(what, "vol")) {
            if (self.selected_volume == null) {
                con.writeLine("");
                con.writeLine("There is no volume selected.");
                con.writeLine("");
                return;
            }
            const v = &self.volumes[self.selected_volume.?];
            var buf: [16]u8 = undefined;
            con.writeLine("");
            _ = con.writeOutput("Volume ###  : ");
            con.writeLine(formatUint(&buf, v.number));
            _ = con.writeOutput("Letter     : ");
            if (v.drive_letter != 0) {
                con.writeLine(&[_]u8{v.drive_letter});
            } else {
                con.writeLine("(none)");
            }
            _ = con.writeOutput("Label      : ");
            con.writeLine(v.label[0..v.label_len]);
            _ = con.writeOutput("Fs         : ");
            con.writeLine(fsTypeStr(v.fs_type));
            _ = con.writeOutput("Type       : Partition");
            con.writeLine("");
            _ = con.writeOutput("Size       : ");
            _ = con.writeOutput(formatUint(&buf, v.size_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Free       : ");
            _ = con.writeOutput(formatUint(&buf, v.free_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Status     : ");
            con.writeLine(statusStr(v.status));
            con.writeLine("");
        } else if (strEqlI(what, "partition") or strEqlI(what, "part")) {
            if (self.selected_disk == null or self.selected_partition == null) {
                con.writeLine("");
                con.writeLine("There is no partition selected.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            const p = &d.partitions[self.selected_partition.?];
            var buf: [16]u8 = undefined;
            con.writeLine("");
            _ = con.writeOutput("Partition ");
            _ = con.writeOutput(formatUint(&buf, p.number));
            con.writeLine("");
            _ = con.writeOutput("Type   : ");
            con.writeLine(partTypeStr(p.part_type));
            _ = con.writeOutput("Active : ");
            con.writeLine(if (p.is_active) "Yes" else "No");
            _ = con.writeOutput("Size   : ");
            _ = con.writeOutput(formatUint(&buf, p.size_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Offset : ");
            _ = con.writeOutput(formatUint(&buf, p.offset_mb));
            con.writeLine(" MB");
            _ = con.writeOutput("Letter : ");
            if (p.drive_letter != 0) {
                con.writeLine(&[_]u8{p.drive_letter});
            } else {
                con.writeLine("(none)");
            }
            _ = con.writeOutput("Label  : ");
            con.writeLine(p.label[0..p.label_len]);
            _ = con.writeOutput("Fs     : ");
            con.writeLine(fsTypeStr(p.fs_type));
            con.writeLine("");
        } else {
            con.writeLine("");
            con.writeLine("Use DETAIL DISK, DETAIL VOLUME, or DETAIL PARTITION.");
            con.writeLine("");
        }
    }

    fn cmdCreate(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        var type_end: usize = 0;
        while (type_end < what.len and what[type_end] != ' ') type_end += 1;
        const obj_type = what[0..type_end];
        const rest = trim(what[type_end..]);

        if (strEqlI(obj_type, "partition") or strEqlI(obj_type, "part")) {
            if (self.selected_disk == null) {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            if (d.partition_count >= 8) {
                con.writeLine("");
                con.writeLine("There is not enough space on the disk to create a partition.");
                con.writeLine("");
                return;
            }
            if (d.free_mb == 0) {
                con.writeLine("");
                con.writeLine("There is not enough usable free space to create a partition.");
                con.writeLine("");
                return;
            }

            var ptype: PartitionType = .primary;
            var size_mb: u32 = d.free_mb;

            var stype_end: usize = 0;
            while (stype_end < rest.len and rest[stype_end] != ' ') stype_end += 1;
            const sub_type = rest[0..stype_end];
            if (strEqlI(sub_type, "primary")) {
                ptype = .primary;
            } else if (strEqlI(sub_type, "extended")) {
                ptype = .extended;
            } else if (strEqlI(sub_type, "logical")) {
                ptype = .logical;
            } else if (strEqlI(sub_type, "efi")) {
                ptype = .efi_system;
            } else if (strEqlI(sub_type, "msr")) {
                ptype = .msr;
            }

            const rest2 = trim(rest[stype_end..]);
            if (rest2.len > 5 and rest2[0] == 's' and rest2[1] == 'i' and rest2[2] == 'z' and rest2[3] == 'e' and rest2[4] == '=') {
                if (parseUint(rest2[5..])) |s| {
                    size_mb = s;
                }
            }

            const offset = d.size_mb - d.free_mb + 1;
            var p = &d.partitions[d.partition_count];
            p.* = .{};
            p.number = d.partition_count + 1;
            p.part_type = ptype;
            p.size_mb = @min(size_mb, d.free_mb);
            p.offset_mb = offset;
            p.status = .healthy;
            p.in_use = true;
            d.partition_count += 1;
            d.free_mb -= p.size_mb;

            self.selected_partition = d.partition_count - 1;

            con.writeLine("");
            con.writeLine("DiskPart succeeded in creating the specified partition.");
            con.writeLine("");
        } else if (strEqlI(obj_type, "volume") or strEqlI(obj_type, "vol")) {
            con.writeLine("");
            con.writeLine("Use CREATE PARTITION to create a partition first, then FORMAT.");
            con.writeLine("");
        } else {
            con.writeLine("");
            con.writeLine("Use CREATE PARTITION PRIMARY [size=<N>].");
            con.writeLine("");
        }
    }

    fn cmdDelete(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        if (strEqlI(what, "partition") or strEqlI(what, "part")) {
            if (self.selected_disk == null or self.selected_partition == null) {
                con.writeLine("");
                con.writeLine("There is no partition selected.");
                con.writeLine("");
                return;
            }
            const d = &self.disks[self.selected_disk.?];
            const pidx = self.selected_partition.?;
            if (pidx < d.partition_count) {
                const p = &d.partitions[pidx];
                d.free_mb += p.size_mb;
                p.in_use = false;
                self.selected_partition = null;
                con.writeLine("");
                con.writeLine("DiskPart successfully deleted the selected partition.");
                con.writeLine("");
            }
        } else {
            con.writeLine("");
            con.writeLine("Use DELETE PARTITION.");
            con.writeLine("");
        }
    }

    fn cmdFormat(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_volume == null and self.selected_partition == null) {
            con.writeLine("");
            con.writeLine("There is no volume or partition selected.");
            con.writeLine("");
            return;
        }

        var fs: vfs.FsType = .fat32;
        var quick = false;
        const what = trim(args);
        if (what.len >= 3 and what[0] == 'f' and what[1] == 's' and what[2] == '=') {
            const fs_name = trim(what[3..]);
            var fs_end: usize = 0;
            while (fs_end < fs_name.len and fs_name[fs_end] != ' ') fs_end += 1;
            const fsn = fs_name[0..fs_end];
            if (strEqlI(fsn, "ntfs")) {
                fs = .ntfs;
            } else if (strEqlI(fsn, "fat32")) {
                fs = .fat32;
            }
        }

        var check_pos: usize = 0;
        while (check_pos + 5 <= what.len) : (check_pos += 1) {
            if (strEqlI(what[check_pos..][0..5], "quick")) {
                quick = true;
                break;
            }
        }

        con.writeLine("");
        _ = con.writeOutput("  100 percent completed");
        con.writeLine("");
        if (quick) {
            con.writeLine("DiskPart successfully formatted the volume (quick).");
        } else {
            con.writeLine("DiskPart successfully formatted the volume.");
        }

        if (self.selected_volume) |vidx| {
            if (vidx < self.volume_count) {
                self.volumes[vidx].fs_type = fs;
            }
        }
        if (self.selected_disk != null and self.selected_partition != null) {
            const d = &self.disks[self.selected_disk.?];
            const pidx = self.selected_partition.?;
            if (pidx < d.partition_count) {
                d.partitions[pidx].fs_type = fs;
            }
        }
        con.writeLine("");
    }

    fn cmdAssign(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);

        var letter: u8 = 0;
        if (what.len >= 8 and what[0] == 'l' and what[1] == 'e' and what[2] == 't' and
            what[3] == 't' and what[4] == 'e' and what[5] == 'r' and what[6] == '=')
        {
            letter = what[7];
            if (letter >= 'a' and letter <= 'z') letter -= 32;
        }

        if (letter == 0) {
            con.writeLine("");
            con.writeLine("Use ASSIGN LETTER=<X>.");
            con.writeLine("");
            return;
        }

        if (self.selected_volume) |vidx| {
            if (vidx < self.volume_count) {
                self.volumes[vidx].drive_letter = letter;
                con.writeLine("");
                con.writeLine("DiskPart successfully assigned the drive letter.");
                con.writeLine("");
                return;
            }
        }
        if (self.selected_disk != null and self.selected_partition != null) {
            const d = &self.disks[self.selected_disk.?];
            const pidx = self.selected_partition.?;
            if (pidx < d.partition_count) {
                d.partitions[pidx].drive_letter = letter;
                con.writeLine("");
                con.writeLine("DiskPart successfully assigned the drive letter.");
                con.writeLine("");
                return;
            }
        }
        con.writeLine("");
        con.writeLine("There is no volume or partition selected.");
        con.writeLine("");
    }

    fn cmdRemove(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);
        _ = what;

        if (self.selected_volume) |vidx| {
            if (vidx < self.volume_count) {
                self.volumes[vidx].drive_letter = 0;
                con.writeLine("");
                con.writeLine("DiskPart successfully removed the drive letter.");
                con.writeLine("");
                return;
            }
        }
        con.writeLine("");
        con.writeLine("There is no volume selected.");
        con.writeLine("");
    }

    fn cmdClean(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null) {
            con.writeLine("");
            con.writeLine("There is no disk selected.");
            con.writeLine("");
            return;
        }
        const d = &self.disks[self.selected_disk.?];
        d.free_mb = d.size_mb;
        d.partition_count = 0;
        d.style = .raw;
        for (&d.partitions) |*p| {
            p.in_use = false;
        }
        self.selected_partition = null;
        con.writeLine("");
        con.writeLine("DiskPart succeeded in cleaning the disk.");
        con.writeLine("");
    }

    fn cmdActive(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null or self.selected_partition == null) {
            con.writeLine("");
            con.writeLine("There is no partition selected.");
            con.writeLine("");
            return;
        }
        const d = &self.disks[self.selected_disk.?];
        d.partitions[self.selected_partition.?].is_active = true;
        con.writeLine("");
        con.writeLine("DiskPart marked the current partition as active.");
        con.writeLine("");
    }

    fn cmdInactive(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null or self.selected_partition == null) {
            con.writeLine("");
            con.writeLine("There is no partition selected.");
            con.writeLine("");
            return;
        }
        const d = &self.disks[self.selected_disk.?];
        d.partitions[self.selected_partition.?].is_active = false;
        con.writeLine("");
        con.writeLine("DiskPart marked the current partition as inactive.");
        con.writeLine("");
    }

    fn cmdExtend(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null or self.selected_partition == null) {
            con.writeLine("");
            con.writeLine("There is no partition selected.");
            con.writeLine("");
            return;
        }
        const d = &self.disks[self.selected_disk.?];
        const p = &d.partitions[self.selected_partition.?];
        var ext_mb: u32 = d.free_mb;
        const what = trim(args);
        if (what.len >= 5 and what[0] == 's' and what[1] == 'i' and what[2] == 'z' and what[3] == 'e' and what[4] == '=') {
            if (parseUint(what[5..])) |s| {
                ext_mb = @min(s, d.free_mb);
            }
        }
        if (ext_mb == 0 or d.free_mb == 0) {
            con.writeLine("");
            con.writeLine("There is not enough usable free space on the disk.");
            con.writeLine("");
            return;
        }
        p.size_mb += ext_mb;
        d.free_mb -= ext_mb;
        con.writeLine("");
        con.writeLine("DiskPart successfully extended the volume.");
        con.writeLine("");
    }

    fn cmdShrink(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null or self.selected_partition == null) {
            con.writeLine("");
            con.writeLine("There is no partition selected.");
            con.writeLine("");
            return;
        }
        const d = &self.disks[self.selected_disk.?];
        const p = &d.partitions[self.selected_partition.?];
        var shrink_mb: u32 = p.size_mb / 2;
        const what = trim(args);
        if (what.len >= 8 and what[0] == 'd' and what[1] == 'e' and what[2] == 's' and
            what[3] == 'i' and what[4] == 'r' and what[5] == 'e' and what[6] == 'd' and what[7] == '=')
        {
            if (parseUint(what[8..])) |s| {
                shrink_mb = @min(s, p.size_mb - 1);
            }
        }
        if (shrink_mb == 0) {
            con.writeLine("");
            con.writeLine("Cannot shrink the volume further.");
            con.writeLine("");
            return;
        }
        p.size_mb -= shrink_mb;
        d.free_mb += shrink_mb;
        var buf: [16]u8 = undefined;
        con.writeLine("");
        _ = con.writeOutput("DiskPart successfully shrunk the volume by ");
        _ = con.writeOutput(formatUint(&buf, shrink_mb));
        con.writeLine(" MB.");
        con.writeLine("");
    }

    fn cmdConvert(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        if (self.selected_disk == null) {
            con.writeLine("");
            con.writeLine("There is no disk selected.");
            con.writeLine("");
            return;
        }
        const what = trim(args);
        const d = &self.disks[self.selected_disk.?];
        if (strEqlI(what, "gpt")) {
            d.style = .gpt;
            con.writeLine("");
            con.writeLine("DiskPart successfully converted the selected disk to GPT format.");
            con.writeLine("");
        } else if (strEqlI(what, "mbr")) {
            d.style = .mbr;
            con.writeLine("");
            con.writeLine("DiskPart successfully converted the selected disk to MBR format.");
            con.writeLine("");
        } else {
            con.writeLine("");
            con.writeLine("Use CONVERT GPT or CONVERT MBR.");
            con.writeLine("");
        }
    }

    fn cmdRescan(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("DiskPart has finished scanning your configuration.");
        con.writeLine("");
    }

    fn cmdOnline(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);
        if (strEqlI(what, "disk")) {
            if (self.selected_disk) |didx| {
                self.disks[didx].status = .online;
                con.writeLine("");
                con.writeLine("DiskPart successfully onlined the selected disk.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
            }
        } else if (strEqlI(what, "volume") or strEqlI(what, "vol")) {
            if (self.selected_volume) |vidx| {
                self.volumes[vidx].status = .healthy;
                con.writeLine("");
                con.writeLine("DiskPart successfully onlined the selected volume.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no volume selected.");
                con.writeLine("");
            }
        } else {
            con.writeLine("");
            con.writeLine("Use ONLINE DISK or ONLINE VOLUME.");
            con.writeLine("");
        }
    }

    fn cmdOffline(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);
        if (strEqlI(what, "disk")) {
            if (self.selected_disk) |didx| {
                self.disks[didx].status = .no_media;
                con.writeLine("");
                con.writeLine("DiskPart successfully offlined the selected disk.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
            }
        } else if (strEqlI(what, "volume") or strEqlI(what, "vol")) {
            if (self.selected_volume) |vidx| {
                self.volumes[vidx].status = .no_media;
                con.writeLine("");
                con.writeLine("DiskPart successfully offlined the selected volume.");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no volume selected.");
                con.writeLine("");
            }
        } else {
            con.writeLine("");
            con.writeLine("Use OFFLINE DISK or OFFLINE VOLUME.");
            con.writeLine("");
        }
    }

    fn cmdAttributes(self: *DiskPartState, args: []const u8) void {
        const con = console.getConsole(self.console_id) orelse return;
        const what = trim(args);
        if (strEqlI(what, "disk")) {
            if (self.selected_disk) |didx| {
                const d = &self.disks[didx];
                con.writeLine("");
                _ = con.writeOutput("Current Read-only State : No");
                con.writeLine("");
                _ = con.writeOutput("Read-only  : No");
                con.writeLine("");
                _ = con.writeOutput("Boot Disk  : ");
                con.writeLine(if (d.is_boot) "Yes" else "No");
                _ = con.writeOutput("System Disk: ");
                con.writeLine(if (d.is_system) "Yes" else "No");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no disk selected.");
                con.writeLine("");
            }
        } else if (strEqlI(what, "volume") or strEqlI(what, "vol")) {
            if (self.selected_volume != null) {
                con.writeLine("");
                con.writeLine("Read-only          : No");
                con.writeLine("Hidden             : No");
                con.writeLine("No Default Drive   : No");
                con.writeLine("Shadow Copy        : No");
                con.writeLine("");
            } else {
                con.writeLine("");
                con.writeLine("There is no volume selected.");
                con.writeLine("");
            }
        } else {
            con.writeLine("");
            con.writeLine("Use ATTRIBUTES DISK or ATTRIBUTES VOLUME.");
            con.writeLine("");
        }
    }

    fn cmdHelp(self: *DiskPartState) void {
        const con = console.getConsole(self.console_id) orelse return;
        con.writeLine("");
        con.writeLine("  ACTIVE      - Mark the selected partition as active.");
        con.writeLine("  ASSIGN      - Assign a drive letter to the selected volume.");
        con.writeLine("  ATTRIBUTES  - Display disk or volume attributes.");
        con.writeLine("  CLEAN       - Clear the configuration on the selected disk.");
        con.writeLine("  CONVERT     - Convert between MBR and GPT disk types.");
        con.writeLine("  CREATE      - Create a volume or partition.");
        con.writeLine("  DELETE      - Delete an object.");
        con.writeLine("  DETAIL      - Display details about an object.");
        con.writeLine("  EXIT        - Exit DiskPart.");
        con.writeLine("  EXTEND      - Extend a volume.");
        con.writeLine("  FORMAT      - Format the volume or partition.");
        con.writeLine("  HELP        - Display a list of commands.");
        con.writeLine("  INACTIVE    - Mark the selected partition as inactive.");
        con.writeLine("  LIST        - Display a list of objects.");
        con.writeLine("  OFFLINE     - Take a disk or volume offline.");
        con.writeLine("  ONLINE      - Bring a disk or volume online.");
        con.writeLine("  REMOVE      - Remove a drive letter assignment.");
        con.writeLine("  RESCAN      - Rescan the computer for disks and volumes.");
        con.writeLine("  SELECT      - Shift the focus to an object.");
        con.writeLine("  SHRINK      - Reduce the size of the selected volume.");
        con.writeLine("");
    }
};

// ── Helper functions ──

fn padTo(con: *console.Console, target_col: usize) void {
    _ = target_col;
    _ = con.writeOutput(" ");
}

fn statusStr(s: PartitionStatus) []const u8 {
    return switch (s) {
        .healthy => "Healthy",
        .at_risk => "At Risk",
        .failed => "Failed",
        .unknown => "Unknown",
        .no_media => "No Media",
        .online => "Online",
    };
}

fn fsTypeStr(fs: vfs.FsType) []const u8 {
    return switch (fs) {
        .fat32 => "FAT32",
        .ntfs => "NTFS",
        .devfs => "DevFS",
        .unknown => "RAW",
    };
}

fn partTypeStr(pt: PartitionType) []const u8 {
    return switch (pt) {
        .primary => "Primary",
        .extended => "Extended",
        .logical => "Logical",
        .efi_system => "EFI System",
        .msr => "MSR (Reserved)",
        .recovery => "Recovery",
    };
}

fn parseUint(s: []const u8) ?u32 {
    const trimmed = trim(s);
    if (trimmed.len == 0) return null;
    var result: u32 = 0;
    for (trimmed) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn strEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const ax = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const by = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (ax != by) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

fn formatUint(buf: []u8, value: anytype) []const u8 {
    const digits = "0123456789";
    var tmp: [20]u8 = undefined;
    var len: usize = 0;
    var n: u64 = @intCast(value);

    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) {
            tmp[len] = digits[n % 10];
            len += 1;
            n /= 10;
        }
    }

    var pos: usize = 0;
    var i = len;
    while (i > 0) {
        i -= 1;
        if (pos < buf.len) {
            buf[pos] = tmp[i];
            pos += 1;
        }
    }
    return buf[0..pos];
}

// ── Global instance ──

var dp_state: DiskPartState = .{};
var dp_initialized: bool = false;

pub fn init() void {
    dp_state.init();
    dp_initialized = true;
    klog.info("DiskPart: Disk partition utility initialized", .{});
}

pub fn getState() *DiskPartState {
    return &dp_state;
}

pub fn isInitialized() bool {
    return dp_initialized;
}

/// Run DiskPart as a sub-shell from CMD or PowerShell.
/// Uses the given console_id for I/O.
/// Reads input from arch.readInputChar() in an interactive loop.
/// Returns when the user types "exit".
pub fn runInteractive(console_id: u32) void {
    const arch = @import("../../arch.zig");

    if (!dp_initialized) init();

    dp_state.console_id = console_id;
    dp_state.running = true;

    dp_state.showBanner();
    dp_state.showPrompt();

    var line_buf: [MAX_CMD_LEN]u8 = undefined;
    var line_len: usize = 0;

    while (dp_state.running) {
        const ch_opt = arch.readInputChar();
        if (ch_opt) |ch| {
            switch (ch) {
                '\n', '\r' => {
                    const con = console.getConsole(console_id);
                    if (con) |c| {
                        c.writeLine("");
                    }
                    if (line_len > 0) {
                        dp_state.executeCommand(line_buf[0..line_len]);
                    }
                    if (dp_state.running) {
                        dp_state.showPrompt();
                    }
                    line_len = 0;
                },
                0x08, 0x7F => {
                    if (line_len > 0) {
                        line_len -= 1;
                        const con = console.getConsole(console_id);
                        if (con) |c| {
                            _ = c.writeOutput("\x08 \x08");
                        }
                    }
                },
                0x03 => {
                    const con = console.getConsole(console_id);
                    if (con) |c| {
                        c.writeLine("^C");
                    }
                    line_len = 0;
                    dp_state.showPrompt();
                },
                else => {
                    if (ch >= 0x20 and ch < 0x7F and line_len < MAX_CMD_LEN - 1) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                        const con = console.getConsole(console_id);
                        if (con) |c| {
                            _ = c.writeOutput(&[_]u8{ch});
                        }
                    }
                },
            }
        } else {
            arch.waitForInterrupt();
        }
    }

    const con = console.getConsole(console_id);
    if (con) |c| {
        c.writeLine("");
        c.writeLine("Leaving DiskPart...");
    }
}

/// Non-interactive: execute a single DiskPart command.
pub fn executeOne(console_id: u32, command: []const u8) void {
    if (!dp_initialized) init();
    dp_state.console_id = console_id;
    dp_state.executeCommand(command);
}
