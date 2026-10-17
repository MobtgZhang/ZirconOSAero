const std = @import("std");

const process = @import("../ps/process.zig");
const subsystem = @import("../subsystems/win32/subsystem.zig");
const klog = @import("../rtl/klog.zig");
const FrameAllocator = @import("../mm/frame.zig").FrameAllocator;
const vfs = @import("../fs/vfs.zig");
const heap = @import("../mm/heap.zig");
const boot = @import("../boot/multiboot2_parse.zig");
const pe = @import("../loader/pe.zig");

pub const StartupProcess = struct {
    name: []const u8,
    subsystem: subsystem.SubsystemType,
    parent_pid: u32,
    pid: u32 = 0,
};

pub const SMSS_PID: u32 = 3;
pub const WININIT_PID: u32 = 4;
pub const SERVICES_PID: u32 = 5;
pub const LSASS_PID: u32 = 6;
pub const USERINIT_PID: u32 = 7;

pub const BootImageKind = struct {
    pub const kernel: u32 = 0;
    pub const hal: u32 = 1;
    pub const driver: u32 = 2;
    pub const smss: u32 = 3;
    pub const wininit: u32 = 4;
    pub const services: u32 = 5;
    pub const lsass: u32 = 6;
    pub const winlogon: u32 = 7;
    pub const userinit: u32 = 8;
    pub const cmd: u32 = 9;
};

const HandoffImageInfo = struct {
    name: []const u8,
    boot_kind: u32,
    is_dll: bool,
    driver_index: u8 = 0,
};

const handoff_images = [_]HandoffImageInfo{
    .{ .name = "ntoskrnl.exe", .boot_kind = BootImageKind.kernel, .is_dll = false },
    .{ .name = "hal.dll", .boot_kind = BootImageKind.hal, .is_dll = true },
    .{ .name = "acpi.sys", .boot_kind = BootImageKind.driver, .is_dll = true, .driver_index = 0 },
    .{ .name = "bootvid.sys", .boot_kind = BootImageKind.driver, .is_dll = true, .driver_index = 1 },
    .{ .name = "disk.sys", .boot_kind = BootImageKind.driver, .is_dll = true, .driver_index = 2 },
    .{ .name = "partmgr.sys", .boot_kind = BootImageKind.driver, .is_dll = true, .driver_index = 3 },
    .{ .name = "classpnp.sys", .boot_kind = BootImageKind.driver, .is_dll = true, .driver_index = 4 },
};

var startup_boot_images: []const boot.BootImage = &.{};

const StartupImage = struct {
    name: []const u8,
    path: []const u8,
    subsystem_type: subsystem.SubsystemType,
    boot_kind: u32,
};

const startup_images = [_]StartupImage{
    .{ .name = "smss.exe", .path = "\\Windows\\System32\\smss.exe", .subsystem_type = .native, .boot_kind = BootImageKind.smss },
    .{ .name = "wininit.exe", .path = "\\Windows\\System32\\wininit.exe", .subsystem_type = .native, .boot_kind = BootImageKind.wininit },
    .{ .name = "services.exe", .path = "\\Windows\\System32\\services.exe", .subsystem_type = .native, .boot_kind = BootImageKind.services },
    .{ .name = "lsass.exe", .path = "\\Windows\\System32\\lsass.exe", .subsystem_type = .native, .boot_kind = BootImageKind.lsass },
    .{ .name = "winlogon.exe", .path = "\\Windows\\System32\\winlogon.exe", .subsystem_type = .native, .boot_kind = BootImageKind.winlogon },
    .{ .name = "userinit.exe", .path = "\\Windows\\System32\\userinit.exe", .subsystem_type = .win32_cui, .boot_kind = BootImageKind.userinit },
    .{ .name = "cmd.exe", .path = "\\Windows\\System32\\cmd.exe", .subsystem_type = .win32_cui, .boot_kind = BootImageKind.cmd },
};

fn bootImageByKind(images: []const boot.BootImage, kind: u32) ?[]const u8 {
    for (images) |image| {
        if (image.kind != kind or image.base == 0 or image.size == 0 or image.size > 256 * 1024 * 1024) continue;
        const ptr: [*]const u8 = @ptrFromInt(image.base);
        return ptr[0..@intCast(image.size)];
    }
    return null;
}

fn readPeFile(path: []const u8) ?[]u8 {
    const file = vfs.open(path, .execute) orelse vfs.open(path, .read) orelse return null;
    defer _ = vfs.close(file);

    if (file.file_size == 0 or file.file_size > 256 * 1024 * 1024) return null;
    const data = heap.allocSlice(u8, @intCast(file.file_size)) orelse return null;
    var total: usize = 0;
    while (total < data.len) {
        const result = vfs.read(file, data[total..]);
        if (result.status != .success) return null;
        if (result.bytes_read == 0) return null;
        total += result.bytes_read;
    }
    return data;
}

fn startPeProcess(
    alloc: *FrameAllocator,
    image: StartupImage,
    parent_pid: u32,
) ?*process.Process {
    var pe_data: ?[]u8 = null;
    var loaded: bool = false;
    var proc_opt: ?*process.Process = null;

    klog.info("Startup: loading '%s' from '%s'", .{ image.name, image.path });
    if (bootImageByKind(startup_boot_images, image.boot_kind)) |data| {
        pe_data = @constCast(data);
        if (process.createProcessFromPe(alloc, data, 0, 0)) |created| {
            proc_opt = created.proc;
            loaded = true;
        }
    } else if (readPeFile(image.path)) |data| {
        pe_data = data;
        if (process.createProcessFromPe(alloc, data, 0, 0)) |created| {
            proc_opt = created.proc;
            loaded = true;
        }
    }

    if (!loaded) {
        proc_opt = process.createSystemProcess(alloc, image.name);
    }

    const proc = proc_opt orelse return null;
    _ = subsystem.registerProcess(proc.pid, image.subsystem_type, image.name, parent_pid);
    if (loaded) {
        klog.info("Startup: '%s' PE loaded (PID=%u, entry=%x)", .{ image.name, proc.pid, proc.image_entry_point });
    } else {
        klog.warn("Startup: '%s' PE missing or invalid; fallback process object created (PID=%u)", .{ image.name, proc.pid });
    }
    return proc;
}

fn startNamedProcess(
    alloc: *FrameAllocator,
    name: []const u8,
    subsystem_type: subsystem.SubsystemType,
    parent_pid: u32,
) ?*process.Process {
    const proc = process.createSystemProcess(alloc, name) orelse {
        klog.err("Startup: failed to create '%s'", .{name});
        return null;
    };

    if (subsystem.registerProcess(proc.pid, subsystem_type, name, parent_pid) == null) {
        klog.warn("Startup: '%s' was not registered with CSRSS", .{name});
    }

    klog.info(
        "Startup: '%s' created (PID=%u, parent=%u, subsystem=%u)",
        .{ name, proc.pid, parent_pid, @backingInt(subsystem_type) },
    );
    return proc;
}

pub fn startSmss(alloc: *FrameAllocator) ?*process.Process {
    return startPeProcess(alloc, startup_images[0], 1);
}

pub fn startWininit(alloc: *FrameAllocator) ?*process.Process {
    const smss_pid = if (process.findProcessByName("smss.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[1], smss_pid);
}

pub fn startServices(alloc: *FrameAllocator) ?*process.Process {
    const wininit_pid = if (process.findProcessByName("wininit.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[2], wininit_pid);
}

pub fn startLsass(alloc: *FrameAllocator) ?*process.Process {
    const wininit_pid = if (process.findProcessByName("wininit.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[3], wininit_pid);
}

pub fn startWinlogon(alloc: *FrameAllocator) ?*process.Process {
    const wininit_pid = if (process.findProcessByName("wininit.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[4], wininit_pid);
}

pub fn startUserinit(alloc: *FrameAllocator) ?*process.Process {
    const winlogon_pid = if (process.findProcessByName("winlogon.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[5], winlogon_pid);
}

pub fn startCmd(alloc: *FrameAllocator) ?*process.Process {
    const userinit_pid = if (process.findProcessByName("userinit.exe")) |proc| proc.pid else 1;
    return startPeProcess(alloc, startup_images[6], userinit_pid);
}

pub fn createSubsystemProcesses(alloc: *FrameAllocator, boot_images: []const boot.BootImage) void {
    startup_boot_images = boot_images;
    registerWinloadImages(boot_images);
    klog.info("--- System Process Startup Chain ---", .{});
    klog.info("Startup: winload handoff images=%u", .{boot_images.len});

    _ = startSmss(alloc);
    _ = startWininit(alloc);
    _ = startServices(alloc);
    _ = startLsass(alloc);
    _ = startWinlogon(alloc);
    _ = startUserinit(alloc);
    _ = startCmd(alloc);
}

fn registerWinloadImages(boot_images: []const boot.BootImage) void {
    for (handoff_images) |handoff| {
        const image = nthBootImageByKind(boot_images, handoff.boot_kind, handoff.driver_index) orelse continue;
        const result = pe.registerMappedImage(handoff.name, image.base, image.size, handoff.is_dll);
        if (result.status != .success) {
            klog.warn("WinloadHandoff: failed to register %s status=%u", .{ handoff.name, @backingInt(result.status) });
        }
    }
}

fn nthBootImageByKind(images: []const boot.BootImage, kind: u32, nth: u8) ?boot.BootImage {
    var count: u8 = 0;
    for (images) |image| {
        if (image.kind != kind or image.base == 0 or image.size == 0) continue;
        if (count == nth) return image;
        count += 1;
    }
    return null;
}
