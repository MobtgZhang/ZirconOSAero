//! Cursor shape data — kernel framebuffer rendering path.

pub const aero_cursor_shape = @import("aero_cursor_shape.zig");
pub const CursorKind = aero_cursor_shape.CursorKind;
pub const CursorPixelArray = aero_cursor_shape.shape;
pub const cursorPixels = aero_cursor_shape.pixels;
