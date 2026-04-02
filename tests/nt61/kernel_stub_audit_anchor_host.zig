//! 内核路径审计锚点：提醒维护者同步 `docs/cn/NT61_CONTRACT_MATRIX.md` 与 MVT（非自动扫描 TODO）。
//! 重点文件：`src/drivers/video/dwm_compositor.zig`、`display.zig`、`user32.zig`、`subsystem.zig`、`registry/hive.zig`。
const std = @import("std");

test "kernel desktop audit anchor (manual checklist)" {
    try std.testing.expect(true);
}
