// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! ZirconOS DWM Compositor - Damage Tracking

const std = @import("std");
const surface_mgr = @import("surface_mgr.zig");

// ============================================================================
// Damage Tracking
// ============================================================================

pub const DamageRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const MAX_DAMAGE_STACK: usize = 256;

pub const DamageTracker = struct {
    damage_stack: [MAX_DAMAGE_STACK]DamageRect = undefined,
    damage_count: usize = 0,

    pub fn reset(self: *DamageTracker) void {
        self.damage_count = 0;
    }

    pub fn addRect(self: *DamageTracker, x: i32, y: i32, w: i32, h: i32) void {
        if (self.damage_count >= MAX_DAMAGE_STACK) return;
        if (w <= 0 or h <= 0) return;
        self.damage_stack[self.damage_count] = .{ .x = x, .y = y, .w = w, .h = h };
        self.damage_count += 1;
    }

    pub fn addUnion(self: *DamageTracker, other: *const DamageTracker) void {
        for (other.damage_stack[0..other.damage_count]) |r| {
            self.addRect(r.x, r.y, r.w, r.h);
        }
    }

    pub fn getUnion(self: *const DamageTracker) ?DamageRect {
        if (self.damage_count == 0) return null;
        var union_rect = self.damage_stack[0];
        for (self.damage_stack[1..self.damage_count]) |r| {
            union_rect = unionRect(union_rect, r);
        }
        return union_rect;
    }

    pub fn hasOverlap(self: *const DamageTracker, rect: DamageRect) bool {
        for (self.damage_stack[0..self.damage_count]) |r| {
            if (rectsOverlap(r, rect)) return true;
        }
        return false;
    }
};

// ============================================================================
// Rect Operations
// ============================================================================

pub fn rectIntersect(a: DamageRect, b: DamageRect) DamageRect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    if (x2 <= x1 or y2 <= y1) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

pub fn unionRect(a: DamageRect, b: DamageRect) DamageRect {
    if (a.w <= 0 or a.h <= 0) return b;
    if (b.w <= 0 or b.h <= 0) return a;
    const x1 = @min(a.x, b.x);
    const y1 = @min(a.y, b.y);
    const x2 = @max(a.x + a.w, b.x + b.w);
    const y2 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

pub fn rectsOverlap(a: DamageRect, b: DamageRect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

pub fn rectContainsPoint(r: DamageRect, px: i32, py: i32) bool {
    return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
}

// ============================================================================
// Merge Algorithm (RLE-based)
// ============================================================================

pub fn mergeRects(in_rects: []const DamageRect, out_rects: []DamageRect) usize {
    if (in_rects.len == 0) return 0;
    if (out_rects.len == 0) return 0;

    var count: usize = 0;
    var current = in_rects[0];

    for (in_rects[1..]) |r| {
        if (rectsOverlap(current, r) or
            (current.y == r.y and current.h == r.h and
                (@abs(current.x + current.w - r.x) <= 4 or @abs(r.x + r.w - current.x) <= 4)))
        {
            current = unionRect(current, r);
        } else {
            if (count < out_rects.len) {
                out_rects[count] = current;
                count += 1;
            }
            current = r;
        }
    }

    if (count < out_rects.len) {
        out_rects[count] = current;
        count += 1;
    }

    return count;
}

// ============================================================================
// Global Damage Tracker
// ============================================================================

pub var g_damage_tracker: DamageTracker = .{};

pub fn resetDamage() void {
    g_damage_tracker.reset();
}

pub fn addDamageRect(x: i32, y: i32, w: i32, h: i32) void {
    g_damage_tracker.addRect(x, y, w, h);
}

pub fn getDamageUnion() ?DamageRect {
    return g_damage_tracker.getUnion();
}

pub fn initDamage() void {
    g_damage_tracker.reset();
}
