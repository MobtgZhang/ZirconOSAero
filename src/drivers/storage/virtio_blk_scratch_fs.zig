// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/virtio_blk_scratch_fs.zig
// Purpose: VirtIO-Blk PCI 探测后的 **最小 VFS 卷**（`B:\PROBE.TXT`），使 `NtReadFile`→`dispatchFileObjectIrp` 具备块设备占位读路径（P3-C2 验收子集；非真实 virtioqueue）。
//
// This is an independent clean-room implementation.
// Ref: VirtIO Block Device 1.2（设备 ID）；VFS 挂载见 `src/fs/vfs.zig`。
// Milestone: [docs/cn/STORAGE_IO_ROADMAP.md](../../../docs/cn/STORAGE_IO_ROADMAP.md)

const vfs = @import("../../fs/vfs.zig");
const klog = @import("../../rtl/klog.zig");
const virtio_blk_pci = @import("virtio_blk_pci.zig");

/// 固定探测载荷；`NtReadFile` 可读回以验证 VFS–IRP–文件句柄链。
const probe_payload = "VIRTIO-BLK-SCRATCH\r\n";

var mount_done: bool = false;

fn nameEqI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const cx: u8 = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const cy: u8 = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (cx != cy) return false;
    }
    return true;
}

fn scratchOpen(f: *vfs.FileObject, path: []const u8, access: vfs.FileAccessMode) vfs.FileStatus {
    _ = access;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const base = path[name_start..];
    if (!nameEqI(base, "PROBE.TXT")) return .not_found;
    f.file_size = probe_payload.len;
    f.position = 0;
    f.fs_data = 0;
    return .success;
}

fn scratchClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn scratchRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    const off = f.position;
    if (off >= f.file_size) return .{ .status = .end_of_file, .bytes_read = 0 };
    const src = probe_payload[off..];
    const n = @min(buffer.len, src.len);
    @memcpy(buffer[0..n], src[0..n]);
    f.position += n;
    return .{ .status = .success, .bytes_read = n };
}

fn scratchWrite(_: *vfs.FileObject, _: []const u8) vfs.WriteResult {
    return .{ .status = .not_implemented, .bytes_written = 0 };
}

fn getScratchOps() vfs.FsOps {
    return .{
        .open = &scratchOpen,
        .close = &scratchClose,
        .read = &scratchRead,
        .write = &scratchWrite,
    };
}

/// 在 `vfs.init` 与 FAT/NTFS 挂载之后调用：若早期 PCI 枚举见过 VirtIO-Blk，则挂载 `B:\` 探测卷。
pub fn mountIfVirtioBlkDetected() void {
    if (mount_done) return;
    mount_done = true;
    if (!virtio_blk_pci.isVirtioBlkPciPresent()) return;
    _ = vfs.mount("B:\\", .devfs, getScratchOps(), 2, "VirtIO-Blk-Scratch");
    klog.info("VFS: VirtIO-Blk scratch volume B:\\ (open PROBE.TXT for read smoke)", .{});
}
