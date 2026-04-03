// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/registry/hive.zig
// Purpose: RegF / hive 文档子集、ZOSH1 引导覆盖加载与可选快照回写（VFS）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/sysinfo/registry-hives

const std = @import("std");
const vfs = @import("../fs/vfs.zig");
const klog = @import("../rtl/klog.zig");
const registry = @import("registry.zig");
const ntdll = @import("../libs/ntdll.zig");

/// 可选用户覆盖文件（FAT32 `C:\`）；不存在则静默跳过。
/// 与 SMSS/未来配置路径叙事一致；见 `registry.zig` 顶部说明。
pub const default_user_overlay_vfs_path = "C:\\System32\\Config\\ZirconUser.zosh";

/// NTFS `D:\` 上对称路径（阶段 4：DWM/Mouse ZOSH1 持久化）；后加载，可覆盖 `C:\` 同名键。
pub const default_ntfs_dwm_overlay_vfs_path = "D:\\System32\\Config\\ZirconUser.zosh";

/// 可选导出路径（管理员保存 Mouse/DWM 子集快照）。
pub const default_user_export_vfs_path = "C:\\System32\\Config\\ZirconUser.export.zosh";

/// NTFS 卷导出路径（与 `saveBootstrapSnapshot` 共用序列化逻辑）。
pub const default_ntfs_dwm_export_vfs_path = "D:\\System32\\Config\\ZirconUser.export.zosh";

/// RegF 基块魔数（仅识别；**本阶段不解析** NK/VK/lh bin 单元格链）。
/// 公开资料仅描述 hive 为二进制文件；单元格布局属实现细节，完整解析为长期项。
pub const regf_file_magic = "regf";

/// ZOSH1 引导格式魔数（与 `registry.mergeFromZosh1Bytes` 一致）。
pub const zosh1_magic = "ZOSH1";

/// 自 VFS 读取可选 ZOSH1 覆盖层；若文件以 `regf` 开头则记录告警并跳过（避免误把 Windows hive 当 ZOSH1）。
pub fn tryLoadBootstrapOverlays() void {
    if (!vfs.isInitialized()) return;
    tryLoadBootstrapFromPath(default_user_overlay_vfs_path);
    tryLoadBootstrapFromPath(default_ntfs_dwm_overlay_vfs_path);
}

fn tryLoadBootstrapFromPath(path: []const u8) void {
    const f = vfs.open(path, .read) orelse {
        klog.info("Registry: optional ZOSH1 overlay not present (%s)", .{path});
        return;
    };
    defer _ = vfs.close(f);

    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const rr = vfs.read(f, buf[total..]);
        if (rr.status != .success or rr.bytes_read == 0) break;
        total += rr.bytes_read;
    }
    if (total < 4) {
        klog.warn("Registry: overlay file too small (%s)", .{path});
        return;
    }
    if (std.mem.eql(u8, buf[0..4], regf_file_magic)) {
        klog.warn("Registry: %s looks like RegF hive; load subset parser not enabled (use ZOSH1)", .{path});
        return;
    }
    const st = registry.mergeFromZosh1Bytes(buf[0..total]);
    if (st.invalid) {
        klog.warn("Registry: ZOSH1 parse failed or bad magic (%s)", .{path});
        return;
    }
    klog.info("Registry: ZOSH1 overlay %s applied (records=%u skipped=%u)", .{ path, st.applied, st.skipped });
}

/// 将 `Mouse` + `DWM` 键导出为 ZOSH1（RegF **兼容子集**之引导格式，非 Windows RegF 文件）。
pub fn saveBootstrapSnapshot(path: []const u8) ntdll.NTSTATUS {
    if (!vfs.isInitialized()) return ntdll.STATUS_INVALID_PARAMETER;
    var buf: [4096]u8 = undefined;
    const n = registry.serializeMouseAndDwmZosh1(&buf);
    if (n == 0) return ntdll.STATUS_INSUFFICIENT_RESOURCES;
    const f = vfs.open(path, .write) orelse return ntdll.STATUS_OBJECT_NAME_NOT_FOUND;
    defer _ = vfs.close(f);
    var woff: usize = 0;
    while (woff < n) {
        const wr = vfs.write(f, buf[woff..n]);
        if (wr.status != .success or wr.bytes_written == 0) return ntdll.STATUS_IO_DEVICE_ERROR;
        woff += wr.bytes_written;
    }
    klog.info("Registry: wrote ZOSH1 snapshot (%u bytes) -> %s", .{ n, path });
    return ntdll.STATUS_SUCCESS;
}

/// 兼容旧名：自 VFS 路径加载（与 `tryLoadBootstrapOverlays` 相同语义）。
pub fn loadHiveFromFile(path: []const u8) ntdll.NTSTATUS {
    if (!vfs.isInitialized()) return ntdll.STATUS_INVALID_PARAMETER;
    tryLoadBootstrapFromPath(path);
    return ntdll.STATUS_SUCCESS;
}

pub fn saveHiveToFile(path: []const u8) ntdll.NTSTATUS {
    return saveBootstrapSnapshot(path);
}
