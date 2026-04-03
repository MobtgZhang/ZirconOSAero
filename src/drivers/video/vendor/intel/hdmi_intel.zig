//! 将 Intel iGPU 探测结果同步到 `hdmi.zig` 的连接器抽象（EDID/DDC 仍为占位）

const hdmi = @import("../../legacy/hdmi.zig");
const types = @import("types.zig");

pub fn syncConnectorFromIntel(device_id: u16, gen: types.IntelGpuGeneration) void {
    hdmi.syncIntelIgpuConnector(device_id, @intFromEnum(gen));
}
