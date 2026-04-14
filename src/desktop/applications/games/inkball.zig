// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/inkball.zig
// Purpose: InkBall - Path drawing game
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Ball color
pub const BallColor = enum(u8) {
    red = 0,
    blue = 1,
    green = 2,
    yellow = 3,
    purple = 4,
};

/// Ball entity
pub const Ball = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    color: BallColor,
    radius: f32,
    active: bool,
};

/// Path point
pub const PathPoint = struct {
    x: i32,
    y: i32,
};

/// Hole (goal)
pub const Hole = struct {
    x: i32,
    y: i32,
    radius: i32,
    color: BallColor,
    filled: bool,
};

/// InkBall game
pub const InkBallGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    balls: [32]Ball,
    ball_count: usize,
    holes: [16]Hole,
    hole_count: usize,
    
    path: [4096]PathPoint,
    path_count: usize,
    is_drawing: bool,
    drawing_color: BallColor,
    
    level: u8,
    score: i32,
    lives: u8,
    game_over: bool,
    level_complete: bool,
    
    hover_new: bool,
    hover_restart: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) InkBallGame {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 640, .height = 480,
            .visible = true, .caption_hover = .none,
            .balls = undefined, .ball_count = 0,
            .holes = undefined, .hole_count = 0,
            .path = undefined, .path_count = 0,
            .is_drawing = false,
            .drawing_color = .red,
            .level = 1, .score = 0, .lives = 3,
            .game_over = false, .level_complete = false,
            .hover_new = false, .hover_restart = false,
        };
    }

    pub fn newGame(ib: *InkBallGame) void {
        ib.score = 0;
        ib.lives = 3;
        ib.level = 1;
        ib.game_over = false;
        ib.level_complete = false;
        ib.path_count = 0;
        ib.ball_count = 0;
        
        ib.initLevel();
    }

    pub fn initLevel(ib: *InkBallGame) void {
        ib.path_count = 0;
        ib.is_drawing = false;
        ib.level_complete = false;
        ib.ball_count = 0;
        
        // Create holes based on level
        ib.hole_count = 0;
        var h: usize = 0;
        while (h < @min(ib.level + 2, 16)) : (h += 1) {
            const hole_x = ib.x + 50 + @as(i32, @intCast(h * 80 % 500));
            const hole_y = ib.y + 150 + @as(i32, @intCast(h * 40 % 200));
            ib.holes[h] = .{
                .x = hole_x, .y = hole_y,
                .radius = 25,
                .color = @enumFromInt(@as(u8, @intCast(h % 5))),
                .filled = false,
            };
            ib.hole_count += 1;
        }
        
        // Create balls
        var b: usize = 0;
        while (b < @min(ib.level + 1, 32)) : (b += 1) {
            ib.balls[b] = .{
                .x = @as(f32, @floatFromInt(ib.x + 300 + (b % 3) * 30)),
                .y = @as(f32, @floatFromInt(ib.y + 50)),
                .vx = 0, .vy = 0,
                .color = @enumFromInt(@as(u8, @intCast(b % 5))),
                .radius = 12,
                .active = false,
            };
            ib.ball_count += 1;
        }
        
        // Activate first ball
        if (ib.ball_count > 0) {
            ib.balls[0].active = true;
            ib.drawing_color = ib.balls[0].color;
        }
    }

    pub fn startDrawing(ib: *InkBallGame, px: i32, py: i32) void {
        ib.is_drawing = true;
        ib.path_count = 0;
        if (ib.path_count < ib.path.len) {
            ib.path[ib.path_count] = .{ .x = px, .y = py };
            ib.path_count += 1;
        }
    }

    pub fn continueDrawing(ib: *InkBallGame, px: i32, py: i32) void {
        if (!ib.is_drawing) return;
        if (ib.path_count < ib.path.len) {
            ib.path[ib.path_count] = .{ .x = px, .y = py };
            ib.path_count += 1;
        }
    }

    pub fn endDrawing(ib: *InkBallGame) void {
        ib.is_drawing = false;
        
        // Check if path forms a valid route
        if (ib.path_count < 10) return;
        
        // Launch ball along path
        if (ib.ball_count > 0) {
            var active_ball_idx: usize = 0;
            while (active_ball_idx < ib.ball_count) : (active_ball_idx += 1) {
                if (ib.balls[active_ball_idx].active) {
                    if (ib.path_count >= 2) {
                        const start = ib.path[0];
                        const next = ib.path[1];
                        ib.balls[active_ball_idx].vx = @as(f32, @floatFromInt(next.x - start.x)) * 0.5;
                        ib.balls[active_ball_idx].vy = @as(f32, @floatFromInt(next.y - start.y)) * 0.5;
                    }
                    ib.balls[active_ball_idx].active = false;
                    break;
                }
            }
        }
    }

    pub fn tick(ib: *InkBallGame) void {
        if (ib.game_over or ib.level_complete) return;
        
        // Update ball physics
        var b: usize = 0;
        while (b < ib.ball_count) : (b += 1) {
            var ball = &ib.balls[b];
            if (ball.vx == 0 and ball.vy == 0) continue;
            
            // Apply gravity
            ball.vy += 0.1;
            
            // Update position
            ball.x += ball.vx;
            ball.y += ball.vy;
            
            // Boundary collision
            const min_x = @as(f32, @floatFromInt(ib.x));
            const max_x = @as(f32, @floatFromInt(ib.x + ib.width));
            const max_y = @as(f32, @floatFromInt(ib.y + ib.height));
            
            if (ball.x < min_x + ball.radius) {
                ball.x = min_x + ball.radius;
                ball.vx = -ball.vx * 0.8;
            }
            if (ball.x > max_x - ball.radius) {
                ball.x = max_x - ball.radius;
                ball.vx = -ball.vx * 0.8;
            }
            if (ball.y > max_y - ball.radius) {
                ball.y = max_y - ball.radius;
                ball.vy = -ball.vy * 0.8;
            }
            
            // Check hole collisions
            var h: usize = 0;
            while (h < ib.hole_count) : (h += 1) {
                const hole = &ib.holes[h];
                if (hole.filled) continue;
                
                const dx = ball.x - @as(f32, @floatFromInt(hole.x));
                const dy = ball.y - @as(f32, @floatFromInt(hole.y));
                const dist = @sqrt(dx * dx + dy * dy);
                
                if (dist < ball.radius + @as(f32, @floatFromInt(hole.radius))) {
                    if (ball.color == hole.color) {
                        hole.filled = true;
                        ib.score += 100;
                        ball.vx = 0;
                        ball.vy = 0;
                        ball.active = false;
                    } else {
                        // Wrong color - ball falls through
                        ib.lives -= 1;
                        ball.vx = 0;
                        ball.vy = 0;
                        ball.active = false;
                    }
                }
            }
            
            // Activate next ball if current stops
            if (@sqrt(ball.vx * ball.vx + ball.vy * ball.vy) < 0.5) {
                ball.vx = 0;
                ball.vy = 0;
                
                // Find next inactive ball
                var next_ball_idx: usize = b + 1;
                while (next_ball_idx < ib.ball_count) : (next_ball_idx += 1) {
                    if (!ib.balls[next_ball_idx].active) {
                        ib.balls[next_ball_idx].active = true;
                        ib.drawing_color = ib.balls[next_ball_idx].color;
                        break;
                    }
                }
            }
        }
        
        // Check for game over
        if (ib.lives == 0) {
            ib.game_over = true;
        }
        
        // Check for level complete
        var all_filled = true;
        for (ib.holes[0..ib.hole_count]) |hole| {
            if (!hole.filled) {
                all_filled = false;
                break;
            }
        }
        if (all_filled) {
            ib.level_complete = true;
            ib.score += 500;
        }
    }

    pub fn render(ib: *InkBallGame, t: *const theme_mod.ThemeColors) void {
        if (!ib.visible) return;
        _ = t;

        const wx = ib.x;
        const wy = ib.y;
        const ww = ib.width;
        const wh = ib.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "InkBall", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (ib.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Game area
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 80, rgb(0xF0, 0xF0, 0xF0));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        // Draw holes
        var h: usize = 0;
        while (h < ib.hole_count) : (h += 1) {
            const hole = ib.holes[h];
            const hole_color = switch (hole.color) {
                .red => rgb(0xE0, 0x40, 0x40),
                .blue => rgb(0x40, 0x40, 0xE0),
                .green => rgb(0x40, 0xC0, 0x40),
                .yellow => rgb(0xE0, 0xE0, 0x40),
                .purple => rgb(0xC0, 0x40, 0xC0),
            };
            
            if (hole.filled) {
                fb.fillEllipse(hole.x, hole.y, hole.radius, hole.radius, rgb(0x80, 0x80, 0x80));
            } else {
                fb.fillEllipse(hole.x, hole.y, hole.radius, hole.radius, hole_color);
                fb.drawEllipse(hole.x, hole.y, hole.radius, hole.radius, rgb(0x40, 0x40, 0x40));
            }
        }

        // Draw path
        if (ib.path_count > 1) {
            var p: usize = 1;
            while (p < ib.path_count) : (p += 1) {
                const prev = ib.path[p - 1];
                const curr = ib.path[p];
                const path_color = switch (ib.drawing_color) {
                    .red => rgb(0xE0, 0x40, 0x40),
                    .blue => rgb(0x40, 0x40, 0xE0),
                    .green => rgb(0x40, 0xC0, 0x40),
                    .yellow => rgb(0xE0, 0xE0, 0x40),
                    .purple => rgb(0xC0, 0x40, 0xC0),
                };
                fb.drawLine(prev.x, prev.y, curr.x, curr.y, path_color);
            }
        }

        // Draw balls
        var b: usize = 0;
        while (b < ib.ball_count) : (b += 1) {
            const ball = ib.balls[b];
            const ball_color = switch (ball.color) {
                .red => rgb(0xFF, 0x60, 0x60),
                .blue => rgb(0x60, 0x60, 0xFF),
                .green => rgb(0x60, 0xFF, 0x60),
                .yellow => rgb(0xFF, 0xFF, 0x60),
                .purple => rgb(0xFF, 0x60, 0xFF),
            };
            
            if (ball.vx != 0 or ball.vy != 0 or ball.active) {
                fb.fillEllipse(@intFromFloat(ball.x), @intFromFloat(ball.y), @intFromFloat(ball.radius), @intFromFloat(ball.radius), ball_color);
                fb.drawEllipse(@intFromFloat(ball.x), @intFromFloat(ball.y), @intFromFloat(ball.radius), @intFromFloat(ball.radius), rgb(0x40, 0x40, 0x40));
            }
        }

        // Status bar
        const sy = wy + wh - 45;
        fb.fillRect(wx, sy, ww, 45, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(wx, sy, ww, 1, rgb(0xC0, 0xC8, 0xD8));

        var buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&buf, "Score: {d}", .{ib.score}) catch "";
        fb.drawTextTransparent(wx + 8, sy + 8, score_str, rgb(0x40, 0x40, 0x50));

        var lives_buf: [32]u8 = undefined;
        const lives_str = std.fmt.bufPrint(&lives_buf, "Lives: {d}", .{ib.lives}) catch "";
        fb.drawTextTransparent(wx + ww - 80, sy + 8, lives_str, rgb(0x40, 0x40, 0x50));

        var level_buf: [32]u8 = undefined;
        const level_str = std.fmt.bufPrint(&level_buf, "Level: {d}", .{ib.level}) catch "";
        fb.drawTextTransparent(wx + ww / 2 - 40, sy + 8, level_str, rgb(0x40, 0x40, 0x50));

        // Game over / level complete overlay
        if (ib.game_over) {
            fb.fillRect(wx + 50, wy + 150, ww - 100, 150, rgb(0xE0, 0xE0, 0xE0));
            fb.draw3DRect(wx + 50, wy + 150, ww - 100, 150, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 60, wy + 180, "Game Over!", rgb(0xCC, 0x00, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 220, "Click Restart to try again", rgb(0x60, 0x60, 0x60));
        }

        if (ib.level_complete) {
            fb.fillRect(wx + 50, wy + 150, ww - 100, 150, rgb(0xE0, 0xF0, 0xE0));
            fb.draw3DRect(wx + 50, wy + 150, ww - 100, 150, rgb(0xC0, 0xE0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + ww/2 - 80, wy + 180, "Level Complete!", rgb(0x00, 0x80, 0x00));
            fb.drawTextTransparent(wx + ww/2 - 60, wy + 220, "Click Next Level", rgb(0x40, 0x40, 0x40));
        }
    }
};
