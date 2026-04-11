//! Shared shell window drag/resize helpers.

const display_primitives = @import("../../../drivers/video/core/display/display_primitives.zig");

const pointInRectI32 = display_primitives.pointInRectI32;

pub const ResizeEdge = enum(u8) {
    none,
    n,
    s,
    e,
    w,
    ne,
    nw,
    se,
    sw,
};

pub fn hitTestFrameResizeEdge(px: i32, py: i32, rx: i32, ry: i32, rw: i32, rh: i32, hit_px: i32) ResizeEdge {
    if (rw < hit_px * 3 or rh < hit_px * 3) return .none;
    if (!pointInRectI32(px, py, rx, ry, rw, rh)) return .none;
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const rx64 = @as(i64, rx);
    const ry64 = @as(i64, ry);
    const rw64 = @as(i64, rw);
    const rh64 = @as(i64, rh);
    const hit = @as(i64, hit_px);
    const in_left = pxi < rx64 + hit;
    const in_right = pxi >= rx64 + rw64 - hit;
    const in_top = pyi < ry64 + hit;
    const in_bottom = pyi >= ry64 + rh64 - hit;
    if (!(in_left or in_right or in_top or in_bottom)) return .none;
    if (in_top and in_left) return .nw;
    if (in_top and in_right) return .ne;
    if (in_bottom and in_left) return .sw;
    if (in_bottom and in_right) return .se;
    if (in_top) return .n;
    if (in_bottom) return .s;
    if (in_left) return .w;
    if (in_right) return .e;
    return .none;
}

pub fn clampShellFrameToWorkArea(nx: *i32, ny: *i32, nw: *i32, nh: *i32, wa_x: i32, wa_y: i32, wa_w: i32, wa_h: i32, min_w: i32, min_h: i32) void {
    if (nw.* < min_w) nw.* = min_w;
    if (nh.* < min_h) nh.* = min_h;
    if (nx.* < wa_x) {
        const d = wa_x - nx.*;
        nx.* = wa_x;
        nw.* -= d;
    }
    if (ny.* < wa_y) {
        const d = wa_y - ny.*;
        ny.* = wa_y;
        nh.* -= d;
    }
    if (nx.* + nw.* > wa_x + wa_w) {
        nw.* = wa_x + wa_w - nx.*;
    }
    if (ny.* + nh.* > wa_y + wa_h) {
        nh.* = wa_y + wa_h - ny.*;
    }
    nw.* = @max(min_w, nw.*);
    nh.* = @max(min_h, nh.*);
}
