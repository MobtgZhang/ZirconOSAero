//! 非 x86 架构占位：`isr.zig` 等仅在 x86_64 编译，此模块满足 `interrupt.zig` 的类型导出。

pub const InterruptFrame = extern struct {
    _pad: u8 = 0,
};

pub fn handle(_: *InterruptFrame) void {}
