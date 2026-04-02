//! 最后已知 phase（供 `panicImpl` 串口定位 integer overflow 等，无需栈回溯）。
//! `0` = 未设置；各子系统用 `setPhase`/`setPhase(0)` 成对管理。
//!
//! **与配置无关**：`src/config` 里 `build_type=debug` 只影响日志文案，**不是** Zig 的 `builtin.mode`。
//! **panic 行格式**（见 `main.zig` `panicImpl`）：`[phase=0x........]` 在 `phase!=0` 时**总是**打印（不限 Debug 优化）；
//! 另附 `[zig_opt=Debug|ReleaseSafe|…]` 标明实际编译优化。
//! 与 `zig build -Ddesktop_bisect=true` / Makefile `DESKTOP_BISECT=true` 配合：桌面 pre/post render 与 panic phase 对齐。

var last_phase: u32 = 0;

pub fn setPhase(code: u32) void {
    last_phase = code;
}

pub fn getPhase() u32 {
    return last_phase;
}
