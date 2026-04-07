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
