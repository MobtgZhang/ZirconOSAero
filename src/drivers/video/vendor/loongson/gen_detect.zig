const types = @import("types.zig");

pub fn generationFromDeviceId(did: u16) types.LoongsonGpuGeneration {
    return switch (did) {
        0x7a05 => .vivante_ls2k1000,
        0x7a15 => .vivante_7a1000,
        0x7a25 => .lg100_7a2000,
        else => .unknown,
    };
}
