//! GMC / GART — 骨架（对称 Intel `gtt.installFramebufferGttStub`；真映射见后续里程碑）。

const klog = @import("../../../rtl/klog.zig");

pub fn installFramebufferGmcStub(mmio_phys: u64, fb_phys: u64, size: usize) bool {
    _ = mmio_phys;
    _ = fb_phys;
    _ = size;
    if (klog.DEBUG_MODE) {
        klog.info("AMD GMC: installFramebufferGmcStub (no-op; GOP handoff path)", .{});
    }
    return true;
}
