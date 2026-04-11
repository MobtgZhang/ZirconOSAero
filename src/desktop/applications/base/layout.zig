// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/base/layout.zig
// Purpose: Layout managers for UI controls
//
// This is an independent clean-room implementation.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.width and py >= r.y and py < r.y + r.height;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x1 = @max(a.x, b.x);
        const y1 = @max(a.y, b.y);
        const x2 = @min(a.x + a.width, b.x + b.width);
        const y2 = @min(a.y + a.height, b.y + b.height);
        return .{
            .x = x1,
            .y = y1,
            .width = @max(0, x2 - x1),
            .height = @max(0, y2 - y1),
        };
    }

    pub fn empty() Rect {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const LayoutOrientation = enum { horizontal, vertical };

pub const Layout = struct {
    margin_left: i32,
    margin_right: i32,
    margin_top: i32,
    margin_bottom: i32,
    spacing: i32,
    enabled: bool,

    pub fn createMargin(l: *Layout, left: i32, top: i32, right: i32, bottom: i32) void {
        l.margin_left = left;
        l.margin_top = top;
        l.margin_right = right;
        l.margin_bottom = bottom;
    }

    pub fn setSpacing(l: *Layout, s: i32) void {
        l.spacing = s;
    }

    pub fn getContentRect(l: *const Layout, parent: Rect) Rect {
        return .{
            .x = parent.x + l.margin_left,
            .y = parent.y + l.margin_top,
            .width = parent.width - l.margin_left - l.margin_right,
            .height = parent.height - l.margin_top - l.margin_bottom,
        };
    }
};

/// Base interface for all layoutable widgets
pub const WidgetInterface = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    enabled: bool,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
    layout_flags: u32,

    pub const FLAG_EXPAND_H = 1 << 0;
    pub const FLAG_EXPAND_V = 1 << 1;
    pub const FLAG_FILL_H = 1 << 2;
    pub const FLAG_FILL_V = 1 << 3;
};

/// Dummy widget for layout calculations
pub const LayoutWidget = struct {
    rect: Rect,
    min_size: Rect,
    alignment: u8,
    expand_horizontal: bool,
    expand_vertical: bool,
    fill_horizontal: bool,
    fill_vertical: bool,
    widget_ptr: ?*anyopaque,

    pub fn create(x: i32, y: i32, w: i32, h: i32) LayoutWidget {
        return .{
            .rect = .{ .x = x, .y = y, .width = w, .height = h },
            .min_size = .{ .x = 0, .y = 0, .width = w, .height = h },
            .alignment = 0,
            .expand_horizontal = false,
            .expand_vertical = false,
            .fill_horizontal = true,
            .fill_vertical = true,
            .widget_ptr = null,
        };
    }

    pub fn withMinSize(w: *LayoutWidget, mw: i32, mh: i32) *LayoutWidget {
        w.min_size = .{ .x = 0, .y = 0, .width = mw, .height = mh };
        return w;
    }

    pub fn withExpand(w: *LayoutWidget, horiz: bool, vert: bool) *LayoutWidget {
        w.expand_horizontal = horiz;
        w.expand_vertical = vert;
        return w;
    }

    pub fn withFill(w: *LayoutWidget, horiz: bool, vert: bool) *LayoutWidget {
        w.fill_horizontal = horiz;
        w.fill_vertical = vert;
        return w;
    }

    pub fn setRect(w: *LayoutWidget, r: Rect) void {
        w.rect = r;
    }

    pub fn preferredWidth(w: *const LayoutWidget) i32 {
        return @max(w.min_size.width, w.rect.width);
    }

    pub fn preferredHeight(w: *const LayoutWidget) i32 {
        return @max(w.min_size.height, w.rect.height);
    }
};

// ============================================================================
// BoxLayout - Horizontal or Vertical Box Layout
// ============================================================================
pub const BoxLayoutMaxItems = 32;

pub const BoxLayout = struct {
    layout: Layout,
    orientation: LayoutOrientation,
    alignment: BoxAlignment,
    items: [BoxLayoutMaxItems]LayoutWidget,
    item_count: usize,
    stretch_last: bool,
    main_axis_alignment: MainAxisAlignment,
    cross_axis_alignment: CrossAxisAlignment,

    pub const BoxAlignment = enum { start, center, end, fill };
    pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
    pub const CrossAxisAlignment = enum { start, center, end, stretch, baseline };

    pub fn create(orient: LayoutOrientation) BoxLayout {
        return .{
            .layout = .{
                .margin_left = 0,
                .margin_right = 0,
                .margin_top = 0,
                .margin_bottom = 0,
                .spacing = 4,
                .enabled = true,
            },
            .orientation = orient,
            .alignment = .fill,
            .items = undefined,
            .item_count = 0,
            .stretch_last = false,
            .main_axis_alignment = .start,
            .cross_axis_alignment = .stretch,
        };
    }

    pub fn addWidget(bl: *BoxLayout, item: LayoutWidget) void {
        if (bl.item_count < BoxLayoutMaxItems) {
            bl.items[bl.item_count] = item;
            bl.item_count += 1;
        }
    }

    pub fn addSizedWidget(bl: *BoxLayout, x: i32, y: i32, w: i32, h: i32) *LayoutWidget {
        if (bl.item_count >= BoxLayoutMaxItems) return null;
        bl.items[bl.item_count] = LayoutWidget.create(x, y, w, h);
        bl.item_count += 1;
        return &bl.items[bl.item_count - 1];
    }

    pub fn removeAll(bl: *BoxLayout) void {
        bl.item_count = 0;
    }

    pub fn invalidate(bl: *BoxLayout) void {
        // Mark layout as needing recalculation
        // In a real implementation this would trigger re-layout
        _ = bl;
    }

    pub fn layoutWidgets(bl: *BoxLayout, parent_rect: Rect) []LayoutWidget {
        const content = bl.layout.getContentRect(parent_rect);
        if (bl.item_count == 0) return bl.items[0..0];

        const spacing = bl.layout.spacing;
        const n = @as(i32, @intCast(bl.item_count));
        const total_spacing = spacing * (n - 1);

        // Calculate main axis size requirements
        var total_min_main: i32 = 0;
        var total_min_cross: i32 = 0;
        var expand_count: i32 = 0;

        for (bl.items[0..bl.item_count]) |*item| {
            if (bl.orientation == .horizontal) {
                total_min_main += item.preferredWidth();
                total_min_cross = @max(total_min_cross, item.preferredHeight());
                if (item.expand_horizontal) expand_count += 1;
            } else {
                total_min_main += item.preferredHeight();
                total_min_cross = @max(total_min_cross, item.preferredWidth());
                if (item.expand_vertical) expand_count += 1;
            }
        }

        const total_available_main = if (bl.orientation == .horizontal)
            content.width - total_spacing
        else
            content.height - total_spacing;

        const total_available_cross = if (bl.orientation == .horizontal)
            content.height
        else
            content.width;

        // Calculate stretch for expandable items
        var extra_per_expand: i32 = 0;
        if (expand_count > 0) {
            const used = total_min_main + total_spacing;
            if (used < total_available_main) {
                extra_per_expand = @divTrunc(total_available_main - used, expand_count);
            }
        }

        // Apply cross-axis alignment
        var offset_cross: i32 = 0;
        switch (bl.cross_axis_alignment) {
            .start, .baseline => offset_cross = 0,
            .center => offset_cross = @divTrunc(total_available_cross - total_min_cross, 2),
            .end => offset_cross = total_available_cross - total_min_cross,
            .stretch => {},
        }

        // Apply main-axis alignment offset
        var leading_space: i32 = 0;
        const content_main = if (bl.orientation == .horizontal) content.width else content.height;
        const used_main = total_min_main + total_spacing + extra_per_expand * expand_count;

        switch (bl.main_axis_alignment) {
            .start => leading_space = 0,
            .center => leading_space = @divTrunc(content_main - used_main, 2),
            .end => leading_space = content_main - used_main,
            .space_between, .space_around, .space_evenly => leading_space = 0,
        }

        var offset_main: i32 = leading_space;

        for (bl.items[0..bl.item_count]) |*item| {
            var item_w: i32 = undefined;
            var item_h: i32 = undefined;
            var item_x: i32 = undefined;
            var item_y: i32 = undefined;

            const is_expand = (bl.orientation == .horizontal and item.expand_horizontal) or
                (bl.orientation == .vertical and item.expand_vertical);

            if (bl.orientation == .horizontal) {
                item_w = item.preferredWidth();
                if (is_expand and extra_per_expand > 0) {
                    item_w += extra_per_expand;
                }

                if (bl.cross_axis_alignment == .stretch) {
                    item_h = total_available_cross;
                } else {
                    item_h = item.preferredHeight();
                }

                item_x = content.x + offset_main;
                item_y = content.y + offset_cross;

                offset_main += item_w + spacing;

                if (bl.cross_axis_alignment != .stretch) {
                    switch (bl.cross_axis_alignment) {
                        .end => item_y = content.y + total_available_cross - item_h,
                        .center => item_y = content.y + @divTrunc(total_available_cross - item_h, 2),
                        else => {},
                    }
                }
            } else {
                item_h = item.preferredHeight();
                if (is_expand and extra_per_expand > 0) {
                    item_h += extra_per_expand;
                }

                if (bl.cross_axis_alignment == .stretch) {
                    item_w = total_available_cross;
                } else {
                    item_w = item.preferredWidth();
                }

                item_x = content.x + offset_cross;
                item_y = content.y + offset_main;

                offset_main += item_h + spacing;

                if (bl.cross_axis_alignment != .stretch) {
                    switch (bl.cross_axis_alignment) {
                        .end => item_x = content.x + total_available_cross - item_w,
                        .center => item_x = content.x + @divTrunc(total_available_cross - item_w, 2),
                        else => {},
                    }
                }
            }

            item.setRect(.{ .x = item_x, .y = item_y, .width = item_w, .height = item_h });
        }

        return bl.items[0..bl.item_count];
    }

    pub fn minimumSize(bl: *const BoxLayout) Rect {
        var min_w: i32 = 0;
        var min_h: i32 = 0;

        for (bl.items[0..bl.item_count]) |*item| {
            if (bl.orientation == .horizontal) {
                min_w += item.preferredWidth() + bl.layout.spacing;
                min_h = @max(min_h, item.preferredHeight());
            } else {
                min_h += item.preferredHeight() + bl.layout.spacing;
                min_w = @max(min_w, item.preferredWidth());
            }
        }

        if (bl.item_count > 0) {
            if (bl.orientation == .horizontal) {
                min_w -= bl.layout.spacing;
            } else {
                min_h -= bl.layout.spacing;
            }
        }

        return .{
            .x = 0,
            .y = 0,
            .width = min_w + bl.layout.margin_left + bl.layout.margin_right,
            .height = min_h + bl.layout.margin_top + bl.layout.margin_bottom,
        };
    }
};

// ============================================================================
// GridLayout - Grid-based Layout
// ============================================================================
pub const GridLayoutMaxItems = 64;

pub const GridLayout = struct {
    layout: Layout,
    rows: i32,
    columns: i32,
    items: [GridLayoutMaxItems]GridItem,
    item_count: usize,
    row_stretch: [16]i32,
    column_stretch: [16]i32,
    default_cell_width: i32,
    default_cell_height: i32,
    cell_spacing: i32,

    pub const GridItem = struct {
        row: i32,
        column: i32,
        row_span: i32,
        column_span: i32,
        alignment: u8,
        widget: ?*anyopaque,
        preferred_size: Rect,
        rect: Rect,

        pub fn create(r: i32, c: i32) GridItem {
            return .{
                .row = r,
                .column = c,
                .row_span = 1,
                .column_span = 1,
                .alignment = 0,
                .widget = null,
                .preferred_size = .{ .x = 0, .y = 0, .width = 100, .height = 30 },
                .rect = .{ .x = 0, .y = 0, .width = 100, .height = 30 },
            };
        }
    };

    pub fn create(r: i32, c: i32) GridLayout {
        return .{
            .layout = .{
                .margin_left = 0,
                .margin_right = 0,
                .margin_top = 0,
                .margin_bottom = 0,
                .spacing = 4,
                .enabled = true,
            },
            .rows = r,
            .columns = c,
            .items = undefined,
            .item_count = 0,
            .row_stretch = undefined,
            .column_stretch = undefined,
            .default_cell_width = 100,
            .default_cell_height = 30,
            .cell_spacing = 4,
        };
    }

    pub fn createAuto(rows: i32, cols: i32) GridLayout {
        var gl = GridLayout.create(rows, cols);
        for (&gl.row_stretch, 0..) |*s, i| {
            s.* = if (i < @as(usize, @intCast(rows))) 1 else 0;
        }
        for (&gl.column_stretch, 0..) |*s, i| {
            s.* = if (i < @as(usize, @intCast(cols))) 1 else 0;
        }
        return gl;
    }

    pub fn addWidget(gl: *GridLayout, item: GridItem) void {
        if (gl.item_count < GridLayoutMaxItems) {
            gl.items[gl.item_count] = item;
            gl.item_count += 1;
        }
    }

    pub fn addItem(gl: *GridLayout, row: i32, col: i32, row_span: i32, col_span: i32, w: i32, h: i32) *GridItem {
        if (gl.item_count >= GridLayoutMaxItems) return null;
        gl.items[gl.item_count] = .{
            .row = row,
            .column = col,
            .row_span = row_span,
            .column_span = col_span,
            .alignment = 0,
            .widget = null,
            .preferred_size = .{ .x = 0, .y = 0, .width = w, .height = h },
            .rect = .{ .x = 0, .y = 0, .width = w, .height = h },
        };
        gl.item_count += 1;
        return &gl.items[gl.item_count - 1];
    }

    pub fn setRowStretch(gl: *GridLayout, row: i32, stretch: i32) void {
        if (row >= 0 and row < 16) {
            gl.row_stretch[@as(usize, @intCast(row))] = stretch;
        }
    }

    pub fn setColumnStretch(gl: *GridLayout, col: i32, stretch: i32) void {
        if (col >= 0 and col < 16) {
            gl.column_stretch[@as(usize, @intCast(col))] = stretch;
        }
    }

    pub fn layoutWidgets(gl: *GridLayout, parent_rect: Rect) []GridItem {
        const content = gl.layout.getContentRect(parent_rect);
        if (gl.rows == 0 or gl.columns == 0) return gl.items[0..0];

        const total_row_stretch: i32 = blk: {
            var total: i32 = 0;
            for (0..@as(usize, @intCast(gl.rows))) |i| {
                total += gl.row_stretch[i];
            }
            break :blk if (total == 0) gl.rows else total;
        };

        const total_col_stretch: i32 = blk: {
            var total: i32 = 0;
            for (0..@as(usize, @intCast(gl.columns))) |i| {
                total += gl.column_stretch[i];
            }
            break :blk if (total == 0) gl.columns else total;
        };

        for (gl.items[0..gl.item_count]) |item| {
            // Clamp spans to valid range
            const rs = @min(item.row_span, gl.rows - item.row);
            const cs = @min(item.column_span, gl.columns - item.column);

            const _row_stretch_span: i32 = blk: {
                var sum: i32 = 0;
                for (item.row..item.row + rs) |r| {
                    sum += gl.row_stretch[@as(usize, @intCast(r))];
                }
                break :blk if (sum == 0) rs else sum;
            };
            _ = _row_stretch_span;

            const _col_stretch_span: i32 = blk: {
                var sum: i32 = 0;
                for (item.column..item.column + cs) |c| {
                    sum += gl.column_stretch[@as(usize, @intCast(c))];
                }
                break :blk if (sum == 0) cs else sum;
            };
            _ = _col_stretch_span;

            // Calculate position
            var col_x: i32 = 0;
            var row_y: i32 = 0;
            var col_w_total: i32 = 0;
            var row_h_total: i32 = 0;

            for (0..@as(usize, @intCast(item.column))) |c| {
                col_x += @divTrunc(content.width * gl.column_stretch[c], total_col_stretch);
            }
            for (0..@as(usize, @intCast(item.row))) |r| {
                row_y += @divTrunc(content.height * gl.row_stretch[r], total_row_stretch);
            }
            for (item.column..item.column + cs) |c| {
                col_w_total += @divTrunc(content.width * gl.column_stretch[@as(usize, @intCast(c))], total_col_stretch);
            }
            for (item.row..item.row + rs) |r| {
                row_h_total += @divTrunc(content.height * gl.row_stretch[@as(usize, @intCast(r))], total_row_stretch);
            }

            item.rect = Rect{
                .x = content.x + col_x,
                .y = content.y + row_y,
                .width = col_w_total,
                .height = row_h_total,
            };
        }

        return gl.items[0..gl.item_count];
    }

    pub fn minimumSize(gl: *const GridLayout) Rect {
        if (gl.rows == 0 or gl.columns == 0) {
            return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }

        var max_col_width = [_]i32{0} ** 16;
        var max_row_height = [_]i32{0} ** 16;

        for (gl.items[0..gl.item_count]) |*item| {
            if (item.column < gl.columns) {
                max_col_width[@as(usize, @intCast(item.column))] = @max(
                    max_col_width[@as(usize, @intCast(item.column))],
                    @divTrunc(item.preferred_size.width, item.column_span),
                );
            }
            if (item.row < gl.rows) {
                max_row_height[@as(usize, @intCast(item.row))] = @max(
                    max_row_height[@as(usize, @intCast(item.row))],
                    @divTrunc(item.preferred_size.height, item.row_span),
                );
            }
        }

        var total_w: i32 = 0;
        var total_h: i32 = 0;
        for (0..@as(usize, @intCast(gl.columns))) |c| {
            total_w += max_col_width[c];
        }
        for (0..@as(usize, @intCast(gl.rows))) |r| {
            total_h += max_row_height[r];
        }

        return .{
            .x = 0,
            .y = 0,
            .width = total_w + bl: {
                var s: i32 = 0;
                for (0..@as(usize, @intCast(gl.columns - 1))) |_| s += gl.layout.spacing;
                break :bl s;
            } + gl.layout.margin_left + gl.layout.margin_right,
            .height = total_h + bl: {
                var s: i32 = 0;
                for (0..@as(usize, @intCast(gl.rows - 1))) |_| s += gl.layout.spacing;
                break :bl s;
            } + gl.layout.margin_top + gl.layout.margin_bottom,
        };
    }
};

// ============================================================================
// BorderLayout - North/South/East/West/Center Layout
// ============================================================================
pub const BorderLayoutPosition = enum { north, south, east, west, center };

pub const BorderLayout = struct {
    layout: Layout,
    north_item: ?BorderLayoutItem,
    south_item: ?BorderLayoutItem,
    east_item: ?BorderLayoutItem,
    west_item: ?BorderLayoutItem,
    center_item: ?BorderLayoutItem,

    pub const BorderLayoutItem = struct {
        widget: ?*anyopaque,
        min_size: Rect,
        max_size: Rect,
        rect: Rect,
        spacing: i32,

        pub fn create(w: i32, h: i32) BorderLayoutItem {
            return .{
                .widget = null,
                .min_size = .{ .x = 0, .y = 0, .width = w, .height = h },
                .max_size = .{ .x = 0, .y = 0, .width = 10000, .height = 10000 },
                .rect = .{ .x = 0, .y = 0, .width = w, .height = h },
                .spacing = 0,
            };
        }

        pub fn withSpacing(item: *BorderLayoutItem, s: i32) *BorderLayoutItem {
            item.spacing = s;
            return item;
        }
    };

    pub fn create() BorderLayout {
        return .{
            .layout = .{
                .margin_left = 0,
                .margin_right = 0,
                .margin_top = 0,
                .margin_bottom = 0,
                .spacing = 0,
                .enabled = true,
            },
            .north_item = null,
            .south_item = null,
            .east_item = null,
            .west_item = null,
            .center_item = null,
        };
    }

    pub fn setNorth(bl: *BorderLayout, item: BorderLayoutItem) void {
        bl.north_item = item;
    }

    pub fn setSouth(bl: *BorderLayout, item: BorderLayoutItem) void {
        bl.south_item = item;
    }

    pub fn setEast(bl: *BorderLayout, item: BorderLayoutItem) void {
        bl.east_item = item;
    }

    pub fn setWest(bl: *BorderLayout, item: BorderLayoutItem) void {
        bl.west_item = item;
    }

    pub fn setCenter(bl: *BorderLayout, item: BorderLayoutItem) void {
        bl.center_item = item;
    }

    pub fn getItem(bl: *BorderLayout, pos: BorderLayoutPosition) ?*BorderLayoutItem {
        return switch (pos) {
            .north => if (bl.north_item) |*i| i else null,
            .south => if (bl.south_item) |*i| i else null,
            .east => if (bl.east_item) |*i| i else null,
            .west => if (bl.west_item) |*i| i else null,
            .center => if (bl.center_item) |*i| i else null,
        };
    }

    pub fn removeAll(bl: *BorderLayout) void {
        bl.north_item = null;
        bl.south_item = null;
        bl.east_item = null;
        bl.west_item = null;
        bl.center_item = null;
    }

    pub fn layoutWidgets(bl: *BorderLayout, parent_rect: Rect) void {
        const content = bl.layout.getContentRect(parent_rect);
        var x = content.x;
        var y = content.y;
        var w = content.width;
        var h = content.height;

        if (bl.north_item) |*item| {
            const ih = @min(@max(item.min_size.height, 0), item.max_size.height);
            item.rect = .{ .x = x, .y = y, .width = w, .height = ih };
            y += ih + item.spacing;
            h -= ih + item.spacing;
        }

        if (bl.south_item) |*item| {
            const ih = @min(@max(item.min_size.height, 0), item.max_size.height);
            item.rect = .{ .x = x, .y = y + h - ih, .width = w, .height = ih };
            h -= ih + item.spacing;
        }

        if (bl.west_item) |*item| {
            const iw = @min(@max(item.min_size.width, 0), item.max_size.width);
            item.rect = .{ .x = x, .y = y, .width = iw, .height = h };
            x += iw + item.spacing;
            w -= iw + item.spacing;
        }

        if (bl.east_item) |*item| {
            const iw = @min(@max(item.min_size.width, 0), item.max_size.width);
            item.rect = .{ .x = x + w - iw, .y = y, .width = iw, .height = h };
            w -= iw + item.spacing;
        }

        if (bl.center_item) |*item| {
            item.rect = .{ .x = x, .y = y, .width = w, .height = h };
        }
    }

    pub fn minimumSize(bl: *const BorderLayout) Rect {
        var min_w: i32 = 0;
        var min_h: i32 = 0;

        inline for (.{ "north_item", "south_item", "center_item" }) |field| {
            const item = @field(bl, field);
            if (item) |i| {
                min_h += i.min_size.height;
                min_w = @max(min_w, i.min_size.width);
            }
        }
        if (bl.west_item) |i| {
            min_w += i.min_size.width;
            min_h = @max(min_h, i.min_size.height);
        }
        if (bl.east_item) |i| {
            min_w += i.min_size.width;
            min_h = @max(min_h, i.min_size.height);
        }

        return .{
            .x = 0,
            .y = 0,
            .width = min_w + bl.layout.margin_left + bl.layout.margin_right,
            .height = min_h + bl.layout.margin_top + bl.layout.margin_bottom,
        };
    }
};

// ============================================================================
// FlowLayout - Flow/Wrap Layout
// ============================================================================
pub const FlowLayoutMaxItems = 64;

pub const FlowLayout = struct {
    layout: Layout,
    alignment: BoxLayout.BoxAlignment,
    wrap: bool,
    items: [FlowLayoutMaxItems]Rect,
    item_count: usize,
    h_spacing: i32,
    v_spacing: i32,
    preferred_wrap_width: i32,

    pub fn create() FlowLayout {
        return .{
            .layout = .{
                .margin_left = 4,
                .margin_right = 4,
                .margin_top = 4,
                .margin_bottom = 4,
                .spacing = 4,
                .enabled = true,
            },
            .alignment = .start,
            .wrap = true,
            .items = undefined,
            .item_count = 0,
            .h_spacing = 4,
            .v_spacing = 4,
            .preferred_wrap_width = 0,
        };
    }

    pub fn addItem(fl: *FlowLayout, w: i32, h: i32) *Rect {
        if (fl.item_count >= FlowLayoutMaxItems) return null;
        fl.items[fl.item_count] = .{ .x = 0, .y = 0, .width = w, .height = h };
        fl.item_count += 1;
        return &fl.items[fl.item_count - 1];
    }

    pub fn addWidget(fl: *FlowLayout, item: Rect) void {
        if (fl.item_count < FlowLayoutMaxItems) {
            fl.items[fl.item_count] = item;
            fl.item_count += 1;
        }
    }

    pub fn removeAll(fl: *FlowLayout) void {
        fl.item_count = 0;
    }

    pub fn layoutWidgets(fl: *FlowLayout, parent_rect: Rect) []Rect {
        const content = fl.layout.getContentRect(parent_rect);
        const max_width = if (fl.preferred_wrap_width > 0)
            fl.preferred_wrap_width
        else
            content.width;

        var x = content.x;
        var y = content.y;
        var row_max_y = y;

        for (fl.items[0..fl.item_count]) |*item| {
            if (fl.wrap and x + item.width > content.x + max_width) {
                x = content.x;
                y = row_max_y + fl.v_spacing;
            }

            item.x = x;
            item.y = y;

            x += item.width + fl.h_spacing;
            row_max_y = @max(row_max_y, y + item.height);
        }

        return fl.items[0..fl.item_count];
    }

    pub fn minimumSize(fl: *const FlowLayout) Rect {
        var max_w: i32 = 0;
        var total_h: i32 = 0;
        var row_w: i32 = 0;
        var row_h: i32 = 0;

        for (fl.items[0..fl.item_count]) |*item| {
            if (row_w + item.width > max_w) {
                max_w = row_w;
            }
            row_w += item.width + fl.h_spacing;
            row_h = @max(row_h, item.height);
        }
        max_w = @max(max_w, row_w - fl.h_spacing);
        total_h += row_h;

        return .{
            .x = 0,
            .y = 0,
            .width = max_w + fl.layout.margin_left + fl.layout.margin_right,
            .height = total_h + fl.layout.margin_top + fl.layout.margin_bottom,
        };
    }
};

// ============================================================================
// StackLayout - Stacked Widget Layout
// ============================================================================
pub const StackLayoutMaxItems = 16;

pub const StackLayout = struct {
    layout: Layout,
    items: [StackLayoutMaxItems]StackItem,
    item_count: usize,
    alignment: StackAlignment,

    pub const StackItem = struct {
        rect: Rect,
        alignment: StackAlignment,
        widget: ?*anyopaque,
    };

    pub const StackAlignment = enum { top_left, top_center, top_right, center_left, center, center_right, bottom_left, bottom_center, bottom_right };

    pub fn create() StackLayout {
        return .{
            .layout = .{
                .margin_left = 0,
                .margin_right = 0,
                .margin_top = 0,
                .margin_bottom = 0,
                .spacing = 0,
                .enabled = true,
            },
            .items = undefined,
            .item_count = 0,
            .alignment = .top_left,
        };
    }

    pub fn addItem(sl: *StackLayout, w: i32, h: i32, item_align: StackAlignment) void {
        if (sl.item_count < StackLayoutMaxItems) {
            sl.items[sl.item_count] = .{
                .rect = .{ .x = 0, .y = 0, .width = w, .height = h },
                .alignment = item_align,
                .widget = null,
            };
            sl.item_count += 1;
        }
    }

    pub fn layoutWidgets(sl: *StackLayout, parent_rect: Rect) []StackItem {
        const content = sl.layout.getContentRect(parent_rect);

        for (sl.items[0..sl.item_count], 0..) |*item, idx| {
            var ax = content.x;
            var ay = content.y;

            switch (item.alignment) {
                .top_left, .center_left, .bottom_left => {},
                .top_center, .center, .bottom_center => ax = content.x + @divTrunc(content.width - item.rect.width, 2),
                .top_right, .center_right, .bottom_right => ax = content.x + content.width - item.rect.width,
            }

            switch (item.alignment) {
                .top_left, .top_center, .top_right => {},
                .center_left, .center, .center_right => ay = content.y + @divTrunc(content.height - item.rect.height, 2),
                .bottom_left, .bottom_center, .bottom_right => ay = content.y + content.height - item.rect.height,
            }

            sl.items[idx].rect = .{ .x = ax, .y = ay, .width = item.rect.width, .height = item.rect.height };
        }

        return sl.items[0..sl.item_count];
    }
};

// ============================================================================
// AnchorLayout - Anchor-based Layout (Qt-style)
// ============================================================================
pub const AnchorLayout = struct {
    layout: Layout,
    anchors: [AnchorLayoutMaxItems]Anchor,
    anchor_count: usize,

    pub const AnchorLayoutMaxItems = 32;

    pub const AnchorType = enum {
        left,
        right,
        top,
        bottom,
        center_x,
        center_y,
        width,
        height,
    };

    pub const Anchor = struct {
        item_id: usize,
        anchor_type: AnchorType,
        offset: i32,
    };

    pub const AnchorItem = struct {
        id: usize,
        rect: Rect,
        left_anchor: ?*Anchor,
        right_anchor: ?*Anchor,
        top_anchor: ?*Anchor,
        bottom_anchor: ?*Anchor,
        center_x_anchor: ?*Anchor,
        center_y_anchor: ?*Anchor,
        width_anchor: ?*Anchor,
        height_anchor: ?*Anchor,
    };

    pub fn create() AnchorLayout {
        return .{
            .layout = .{
                .margin_left = 0,
                .margin_right = 0,
                .margin_top = 0,
                .margin_bottom = 0,
                .spacing = 0,
                .enabled = true,
            },
            .anchors = undefined,
            .anchor_count = 0,
        };
    }

    pub fn layoutWidgets(al: *AnchorLayout, parent_rect: Rect) void {
        _ = al;
        _ = parent_rect;
        // Anchor layout requires item-level resolution
        // Full implementation would resolve all anchor relationships
    }
};
