// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/riscv64/fdt.zig
// Purpose: RISC-V 设备树（Device Tree Blob, DTB）解析 — 枚举 CPU hart、内存布局、PLIC 等。
// DTB 由固件通过 a1 寄存器传入（QEMU `-kernel` 或 UEFI）。
//
// This is an independent clean-room implementation.
// Reference: Devicetree Specification v0.4 (devicetree.org, public).

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const std = @import("std");

/// DTB magic: 0xD00DFEED (big-endian)
const FDT_MAGIC: u32 = 0xD00DFEED;

/// DTB 结构布局偏移
const OFF_MAGIC: usize = 0;
const OFF_TOTAL_SIZE: usize = 4;
const OFF_OFF_STRUCT: usize = 8;
const OFF_OFF_STRINGS: usize = 12;
const OFF_OFF_RSVMAP: usize = 16;
const OFF_VERSION: usize = 20;
const OFF_LAST_COMPAT_VERSION: usize = 24;

/// DTB 节点类型
const FDT_BEGIN_NODE: u32 = 0x1;
const FDT_END_NODE: u32 = 0x2;
const FDT_PROP: u32 = 0x3;
const FDT_NOP: u32 = 0x4;
const FDT_END: u32 = 0x9;

pub const HartInfo = struct {
    hartid: u32,
    status_code: u8,
};

/// 从 DTB 解析的所有 hart 信息
pub const MAX_HARTS: usize = 64;
pub var hart_count: u32 = 0;
pub var hart_infos: [MAX_HARTS]HartInfo = undefined;
pub var hart_ids: [MAX_HARTS]u32 = undefined;

/// DTB 根节点解析到的物理内存大小
pub var dtb_mem_size: u64 = 0;

/// 解析 DTB — 遍历 `/cpus` 节点下的 `/cpus hart@N` 子节点
/// fdt_phys: DTB blob 的物理地址
/// 返回 hart 数量（至少为 1）
pub fn parse(fdt_phys: usize) u32 {
    hart_count = 0;
    if (fdt_phys == 0) {
        klog.warn("RISC-V FDT: fdt_phys is zero (no DTB)", .{});
        return fallbackHartCount();
    }

    const header: [*]align(4) const u8 = @ptrFromInt(fdt_phys);

    // 读取 magic
    const magic = readBeU32(header, OFF_MAGIC);
    if (magic != FDT_MAGIC) {
        klog.warn("RISC-V FDT: bad magic 0x%x (expected 0xD00DFEED)", .{magic});
        return fallbackHartCount();
    }

    // 读取 total_size
    const total_size = readBeU32(header, OFF_TOTAL_SIZE);
    if (total_size < 40) {
        klog.warn("RISC-V FDT: total_size too small %u", .{total_size});
        return fallbackHartCount();
    }

    const struct_off = readBeU32(header, OFF_OFF_STRUCT);
    const strings_off = readBeU32(header, OFF_OFF_STRINGS);
    const version = readBeU32(header, OFF_VERSION);

    if (struct_off >= total_size or strings_off >= total_size) {
        klog.warn("RISC-V FDT: bad offsets (off_struct=%u off_strings=%u total=%u)", .{
            struct_off, strings_off, total_size,
        });
        return fallbackHartCount();
    }

    const struct_start = fdt_phys + struct_off;
    const strings_start = fdt_phys + strings_off;
    const struct_size = total_size - struct_off;

    var pos: usize = 0;
    var depth: u32 = 0;
    var in_cpus = false;
    var in_memory = false;
    var node_name: []const u8 = "";

    // 遍历 FDT 结构块
    while (pos < struct_size) {
        const token_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
        const token = readBeU32(token_p, 0);
        pos += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                var name_len: usize = 0;
                while (name_len < struct_size and token_p[pos + name_len] != 0) : (name_len += 1) {}
                node_name = if (name_len > 0) @as([]const u8, token_p[pos .. pos + name_len]) else "";
                pos += name_len + 1;
                pos = align4(pos);

                depth += 1;
                if (depth == 1) {
                    if (node_name.len >= 5 and std.mem.eql(u8, node_name[0..4], "cpus")) {
                        in_cpus = true;
                    } else if (std.mem.eql(u8, node_name, "memory")) {
                        in_memory = true;
                    }
                } else if (depth == 2 and in_cpus and node_name.len >= 5) {
                    if (std.mem.eql(u8, node_name[0..4], "hart")) {
                        parseHartProperties(struct_start, &pos, struct_size, strings_start);
                    }
                }
            },
            FDT_END_NODE => {
                if (depth == 1) {
                    in_cpus = false;
                    in_memory = false;
                }
                depth -= 1;
                if (depth == 0) break;
            },
            FDT_PROP => {
                if (pos + 8 > struct_size) break;
                const prop_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
                const prop_len = (@as(usize, prop_p[0]) << 24) | (@as(usize, prop_p[1]) << 16) |
                    (@as(usize, prop_p[2]) << 8) | @as(usize, prop_p[3]);
                pos += 8;
                const data_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
                pos += align4(prop_len);

                if (in_memory and prop_len >= 8) {
                    const nameoff = (@as(usize, prop_p[4]) << 24) | (@as(usize, prop_p[5]) << 16) |
                        (@as(usize, prop_p[6]) << 8) | @as(usize, prop_p[7]);
                    const prop_name_p: [*]const u8 = @ptrFromInt(strings_start + nameoff);
                    var pn_len: usize = 0;
                    while (pn_len < 64 and prop_name_p[pn_len] != 0) : (pn_len += 1) {}
                    const prop_name = prop_name_p[0..pn_len];

                    if (std.mem.eql(u8, prop_name, "reg")) {
                        const base = readBeU64(data_p, 0);
                        const len = readBeU64(data_p, 8);
                        _ = base;
                        if (dtb_mem_size == 0 or len > dtb_mem_size) {
                            dtb_mem_size = len;
                        }
                    }
                }
            },
            FDT_NOP => {},
            FDT_END => {
                break;
            },
            else => {
                if (token >= 0x10) pos += 4;
            },
        }
    }

    if (dtb_mem_size == 0) {
        dtb_mem_size = 256 * 1024 * 1024;
        klog.warn("RISC-V FDT: no /memory reg found, using fallback 256MiB", .{});
    }

    if (hart_count == 0) {
        klog.warn("RISC-V FDT: no hart entries found in /cpus", .{});
        return fallbackHartCount();
    }

    // 复制到 hart_ids 数组
    for (0..hart_count) |i| {
        hart_ids[i] = hart_infos[i].hartid;
    }

    klog.info("RISC-V FDT: %u harts found (v%u, DTB @0x%x)", .{
        hart_count, version, fdt_phys,
    });
    for (0..hart_count) |i| {
        klog.debug("  hart[%u]: id=%u status={s}", .{
            i, hart_infos[i].hartid, hart_infos[i].status_code,
        });
    }

    return hart_count;
}

fn parseHartProperties(struct_start: usize, pos: *usize, total_size: u32, strings_start: usize) void {
    if (hart_count >= MAX_HARTS) return;

    var hartid: u32 = 0;
    var has_hartid = false;
    var status: []const u8 = "ok";

    while (pos.* < total_size) {
        const token_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos.*);
        const token = readBeU32(token_p, 0);
        pos.* += 4;

        switch (token) {
            FDT_PROP => {
                const len = (@as(usize, token_p[0]) << 24) | (@as(usize, token_p[1]) << 16) | (@as(usize, token_p[2]) << 8) | @as(usize, token_p[3]);
                const nameoff = (@as(usize, token_p[4]) << 24) | (@as(usize, token_p[5]) << 16) | (@as(usize, token_p[6]) << 8) | @as(usize, token_p[7]);
                pos.* += 8;
                const data_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos.*);
                pos.* += align4(len);

                const name_p: [*]const u8 = @ptrFromInt(strings_start + nameoff);
                var name_len: usize = 0;
                while (name_len < 256 and name_p[name_len] != 0) : (name_len += 1) {}

                const prop_name = name_p[0..name_len];

                if (std.mem.eql(u8, prop_name, "reg")) {
                    if (len >= 8) {
                        hartid = @as(u32, @truncate(readBeU64(data_p, 0)));
                        has_hartid = true;
                    }
                } else if (std.mem.eql(u8, prop_name, "status")) {
                    if (len > 0) {
                        var i: usize = 0;
                        while (i < len and data_p[i] != 0 and i < 16) : (i += 1) {}
                        status = data_p[0..i];
                    }
                }
            },
            FDT_END_NODE => {
                pos.* -= 4; // 回退一个 token
                break;
            },
            FDT_NOP => {},
            else => {
                if (token >= 0x10) pos.* += 4;
            },
        }
    }

    const status_code: u8 = if (std.mem.eql(u8, status, "disabled")) 1 else 0;
    if (has_hartid and status_code == 0) {
        hart_infos[hart_count] = .{
            .hartid = hartid,
            .status_code = status_code,
        };
        hart_count += 1;
    }
}

fn readBeU32(p: [*]align(4) const u8, off: usize) u32 {
    return (@as(u32, p[off]) << 24) | (@as(u32, p[off + 1]) << 16) |
        (@as(u32, p[off + 2]) << 8) | @as(u32, p[off + 3]);
}

fn readBeU64(p: [*]align(4) const u8, off: usize) u64 {
    const hi = readBeU32(p, off);
    const lo = readBeU32(p, off + 4);
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

fn align4(pos: usize) usize {
    return (pos + 3) & ~@as(usize, 3);
}

/// 无 DTB 时的保守回退
fn fallbackHartCount() u32 {
    // OpenSBI 默认最多 8 个 hart；实际数量由 -smp N 决定
    // 由于没有可靠手段在无 DTB 时探测，回退为 1
    hart_count = 1;
    hart_ids[0] = 0;
    hart_infos[0] = .{ .hartid = 0, .status_code = 0 };
    klog.info("RISC-V FDT: using fallback 1 hart (no DTB)", .{});
    return 1;
}
