// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/riscv64/sbi_timebase.zig
// Purpose: RISC-V64 定时器频率检测 — 从 DTB / OpenSBI 获取真实 timebase。
//
// DTB 路径: /cpus/cpu@N/timebase-frequency（通常 10MHz 或 100MHz）
// OpenSBI 通常从 DTB 获取此值，或使用默认值。
//
// This is an independent clean-room implementation.

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

/// SBI BASE EID（查询固件信息）
pub const BASE_EID: u64 = 0x0;

/// SBI BASE 函数 ID
pub const BASE_GET_SPEC_VERSION: u64 = 0;
pub const BASE_GET_IMP_ID: u64 = 1;
pub const BASE_PROBE_EXTENSION: u64 = 2;

/// 默认 timebase（QEMU virt 通常是 10MHz）
pub const DEFAULT_TIMEBASE: u64 = 10_000_000;

/// 检测到的 timebase 频率（Hz）
var detected_timebase: u64 = DEFAULT_TIMEBASE;

/// 是否已检测
var timebase_detected: bool = false;

/// 底层 SBI 调用
fn sbiCall(eid: u64, fid: u64, a0: u64, a1: u64, a2: u64) struct { err: i64, value: i64 } {
    var err: i64 = undefined;
    var val: i64 = undefined;
    asm volatile ("ecall"
        : [e] "={a0}" (err),
          [v] "={a1}" (val),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
          [a6] "{a6}" (fid),
          [a7] "{a7}" (eid),
        : .{ .memory = true });
    return .{ .err = err, .value = val };
}

/// 查询 SBI 规范版本（高位 = major，低位 = minor）
pub fn getSpecVersion() u32 {
    const ret = sbiCall(BASE_EID, BASE_GET_SPEC_VERSION, 0, 0, 0);
    if (ret.err != 0) return 0;
    return @as(u32, @truncate(@as(u64, @bitCast(ret.value))));
}

/// 查询实现者 ID
pub fn getImplementationId() u64 {
    const ret = sbiCall(BASE_EID, BASE_GET_IMP_ID, 0, 0, 0);
    if (ret.err != 0) return 0;
    return @as(u64, @bitCast(ret.value));
}

/// 检测固件是否支持特定扩展
pub fn probeExtension(eid: u64) bool {
    const ret = sbiCall(BASE_EID, BASE_PROBE_EXTENSION, eid, 0, 0);
    return ret.value != 0;
}

/// 从 DTB 获取 timebase-frequency
pub fn getTimebaseFromFdt(fdt_phys: usize) void {
    if (fdt_phys == 0) return;

    const header: [*]align(4) const u8 = @ptrFromInt(fdt_phys);

    // 读取 magic
    const magic = (@as(u32, header[0]) << 24) | (@as(u32, header[1]) << 16) |
        (@as(u32, header[2]) << 8) | @as(u32, header[3]);
    if (magic != 0xD00DFEED) return;

    _ = (@as(u32, header[4]) << 24) | (@as(u32, header[5]) << 16) |
        (@as(u32, header[6]) << 8) | @as(u32, header[7]); // total_size (unused)

    const struct_off = (@as(u32, header[8]) << 24) | (@as(u32, header[9]) << 16) |
        (@as(u32, header[10]) << 8) | @as(u32, header[11]);
    const strings_off = (@as(u32, header[12]) << 24) | (@as(u32, header[13]) << 16) |
        (@as(u32, header[14]) << 8) | @as(u32, header[15]);

    const struct_start = fdt_phys + struct_off;
    const strings_start = fdt_phys + strings_off;
    var pos: usize = 0;

    while (pos < struct_off) {
        const token_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
        const token = (@as(u32, token_p[0]) << 24) | (@as(u32, token_p[1]) << 16) |
            (@as(u32, token_p[2]) << 8) | @as(u32, token_p[3]);
        pos += 4;

        if (token == 1) { // FDT_BEGIN_NODE
            var name_len: usize = 0;
            while (token_p[name_len] != 0) : (name_len += 1) {}
            const node_name = token_p[0..name_len];
            pos += name_len + 1;
            pos = (pos + 3) & ~@as(usize, 3);

            // 查找 cpu@N 节点
            if (node_name.len >= 5 and node_name[0..4].len >= 4) {
                const prefix = node_name[0..@min(4, node_name.len)];
                if (prefix[0] == 'c' and prefix[1] == 'p' and prefix[2] == 'u' and prefix[3] == '@') {
                    // 解析属性
                    while (pos < struct_off) {
                        const t2_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
                        const t2 = (@as(u32, t2_p[0]) << 24) | (@as(u32, t2_p[1]) << 16) |
                            (@as(u32, t2_p[2]) << 8) | @as(u32, t2_p[3]);
                        pos += 4;

                        if (t2 == 2) break; // FDT_END_NODE

                        if (t2 == 3) { // FDT_PROP
                            const len = (@as(u32, t2_p[0]) << 24) | (@as(u32, t2_p[1]) << 16) |
                                (@as(u32, t2_p[2]) << 8) | @as(u32, t2_p[3]);
                            const nameoff = (@as(u32, t2_p[4]) << 24) | (@as(u32, t2_p[5]) << 16) |
                                (@as(u32, t2_p[6]) << 8) | @as(u32, t2_p[7]);
                            pos += 8;
                            const data_p: [*]align(4) const u8 = @ptrFromInt(struct_start + pos);
                            pos += (len + 3) & ~@as(usize, 3);

                            // 检查属性名
                            const name_p: [*]const u8 = @ptrFromInt(strings_start + nameoff);
                            var nl: usize = 0;
                            while (nl < 64 and name_p[nl] != 0) : (nl += 1) {}
                            const prop_name = name_p[0..nl];

                            if (prop_name.len == 16) {
                                if (prop_name[0] == 't' and prop_name[1] == 'i' and
                                    prop_name[2] == 'm' and prop_name[3] == 'e' and
                                    prop_name[4] == 'b' and prop_name[5] == 'a' and
                                    prop_name[6] == 's' and prop_name[7] == 'e' and
                                    prop_name[8] == '-' and prop_name[9] == 'f' and
                                    prop_name[10] == 'r' and prop_name[11] == 'e' and
                                    prop_name[12] == 'q')
                                {
                                    if (len >= 4) {
                                        const tb = (@as(u32, data_p[0]) << 24) |
                                            (@as(u32, data_p[1]) << 16) |
                                            (@as(u32, data_p[2]) << 8) |
                                            @as(u32, data_p[3]);
                                        detected_timebase = tb;
                                        timebase_detected = true;
                                        klog.info("RISC-V timebase: %u Hz from DTB", .{tb});
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if (token == 2) { // FDT_END_NODE
            break;
        }
    }
}

/// 初始化 timebase 检测
pub fn init(fdt_phys: usize) void {
    if (timebase_detected) return;
    if (builtin.cpu.arch != .riscv64) return;

    const spec_ver = getSpecVersion();
    klog.info("RISC-V SBI: spec v%u.%u", .{
        spec_ver >> 16, spec_ver & 0xFFFF,
    });

    const impl_id = getImplementationId();
    if (impl_id != 0) {
        klog.info("RISC-V SBI: impl_id=0x%x", .{impl_id});
    }

    // 尝试从 DTB 读取 timebase-frequency
    getTimebaseFromFdt(fdt_phys);

    if (!timebase_detected) {
        // 使用 OpenSBI 已知默认值（QEMU virt: 10MHz）
        detected_timebase = DEFAULT_TIMEBASE;
        timebase_detected = true;
        klog.info("RISC-V timebase: using default %u Hz", .{DEFAULT_TIMEBASE});
    }
}

/// 获取检测到的 timebase 频率
pub fn getTimebase() u64 {
    if (!timebase_detected) return DEFAULT_TIMEBASE;
    return detected_timebase;
}
