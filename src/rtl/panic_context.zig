//! Debug-only last-known phase for `panicImpl` (narrow integer-overflow sites without unwinder).
//! Set via `setPhase` at desktop loop / render / input boundaries; `0` = unset.
//! 与 `zig build -Ddesktop_bisect=true` / Makefile `DESKTOP_BISECT=true` 配合：串口 pre/post render 日志与 panic 行尾 `[phase=…]` 对齐。

var last_phase: u32 = 0;

pub fn setPhase(code: u32) void {
    last_phase = code;
}

pub fn getPhase() u32 {
    return last_phase;
}
