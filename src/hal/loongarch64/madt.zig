// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/loongarch64/madt.zig
// Purpose: LoongArch64 MADT 解析 — Processor Local APIC（Type 0）、I/O APIC（Type 1）、
//          Liointc（Legacy PIC，Type 2）、x2APIC（Type 4）、RINTC（Type 34，LoongArch）。
//          产出 HartID 列表与逻辑 CPU 计数，供 SMP 启动使用。
//
// This is an independent clean-room implementation.
// Reference: ACPI 6.x §5.2.12 (MADT); LoongArch ACPI 适配（HWI ID = Hart ID）。

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const acpi_core = @import("acpi_core.zig");

fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

fn readU64(p: [*]align(1) const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

/// Local APIC MMIO 物理基址（MADT type 0）；未找到时回退到 LoongArch 常用默认值。
pub var local_apic_mmio_phys: u32 = 0xFEE0_0000;

/// 自 MADT 中已启用 Processor 条目统计的逻辑 CPU 数（至少为 1）。
pub var logical_cpu_count: u32 = 1;

/// 首个 I/O APIC 的 MMIO 物理基址（MADT type 1）；未找到时为 0。
pub var ioapic_mmio_phys: u32 = 0;

/// Liointc（Legacy PIC）MMIO 基址（MADT type 2）；未找到时为 0。
pub var liointc_mmio_phys: u32 = 0;

/// 已发现 HartID 列表（APIC ID 对 LoongArch 即 Hart ID）。
pub const MAX_HART_LIST: usize = 64;
pub var hart_id_count: u32 = 0;
pub var hart_ids: [MAX_HART_LIST]u32 = [_]u32{0} ** MAX_HART_LIST;

/// 启发式 BSP：首个 flags.enabled 的 Processor 条目的 Hart ID。
pub var bsp_hart_id: u32 = 0;

/// 置位表示对应 Hart ID 的 Local APIC 条目存在但未启用。
pub var disabled_hart_mask: u64 = 0;

fn addHart(hart_id: u32, enabled: bool) void {
    // 跳过重复的 HartID（MADT 中可能同时有 Type 0 和 RINTC 条目）
    for (hart_ids[0..hart_id_count]) |hid| {
        if (hid == hart_id) return;
    }
    if (enabled) {
        if (hart_id_count < MAX_HART_LIST) {
            hart_ids[hart_id_count] = hart_id;
            hart_id_count += 1;
        }
    } else if (hart_id < 64) {
        disabled_hart_mask |= @as(u64, 1) << hart_id;
    }
}

fn parseMadt(madt_phys: u64) void {
    hart_id_count = 0;
    bsp_hart_id = 0;
    disabled_hart_mask = 0;
    logical_cpu_count = 1;
    ioapic_mmio_phys = 0;
    liointc_mmio_phys = 0;

    const h: [*]align(1) const u8 = @ptrFromInt(@as(usize, @truncate(madt_phys)));
    if (!std.mem.eql(u8, h[0..4], "APIC")) return;
    const len = readU32(h, 4);
    if (len < 44) return;

    const lapic = readU32(h, 36);
    if (lapic != 0) local_apic_mmio_phys = lapic;

    var off: usize = 44;
    var cpus: u32 = 0;
    var bsp_set = false;
    while (off + 2 <= len) {
        const typ = h[off];
        const elen = h[off + 1];
        if (elen < 2 or off + elen > len) break;

        switch (typ) {
            0 => {
                // Processor Local APIC (ACPI MADT Type 0)
                // LoongArch: ACPI Processor ID = Hart ID
                if (elen >= 8) {
                    const hart_id = readU32(h, off + 4);
                    const flags = readU32(h, off + 8);
                    const enabled = (flags & 1) != 0;
                    addHart(hart_id, enabled);
                    if (enabled) {
                        cpus += 1;
                        if (!bsp_set) {
                            bsp_hart_id = hart_id;
                            bsp_set = true;
                        }
                    }
                }
            },
            1 => {
                // I/O APIC (ACPI MADT Type 1)
                if (elen >= 12 and ioapic_mmio_phys == 0) {
                    ioapic_mmio_phys = readU32(h, off + 4);
                }
            },
            2 => {
                // Liointc — Legacy PIC (ACPI MADT Type 2, LoongArch-specific)
                if (elen >= 10 and liointc_mmio_phys == 0) {
                    liointc_mmio_phys = readU32(h, off + 4);
                }
            },
            4 => {
                // Local x2APIC (ACPI MADT Type 4) — 支持超过 255 个 CPU
                // Structure: Type(1) + Length(1) + Reserved(2) + x2APIC ID(4) + Flags(4) + UID(4) = 16 bytes
                if (elen >= 20) {
                    const x2apic_id = readU32(h, off + 8);
                    const flags = readU32(h, off + 12);
                    const enabled = (flags & 1) != 0;
                    addHart(x2apic_id, enabled);
                    if (enabled) {
                        cpus += 1;
                        if (!bsp_set) {
                            bsp_hart_id = x2apic_id;
                            bsp_set = true;
                        }
                    }
                }
            },
            34 => {
                // RINTC — LoongArch 中断控制器 (ACPI MADT Type 34)
                // Structure: Type(1) + Length(1) + Reserved(2) + Hart ID(4) + UID(4) + Flags(4) = 16 bytes
                if (elen >= 16) {
                    const hart_id = readU32(h, off + 8);
                    const flags = readU32(h, off + 16);
                    const enabled = (flags & 1) != 0;
                    // RINTC 条目优先级高于 Type 0（已处理的跳过）
                    // 如果此 Hart ID 尚未记录，则添加
                    const already_seen = for (hart_ids[0..hart_id_count]) |hid| {
                        if (hid == hart_id) break true;
                    } else false;
                    if (!already_seen) {
                        addHart(hart_id, enabled);
                        if (enabled) {
                            cpus += 1;
                            if (!bsp_set) {
                                bsp_hart_id = hart_id;
                                bsp_set = true;
                            }
                        }
                    }
                }
            },
            else => {
                // 忽略其他 MADT 类型
            },
        }
        off += elen;
    }
    if (cpus >= 1) logical_cpu_count = cpus;
}

/// 在 `acpi_core.initFromRsdp` 之后调用。
pub fn loadFromAcpiCore() void {
    if (acpi_core.g_madt_phys != 0) {
        parseMadt(acpi_core.g_madt_phys);
    }
    klog.info("LA MADT: LAPIC=0x%x harts=%u IOAPIC=0x%x Liointc=0x%x bsp_hart=%u", .{
        local_apic_mmio_phys,
        logical_cpu_count,
        ioapic_mmio_phys,
        liointc_mmio_phys,
        bsp_hart_id,
    });
}

/// rsdp_phys: 若 acpi_core 未初始化则先遍历；否则仅重载 MADT。
pub fn initFromRsdp(rsdp_phys: usize) void {
    if (!acpi_core.g_rsdp_ok and rsdp_phys != 0) {
        acpi_core.initFromRsdp(rsdp_phys);
    }
    loadFromAcpiCore();
}
