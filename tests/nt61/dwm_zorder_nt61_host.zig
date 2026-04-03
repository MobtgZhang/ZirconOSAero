//! 与 `user32.syncCompositorZOrderForUserWindows` 两趟 Z 序模型一致：非 topmost 表面先赋递增 z，再处理 topmost。
//! 对照：`src/subsystems/win32/user32.zig`、`docs/cn/DesktopManagerSpec.md`。
const std = @import("std");

fn surfaceZOrderTwoPass(comptime n: usize, is_topmost: *const [n]bool) [n]i16 {
    var zi: i16 = 10;
    var out: [n]i16 = .{0} ** n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (is_topmost[i]) continue;
        out[i] = zi;
        zi += 10;
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (!is_topmost[i]) continue;
        out[i] = zi;
        zi += 10;
    }
    return out;
}

test "topmost surfaces get higher z than all normals" {
    const tm = [_]bool{ false, true, false };
    const z = surfaceZOrderTwoPass(3, &tm);
    try std.testing.expect(z[1] > z[0] and z[1] > z[2]);
}

test "all normal preserves stride 10" {
    const tm = [_]bool{ false, false, false };
    const z = surfaceZOrderTwoPass(3, &tm);
    try std.testing.expectEqual(@as(i16, 10), z[0]);
    try std.testing.expectEqual(@as(i16, 20), z[1]);
    try std.testing.expectEqual(@as(i16, 30), z[2]);
}

/// 模型 `user32.placeHwndAboveInsertAfter` 跨 band：先令 `moving` 与 `anchor` 同 `is_topmost`，再赋 z。
fn zAfterCrossBandPlace(
    comptime n: usize,
    is_topmost: *[n]bool,
    moving_idx: usize,
    anchor_idx: usize,
) [n]i16 {
    if (moving_idx == anchor_idx) return surfaceZOrderTwoPass(n, is_topmost);
    is_topmost[moving_idx] = is_topmost[anchor_idx];
    return surfaceZOrderTwoPass(n, is_topmost);
}

test "cross-band SetWindowPos insert-after aligns band then topmost gets highest z" {
    var tm = [_]bool{ false, true, false }; // 0=normal, 1=topmost, 2=normal
    // 将索引 2 插到 topmost 窗(1) 之上：2 应变为 topmost 且 z 高于 0 与同 band 内其它
    const z = zAfterCrossBandPlace(3, &tm, 2, 1);
    try std.testing.expect(tm[2]); // 已与 anchor 同 band
    try std.testing.expect(z[2] > z[0]);
    try std.testing.expect(z[2] >= z[1]);
}

/// 文档镜像 `dwm_compositor.collectShellWindowSurfaceIds` 过滤（矩阵 §4.1 Flip3D）。
fn flip3dShellCollectable(visible: bool, owner_pid: u32, width: u32, height: u32, z_order: i16) bool {
    if (!visible or owner_pid == 0) return false;
    if (width < 16 or height < 16) return false;
    if (z_order >= 30000) return false;
    return true;
}

test "Flip3D shell sid filter skips tiny or non-owned surfaces" {
    try std.testing.expect(flip3dShellCollectable(true, 1, 64, 64, 100));
    try std.testing.expect(!flip3dShellCollectable(true, 0, 64, 64, 100));
    try std.testing.expect(!flip3dShellCollectable(true, 1, 8, 64, 100));
    try std.testing.expect(!flip3dShellCollectable(true, 1, 64, 64, 30000));
}

/// Learn：`HWND_NOTOPMOST` 对 **已非** topmost 的窗口不改变 Z 序；仅当此前为 topmost 时取消 topmost 并置于普通栈顶。
fn notopmostShouldReorderZ(was_topmost: bool) bool {
    return was_topmost;
}

test "HWND_NOTOPMOST Learn no-op when window not topmost" {
    try std.testing.expect(!notopmostShouldReorderZ(false));
    try std.testing.expect(notopmostShouldReorderZ(true));
}
