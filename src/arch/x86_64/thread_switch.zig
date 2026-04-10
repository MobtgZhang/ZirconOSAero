//! x86_64 线程上下文与协作式切换。
//! 遵循 System V AMD64 ABI，但协作式切换需要保存额外寄存器。
//! 参考 Intel SDM Vol.1 第 5.4 节和 System V ABI。

const builtin = @import("builtin");

/// x86_64 线程上下文结构体，大小必须与汇编中的布局匹配 (18 u64 = 144 bytes)。
/// 使用 extern struct 确保与 C/汇编兼容。
pub const X86ThreadContext = extern struct {
    /// r15
    r15: u64,
    /// r14
    r14: u64,
    /// r13
    r13: u64,
    /// r12
    r12: u64,
    /// rbp
    rbp: u64,
    /// rbx
    rbx: u64,
    /// r11
    r11: u64,
    /// r10
    r10: u64,
    /// r9
    r9: u64,
    /// r8
    r8: u64,
    /// rax (用于保存返回值)
    rax: u64,
    /// rcx (caller-saved)
    rcx: u64,
    /// rdx (caller-saved)
    rdx: u64,
    /// rsi (caller-saved)
    rsi: u64,
    /// rdi (caller-saved)
    rdi: u64,
    /// 保留字段（用于栈对齐或其他用途）
    reserved: u64,
    /// rsp (栈指针)
    rsp: u64,
    /// 跳转目标地址 (rip)
    rip: u64,
};

comptime {
    if (@sizeOf(X86ThreadContext) != 18 * 8) {
        @compileError("X86ThreadContext size must be 18 * 8 = 144 bytes, got " ++ @typeName(X86ThreadContext));
    }
}

/// 蹦床函数地址获取。
/// freestanding 目标：使用汇编获取符号地址。
/// 其他目标：返回 0（不会使用）。
pub fn trampolineAddr() usize {
    if (builtin.target.os.tag == .freestanding) {
        return asm volatile (
            \\ lea x86_64_thread_trampoline(%rip), %[o]
            : [o] "=r" (-> usize),
        );
    }
    return 0;
}

/// 上下文切换函数。
/// freestanding 目标：从汇编获取。
/// 其他目标：提供桩函数。
pub const x86_64_switch_context = if (builtin.target.os.tag == .freestanding)
    struct {
        pub extern fn x86_64_switch_context(from: *X86ThreadContext, to: *X86ThreadContext) callconv(.c) noreturn;
    }.x86_64_switch_context
else
    struct {
        pub fn x86_64_switch_context(_: *X86ThreadContext, _: *X86ThreadContext) noreturn {
            while (true) {}
        }
    }.x86_64_switch_context;

/// 准备新内核线程的上下文。
/// 入口点 `entry` 会被压入栈顶，当 `x86_64_switch_context` 恢复时，
/// 蹦床函数会弹出这个地址并跳转到入口点。
pub fn initNewThread(ctx: *X86ThreadContext, entry: u64, stack_top: usize) void {
    var sp = stack_top;

    // 为蹦床预留返回地址槽（entry 被压入作为"返回地址"）
    sp -= 8;
    @as(*align(8) u64, @ptrFromInt(sp)).* = entry;

    ctx.* = .{
        .r15 = 0,
        .r14 = 0,
        .r13 = 0,
        .r12 = 0,
        .rbp = 0,
        .rbx = 0,
        .r11 = 0,
        .r10 = 0,
        .r9 = 0,
        .r8 = 0,
        .rax = 0,
        .rcx = 0,
        .rdx = 0,
        .rsi = 0,
        .rdi = 0,
        .reserved = 0,
        // rsp 需要保存，以便下次切换时恢复正确的栈
        .rsp = sp,
        // rip 指向蹦床函数（首次切换后从这里开始）
        .rip = trampolineAddr(),
    };
}
