// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_pm.zig
// Purpose: ACPI **S5** 关机（PM1a/PM1b_CNT）与 **FADT RESET_REG**（System I/O）复位尝试；失败时串口诊断码。AML `_S5_` 仍见 `NT61_DEFERRED_SURFACES.md`。
//
// This is an independent clean-room implementation.
// Reference: ACPI 6.x — PM1 Control Register Group、SLP_EN / SLP_TYPx；FADT RESET_REGISTER。

const portio = @import("portio.zig");
const acpi_core = @import("acpi_core.zig");
const klog = @import("../../rtl/klog.zig");
const arch_x86 = @import("../../arch/x86_64/mod.zig");

const PM1_SLP_EN: u16 = 1 << 13;
const ASSUMED_SLP_TYP_FOR_S5: u16 = 5;

/// 串口诊断：与 `STATUS_*` 无耦合，仅电源路径自检。
pub const AcpiPmDiag = enum(u32) {
    ok = 0,
    no_pm1a = 0xAC00_0001,
    pm1a_write_done = 0xAC00_0002,
    reset_no_io_gas = 0xAC00_0010,
    reset_port_written = 0xAC00_0011,
};

/// 若 `acpi_core` 已解析 **PM1a_CNT_BLK**，写 `SLP_TYP|SLP_EN`；若存在 **PM1b_CNT_BLK** 则写相同模式（仅 PM1a 固件忽略第二写）。
pub fn trySystemPowerOffAssumingS5Typ() void {
    const a = acpi_core.pm1aControlIoPort();
    if (a == 0) {
        klog.warn("ACPI PM: S5 skipped diag=0x{x} (no PM1a_CNT)", .{@intFromEnum(AcpiPmDiag.no_pm1a)});
        return;
    }
    const word: u16 = (ASSUMED_SLP_TYP_FOR_S5 << 10) | PM1_SLP_EN;
    klog.info("ACPI PM: PM1a_CNT port=0x%x write 0x%x diag=0x{x}", .{
        a,
        word,
        @intFromEnum(AcpiPmDiag.pm1a_write_done),
    });
    portio.outw(a, word);
    const b = acpi_core.pm1bControlIoPort();
    if (b != 0) {
        portio.outw(b, word);
    }
    arch_x86.disableInterrupts();
    arch_x86.halt();
}

/// FADT **RESET_REG** 为 **System I/O**（GAS space id 1）时向 `Address` 低 16 位端口写 `RESET_VALUE`；与 `arch.reset()` 异常重启路径区分（本函数仅 ACPI 表驱动）。
pub fn tryHardwareResetFromFadt() void {
    const f = acpi_core.fadtSnapshot();
    if (f.reset_gas_space_id != 1 or f.reset_gas_addr == 0) {
        klog.warn("ACPI PM: reset skipped diag=0x{x} (need FADT RESET_REG System IO)", .{
            @intFromEnum(AcpiPmDiag.reset_no_io_gas),
        });
        return;
    }
    const port: u16 = @truncate(f.reset_gas_addr);
    klog.info("ACPI PM: RESET_REG outb port=0x%x val=0x%x diag=0x{x}", .{
        port,
        f.reset_value,
        @intFromEnum(AcpiPmDiag.reset_port_written),
    });
    portio.outb(port, f.reset_value);
    arch_x86.disableInterrupts();
    arch_x86.halt();
}
