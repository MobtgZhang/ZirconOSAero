// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/virtio_gpu_pci.zig
// Purpose: PCI probe for VirtIO-GPU (1af4:1050); logs presence for B2 milestone (queues/scanout TBD).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html (GPU device, PCI)

const klog = @import("../../rtl/klog.zig");
const pcie = @import("../bus/pcie.zig");
const spec = @import("virtio_gpu_spec.zig");

var probed_gpu: bool = false;

/// True after a successful PCI locate of 1af4:1050 (no MMIO bring-up yet).
pub fn isPresent() bool {
    return probed_gpu;
}

pub fn probe() void {
    if (!pcie.supports_pci_config) return;
    const ids = [_]u16{spec.pci_device_gpu};
    if (pcie.findDevicePci0(spec.pci_vendor_virtio, &ids)) |_| {
        probed_gpu = true;
        klog.info("VirtIO-GPU PCI: 1af4:1050 detected (control/scanout driver milestone pending; see virtio_gpu_spec.zig)", .{});
    }
}
