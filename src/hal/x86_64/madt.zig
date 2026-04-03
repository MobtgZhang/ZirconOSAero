// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/madt.zig
// Purpose: 自 `acpi_core` 提供的 **MADT** 物理指针解析 Local APIC / I/O APIC；产出 **APIC ID 清单**（与 `scheduler` `MAX_SCHED_CPUS` 截断策略配合）。
//
// This is an independent clean-room implementation.
// Reference: ACPI 5.x/6.x — MADT (Multiple APIC Description Table); Intel SDM — local APIC.

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const acpi_core = @import("acpi_core.zig");

fn readU32(p: [*]align(1) const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}

/// Local APIC 寄存器区默认物理基址（MADT 可覆盖）；未解析成功时为 0xFEE00000。
pub var local_apic_mmio_phys: u32 = 0xFEE0_0000;

/// 自 MADT 中 **已启用** 的 Processor Local APIC 条目统计的逻辑 CPU 数（至少为 1）。
pub var logical_cpu_count: u32 = 1;

/// 首个 **I/O APIC** 的 MMIO 物理基址（MADT type 1）；未找到时为 0。
pub var ioapic_mmio_phys: u32 = 0;

/// 已启用 Local APIC 条目的 **APIC ID** 列表（顺序与 MADT 中一致）；`apic_id_count` 为有效前缀长度。
pub const MAX_APIC_ID_LIST: usize = 64;
pub var apic_id_count: u32 = 0;
pub var apic_ids: [MAX_APIC_ID_LIST]u8 = [_]u8{0} ** MAX_APIC_ID_LIST;

/// 启发式 BSP：**首个** flags.enabled 的 Local APIC 条目的 APIC ID（固件未必显式标记 BSP；与公开固件常见布局一致时为 APIC ID 0）。
pub var bsp_apic_id: u8 = 0;

/// 置位表示对应 APIC ID 的 Local APIC 条目存在且 **未** 启用（flags bit0=0）。
pub var disabled_lapic_mask: u64 = 0;

fn parseMadt(madt_phys: u64) void {
    apic_id_count = 0;
    bsp_apic_id = 0;
    disabled_lapic_mask = 0;
    logical_cpu_count = 1;
    ioapic_mmio_phys = 0;

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
        if (typ == 0 and elen >= 8) {
            const apic_id = h[off + 3];
            const flags = readU32(h, off + 4);
            if ((flags & 1) != 0) {
                cpus += 1;
                if (apic_id < 64) {
                    if (apic_id_count < MAX_APIC_ID_LIST) {
                        apic_ids[apic_id_count] = apic_id;
                        apic_id_count += 1;
                    }
                    if (!bsp_set) {
                        bsp_apic_id = apic_id;
                        bsp_set = true;
                    }
                }
            } else if (apic_id < 64) {
                disabled_lapic_mask |= @as(u64, 1) << @intCast(apic_id);
            }
        } else if (typ == 1 and elen >= 12 and ioapic_mmio_phys == 0) {
            ioapic_mmio_phys = readU32(h, off + 4);
        }
        off += elen;
    }
    if (cpus >= 1) logical_cpu_count = cpus;
}

/// 在 `acpi_core.initFromRsdp`（及 `acpi_pci_early.initFromRsdp`）之后调用。
pub fn loadFromAcpiCore() void {
    if (acpi_core.g_madt_phys != 0) {
        parseMadt(acpi_core.g_madt_phys);
    }
    klog.info("ACPI MADT: LAPIC MMIO phys=0x%x logical_cpus=%u IOAPIC=0x%x apic_id_count=%u bsp_apic_id=%u", .{
        local_apic_mmio_phys,
        logical_cpu_count,
        ioapic_mmio_phys,
        apic_id_count,
        bsp_apic_id,
    });
}

/// `rsdp_phys`：若 `acpi_core` 尚未初始化则先遍历 ACPI；否则仅重载 MADT。
pub fn initFromRsdp(rsdp_phys: usize) void {
    if (!acpi_core.g_rsdp_ok and rsdp_phys != 0) {
        acpi_core.initFromRsdp(rsdp_phys);
    }
    loadFromAcpiCore();
}
