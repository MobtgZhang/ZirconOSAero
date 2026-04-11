//! Desktop shell event protocol types.
//! Shared between driver-side display loop and higher desktop abstractions.

pub const MouseMovePaintHint = struct {
    needs_full_scene: bool = false,
    needs_startmenu_repaint: bool = false,
    needs_drag_repaint: bool = false,
    needs_shell_frame_repaint: bool = false,
    needs_post_drag_composite: bool = false,
    needs_caption_chrome_only: bool = false,
    cursor_shape_changed: bool = false,

    pub fn merge(a: MouseMovePaintHint, b: MouseMovePaintHint) MouseMovePaintHint {
        return .{
            .needs_full_scene = a.needs_full_scene or b.needs_full_scene,
            .needs_startmenu_repaint = a.needs_startmenu_repaint or b.needs_startmenu_repaint,
            .needs_drag_repaint = a.needs_drag_repaint or b.needs_drag_repaint,
            .needs_shell_frame_repaint = a.needs_shell_frame_repaint or b.needs_shell_frame_repaint,
            .needs_post_drag_composite = a.needs_post_drag_composite or b.needs_post_drag_composite,
            .needs_caption_chrome_only = a.needs_caption_chrome_only or b.needs_caption_chrome_only,
            .cursor_shape_changed = a.cursor_shape_changed or b.cursor_shape_changed,
        };
    }
};

pub const MouseReleasePaintHint = struct {
    needs_full_scene: bool = false,
    needs_post_drag_composite: bool = false,
};
