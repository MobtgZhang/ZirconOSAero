//! LoongArch64 线程初始上下文与 `loongarch_switch_context`（见 `context_switch.S`）。

pub const LaThreadContext = extern struct {
    ra: u64,
    fp: u64,
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    sp: u64,
};

pub extern fn loongarch_switch_context(from: *LaThreadContext, to: *LaThreadContext) callconv(.c) void;

pub fn trampolineAddr() usize {
    return asm volatile ("la.local %[o], loongarch_thread_trampoline"
        : [o] "=r" (-> usize),
    );
}

/// 新内核线程：栈顶 `stack_top` 已 16 字节对齐；入口 `entry` 为 noreturn 风格。
pub fn initNewThread(ctx: *LaThreadContext, entry: u64, stack_top: usize) void {
    var sp = stack_top;
    sp -= 8;
    @as(*align(8) u64, @ptrFromInt(sp)).* = entry;
    ctx.* = .{
        .ra = trampolineAddr(),
        .fp = 0,
        .s0 = 0,
        .s1 = 0,
        .s2 = 0,
        .s3 = 0,
        .s4 = 0,
        .s5 = 0,
        .s6 = 0,
        .s7 = 0,
        .s8 = 0,
        .sp = sp,
    };
}
