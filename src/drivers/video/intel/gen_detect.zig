//! PCI device id → Intel graphics generation（粗粒度，供表驱动分派）
//! 参考 Linux `i915_pci.c` / pci.ids；10 代酷睿含 Ice Lake（Gen11）与 Comet Lake（多为 Gen9.5）。

const types = @import("types.zig");

pub fn generationFromDeviceId(did: u16) types.IntelGpuGeneration {
    // Gen11 — Ice Lake 等（8Axx）
    if (did >= 0x8A40 and did <= 0x8A7F) return .gen11;
    // Gen12+ — Tiger Lake 起（9Axx、A7xx 等），本驱动仅标记为 gen12_plus
    if (did >= 0x9A40 and did <= 0x9AFF) return .gen12_plus;
    if (did >= 0xA720 and did <= 0xA78F) return .gen12_plus;
    if (did >= 0x4680 and did <= 0x46CF) return .gen12_plus;

    // Gen9.5 — Kaby / Coffee / Amber（590x、3E9x、31xx…）
    if (did >= 0x5900 and did <= 0x593B) return .gen9_5;
    if (did >= 0x3E90 and did <= 0x3E9C) return .gen9_5;
    if (did >= 0x3184 and did <= 0x31FF) return .gen9_5;

    // Gen9 — Skylake（190x、191x、192x、193x）
    if (did >= 0x1900 and did <= 0x193B) return .gen9;

    // Gen8 — Broadwell（160x、161x、162x）
    if (did >= 0x1600 and did <= 0x163D) return .gen8;

    // Gen7 — Ivy / Haswell（015x、016x、040x–042x）
    if (did >= 0x0150 and did <= 0x0166) return .gen7;
    if (did >= 0x0400 and did <= 0x0426) return .gen7;
    if (did >= 0x0A00 and did <= 0x0A26) return .gen7;

    // Gen6 — Sandy / Ivy bridge 部分（010x–012x）
    if (did >= 0x0100 and did <= 0x0126) return .gen6;

    return .unknown;
}
