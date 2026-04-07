//! LoongArch64 上运行 x86-32/x86-64 代码：须独立翻译引擎（DBT 或可选 LATX 等非微软引擎）。
//! 本模块定义引擎接口，当前返回 STATUS_NOT_IMPLEMENTED；可对接 LATX 等 clean-room 翻译器。

const klog = @import("../../../rtl/klog.zig");
const ntdll = @import("../../../libs/ntdll.zig");

/// 翻译引擎状态
pub const EngineState = enum {
    uninitialized,
    available,
    not_available,
};

var engine_state: EngineState = .uninitialized;

pub fn logBringUpStub() void {
    const lbt = @import("lbt_hw.zig");
    if (lbt.binaryTranslationExtensionsPresent()) {
        klog.info("wow64(la64): LBT hardware present; translation engine interface ready (not connected)", .{});
        engine_state = .not_available;
    } else {
        klog.info("wow64(la64): no LBT hardware; software-only DBT would be required", .{});
        engine_state = .not_available;
    }
}

pub fn translateAndExecute(x86_entry: u64, context_ptr: u64) ntdll.NTSTATUS {
    _ = x86_entry;
    _ = context_ptr;
    return ntdll.STATUS_NOT_IMPLEMENTED;
}

pub fn isEngineAvailable() bool {
    return engine_state == .available;
}

pub fn getEngineState() EngineState {
    return engine_state;
}
