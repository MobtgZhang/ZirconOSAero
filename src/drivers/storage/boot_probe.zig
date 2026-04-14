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
// Purpose: 真机/CI 启动盘探测挂载：NVMe 块路径优先，否则 AHCI（与 pci_driver_bind 策略一致）。

const nvme = @import("nvme_pci.zig");
const ahci = @import("ahci.zig");

pub fn mountBootProbeIfReady() void {
    if (nvme.storageReady()) {
        nvme.mountVfsProbeIfReady();
    } else if (ahci.storageReady()) {
        ahci.mountVfsProbeIfReady();
    }
}
