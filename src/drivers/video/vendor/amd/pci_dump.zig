//! 探测失败时的 BDF + BAR 转储（计划 D3）。

const klog = @import("../../../../rtl/klog.zig");
const pcie = @import("../../../bus/pcie.zig");

pub fn logDeviceDump(dev: *const pcie.DisplayGfxPciInfo, reason: []const u8) void {
    klog.warn("AMD display: %s — BDF %u:%u:%u VID=0x%x DID=0x%x rev=0x%x class=0x%x", .{
        reason,
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        dev.vendor_id,
        dev.device_id,
        dev.revision_id,
        dev.class_code,
    });
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const bar = dev.bars[i];
        if (bar.size == 0 and bar.base == 0) continue;
        klog.warn("AMD BAR[%u] base=0x%x size=0x%x io=%u pf=%u", .{
            i,
            bar.base,
            bar.size,
            @intFromBool(bar.is_io),
            @intFromBool(bar.prefetchable),
        });
    }
}
