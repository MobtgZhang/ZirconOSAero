// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/registry/regf_hive_stub.zig
// Purpose: REGF 磁盘 Hive 持久化路线图锚点；当前注册表仍为 `registry.zig` 内存树。
//
// This is an independent clean-room implementation.
// Ref: MS Learn — Registry hive format (behavioral overview only).

const regf_parse = @import("regf_parse.zig");

/// 持久化 REGF **后端**是否已接 `registry` 写路径（`registry.effectiveMutationBackend`）；**只读解析**子集见 `regf_parse.zig`。
/// 恒 `false` 直至 RegF 写路径与事务策略落地（见 `NT61_CONTRACT_MATRIX` B2）。
pub fn regfHiveBackendReady() bool {
    _ = regf_parse.minimalParserReady();
    return false;
}
