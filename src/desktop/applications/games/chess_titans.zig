// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/chess_titans.zig
// Purpose: Chess Titans - Simplified 3D-style chess game
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Piece types
pub const PieceType = enum {
    king,
    queen,
    rook,
    bishop,
    knight,
    pawn,
};

/// Piece color
pub const PieceColor = enum {
    white,
    black,
};

/// Chess piece
pub const Piece = struct {
    piece_type: PieceType,
    color: PieceColor,
};

/// Chess Titans game
pub const ChessTitansGame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,

    board: [8][8]?Piece,
    selected_pos: ?[2]i32,
    valid_moves: [64][2]i32,
    valid_move_count: usize,

    current_turn: PieceColor,
    white_score: i32,
    black_score: i32,
    game_over: bool,
    check: bool,
    checkmate: bool,

    hover_square: ?[2]i32,
    hover_new: bool,
    hover_undo: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) ChessTitansGame {
        var ct: ChessTitansGame = .{
            .x = x_pos,
            .y = y_pos,
            .width = 580,
            .height = 600,
            .visible = true,
            .caption_hover = .none,
            .board = undefined,
            .selected_pos = null,
            .valid_moves = undefined,
            .valid_move_count = 0,
            .current_turn = .white,
            .white_score = 0,
            .black_score = 0,
            .game_over = false,
            .check = false,
            .checkmate = false,
            .hover_square = null,
            .hover_new = false,
            .hover_undo = false,
        };
        ct.initBoard();
        return ct;
    }

    pub fn initBoard(ct: *ChessTitansGame) void {
        // Clear board
        for (&ct.board) |*row| {
            for (row) |*square| {
                square.* = null;
            }
        }

        // Set up black pieces (top)
        // Row 0 (back rank)
        ct.board[0][0] = .{ .piece_type = .rook, .color = .black };
        ct.board[0][1] = .{ .piece_type = .knight, .color = .black };
        ct.board[0][2] = .{ .piece_type = .bishop, .color = .black };
        ct.board[0][3] = .{ .piece_type = .queen, .color = .black };
        ct.board[0][4] = .{ .piece_type = .king, .color = .black };
        ct.board[0][5] = .{ .piece_type = .bishop, .color = .black };
        ct.board[0][6] = .{ .piece_type = .knight, .color = .black };
        ct.board[0][7] = .{ .piece_type = .rook, .color = .black };

        // Row 1 (pawns)
        for (0..8) |col| {
            ct.board[1][col] = .{ .piece_type = .pawn, .color = .black };
        }

        // Set up white pieces (bottom)
        // Row 6 (pawns)
        for (0..8) |col| {
            ct.board[6][col] = .{ .piece_type = .pawn, .color = .white };
        }

        // Row 7 (back rank)
        ct.board[7][0] = .{ .piece_type = .rook, .color = .white };
        ct.board[7][1] = .{ .piece_type = .knight, .color = .white };
        ct.board[7][2] = .{ .piece_type = .bishop, .color = .white };
        ct.board[7][3] = .{ .piece_type = .queen, .color = .white };
        ct.board[7][4] = .{ .piece_type = .king, .color = .white };
        ct.board[7][5] = .{ .piece_type = .bishop, .color = .white };
        ct.board[7][6] = .{ .piece_type = .knight, .color = .white };
        ct.board[7][7] = .{ .piece_type = .rook, .color = .white };

        ct.current_turn = .white;
        ct.selected_pos = null;
        ct.valid_move_count = 0;
        ct.game_over = false;
        ct.check = false;
        ct.checkmate = false;
    }

    pub fn handleSquareClick(ct: *ChessTitansGame, row: i32, col: i32) void {
        if (ct.game_over) return;
        if (row < 0 or row >= 8 or col < 0 or col >= 8) return;

        const clicked_piece = ct.board[@as(usize, @intCast(row))][@as(usize, @intCast(col))];

        if (ct.selected_pos) |sel| {
            // Check if clicking on valid move
            var is_valid_move = false;
            for (ct.valid_moves[0..ct.valid_move_count]) |move| {
                if (move[0] == row and move[1] == col) {
                    is_valid_move = true;
                    break;
                }
            }

            if (is_valid_move) {
                // Make move
                ct.makeMove(sel[0], sel[1], row, col);
                ct.selected_pos = null;
                ct.valid_move_count = 0;
            } else if (clicked_piece != null and clicked_piece.?.color == ct.current_turn) {
                // Select new piece
                ct.selected_pos = .{ row, col };
                ct.calculateValidMoves(row, col);
            } else {
                // Deselect
                ct.selected_pos = null;
                ct.valid_move_count = 0;
            }
        } else {
            // Select piece
            if (clicked_piece != null and clicked_piece.?.color == ct.current_turn) {
                ct.selected_pos = .{ row, col };
                ct.calculateValidMoves(row, col);
            }
        }
    }

    pub fn makeMove(ct: *ChessTitansGame, from_r: i32, from_c: i32, to_r: i32, to_c: i32) void {
        const piece = ct.board[@as(usize, @intCast(from_r))][@as(usize, @intCast(from_c))];
        if (piece == null) return;

        const captured = ct.board[@as(usize, @intCast(to_r))][@as(usize, @intCast(to_c))];

        // Update score
        if (captured) |cap| {
            const score_val: i32 = switch (cap.piece_type) {
                .pawn => 1,
                .knight, .bishop => 3,
                .rook => 5,
                .queen => 9,
                .king => 100,
            };
            if (cap.color == .white) {
                ct.black_score += score_val;
            } else {
                ct.white_score += score_val;
            }
        }

        // Move piece
        ct.board[@as(usize, @intCast(to_r))][@as(usize, @intCast(to_c))] = piece;
        ct.board[@as(usize, @intCast(from_r))][@as(usize, @intCast(from_c))] = null;

        // Handle pawn promotion (auto-queen)
        if (piece.?.piece_type == .pawn) {
            if ((piece.?.color == .white and to_r == 0) or
                (piece.?.color == .black and to_r == 7))
            {
                ct.board[@as(usize, @intCast(to_r))][@as(usize, @intCast(to_c))] = .{
                    .piece_type = .queen,
                    .color = piece.?.color,
                };
            }
        }

        // Switch turn
        ct.current_turn = if (ct.current_turn == .white) .black else .white;

        // Check for check/checkmate
        ct.check = ct.isInCheck(ct.current_turn);

        // Simple checkmate detection (can be enhanced)
        if (ct.check and !ct.hasValidMoves(ct.current_turn)) {
            ct.checkmate = true;
            ct.game_over = true;
        }
    }

    pub fn calculateValidMoves(ct: *ChessTitansGame, row: i32, col: i32) void {
        ct.valid_move_count = 0;

        const piece = ct.board[@as(usize, @intCast(row))][@as(usize, @intCast(col))];
        if (piece == null) return;

        switch (piece.?.piece_type) {
            .pawn => {
                const dir: i32 = if (piece.?.color == .white) -1 else 1;
                const start_row: i32 = if (piece.?.color == .white) 6 else 1;

                // Forward move
                const new_row = row + dir;
                if (new_row >= 0 and new_row < 8) {
                    if (ct.board[@as(usize, @intCast(new_row))][@as(usize, @intCast(col))] == null) {
                        ct.addValidMove(new_row, col);

                        // Double move from start
                        if (row == start_row) {
                            const new_row2 = row + 2 * dir;
                            if (ct.board[@as(usize, @intCast(new_row2))][@as(usize, @intCast(col))] == null) {
                                ct.addValidMove(new_row2, col);
                            }
                        }
                    }
                }

                // Diagonal captures
                for ([_]i32{ -1, 1 }) |dc| {
                    const new_col = col + dc;
                    if (new_col >= 0 and new_col < 8 and new_row >= 0 and new_row < 8) {
                        const target = ct.board[@as(usize, @intCast(new_row))][@as(usize, @intCast(new_col))];
                        if (target != null and target.?.color != piece.?.color) {
                            ct.addValidMove(new_row, new_col);
                        }
                    }
                }
            },

            .rook => {
                ct.addLineMoves(row, col, &[_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }, piece.?.color);
            },

            .bishop => {
                ct.addLineMoves(row, col, &[_][2]i32{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } }, piece.?.color);
            },

            .queen => {
                ct.addLineMoves(row, col, &[_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 }, .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } }, piece.?.color);
            },

            .knight => {
                for ([_][2]i32{ .{ -2, -1 }, .{ -2, 1 }, .{ -1, -2 }, .{ -1, 2 }, .{ 1, -2 }, .{ 1, 2 }, .{ 2, -1 }, .{ 2, 1 } }) |offset| {
                    const nr = row + offset[0];
                    const nc = col + offset[1];
                    if (nr >= 0 and nr < 8 and nc >= 0 and nc < 8) {
                        const target = ct.board[@as(usize, @intCast(nr))][@as(usize, @intCast(nc))];
                        if (target == null or target.?.color != piece.?.color) {
                            ct.addValidMove(nr, nc);
                        }
                    }
                }
            },

            .king => {
                for ([_][2]i32{ .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 }, .{ 0, -1 }, .{ 0, 1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 1, 1 } }) |offset| {
                    const nr = row + offset[0];
                    const nc = col + offset[1];
                    if (nr >= 0 and nr < 8 and nc >= 0 and nc < 8) {
                        const target = ct.board[@as(usize, @intCast(nr))][@as(usize, @intCast(nc))];
                        if (target == null or target.?.color != piece.?.color) {
                            ct.addValidMove(nr, nc);
                        }
                    }
                }
            },
        }
    }

    fn addValidMove(ct: *ChessTitansGame, row: i32, col: i32) void {
        if (ct.valid_move_count < ct.valid_moves.len) {
            ct.valid_moves[ct.valid_move_count] = .{ row, col };
            ct.valid_move_count += 1;
        }
    }

    fn addLineMoves(ct: *ChessTitansGame, row: i32, col: i32, dirs: []const [2]i32, color: PieceColor) void {
        for (dirs) |dir| {
            var r = row + dir[0];
            var c = col + dir[1];

            while (r >= 0 and r < 8 and c >= 0 and c < 8) {
                const target = ct.board[@as(usize, @intCast(r))][@as(usize, @intCast(c))];

                if (target == null) {
                    ct.addValidMove(r, c);
                } else if (target.?.color != color) {
                    ct.addValidMove(r, c);
                    break;
                } else {
                    break;
                }

                r += dir[0];
                c += dir[1];
            }
        }
    }

    fn isInCheck(ct: *ChessTitansGame, color: PieceColor) bool {
        // Find king
        var king_row: i32 = -1;
        var king_col: i32 = -1;

        for (0..8) |r| {
            for (0..8) |c| {
                const piece = ct.board[r][c];
                if (piece != null and piece.?.piece_type == .king and piece.?.color == color) {
                    king_row = @as(i32, @intCast(r));
                    king_col = @as(i32, @intCast(c));
                    break;
                }
            }
        }

        if (king_row < 0) return false;

        // Check if any opponent piece can capture the king
        for (0..8) |r| {
            for (0..8) |c| {
                const piece = ct.board[r][c];
                if (piece != null and piece.?.color != color) {
                    if (ct.canPieceAttack(@as(i32, @intCast(r)), @as(i32, @intCast(c)), king_row, king_col)) {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    fn canPieceAttack(ct: *ChessTitansGame, from_r: i32, from_c: i32, to_r: i32, to_c: i32) bool {
        const piece = ct.board[@as(usize, @intCast(from_r))][@as(usize, @intCast(from_c))];
        if (piece == null) return false;

        const dr = to_r - from_r;
        const dc = to_c - from_c;

        switch (piece.?.piece_type) {
            .pawn => {
                const dir: i32 = if (piece.?.color == .white) -1 else 1;
                return dr == dir and @abs(dc) == 1;
            },
            .knight => {
                return (@abs(dr) == 2 and @abs(dc) == 1) or (@abs(dr) == 1 and @abs(dc) == 2);
            },
            .king => {
                return @abs(dr) <= 1 and @abs(dc) <= 1;
            },
            .rook => {
                if (dr != 0 and dc != 0) return false;
                return ct.isPathClear(from_r, from_c, to_r, to_c);
            },
            .bishop => {
                if (@abs(dr) != @abs(dc)) return false;
                return ct.isPathClear(from_r, from_c, to_r, to_c);
            },
            .queen => {
                if (dr != 0 and dc != 0 and @abs(dr) != @abs(dc)) return false;
                return ct.isPathClear(from_r, from_c, to_r, to_c);
            },
        }
    }

    fn isPathClear(ct: *ChessTitansGame, from_r: i32, from_c: i32, to_r: i32, to_c: i32) bool {
        const dr: i32 = if (to_r > from_r) 1 else if (to_r < from_r) -1 else 0;
        const dc: i32 = if (to_c > from_c) 1 else if (to_c < from_c) -1 else 0;

        var r = from_r + dr;
        var c = from_c + dc;

        while (r != to_r or c != to_c) {
            if (ct.board[@as(usize, @intCast(r))][@as(usize, @intCast(c))] != null) {
                return false;
            }
            r += dr;
            c += dc;
        }

        return true;
    }

    fn hasValidMoves(ct: *ChessTitansGame, color: PieceColor) bool {
        for (0..8) |r| {
            for (0..8) |c| {
                const piece = ct.board[r][c];
                if (piece != null and piece.?.color == color) {
                    ct.calculateValidMoves(@as(i32, @intCast(r)), @as(i32, @intCast(c)));
                    if (ct.valid_move_count > 0) return true;
                }
            }
        }
        return false;
    }

    pub fn render(ct: *ChessTitansGame, t: *const theme_mod.ThemeColors) void {
        if (!ct.visible) return;
        _ = t;

        const wx = ct.x;
        const wy = ct.y;
        const ww = ct.width;
        const wh = ct.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x40, 0x40, 0x60), rgb(0x60, 0x60, 0x80));
        fb.drawTextTransparent(wx + 8, wy + 6, "Chess Titans", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (ct.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Draw board
        const board_size: i32 = 480;
        const square_size: i32 = board_size / 8;
        const board_x = wx + (ww - board_size) / 2;
        const board_y = wy + 40;

        // Board background
        fb.fillRect(board_x, board_y, board_size, board_size, rgb(0x60, 0x50, 0x40));
        fb.draw3DRect(board_x, board_y, board_size, board_size, rgb(0x40, 0x30, 0x20), rgb(0x80, 0x70, 0x60));

        // Draw squares
        for (0..8) |row| {
            for (0..8) |col| {
                const sq_x = board_x + @as(i32, @intCast(col)) * square_size;
                const sq_y = board_y + @as(i32, @intCast(row)) * square_size;

                const is_light = (row + col) % 2 == 0;
                var square_color: u32 = if (is_light) rgb(0xF0, 0xD0, 0xB0) else rgb(0xB0, 0x70, 0x40);

                // Highlight selected square
                if (ct.selected_pos) |sel| {
                    if (row == @as(usize, @intCast(sel[0])) and col == @as(usize, @intCast(sel[1]))) {
                        square_color = rgb(0xE0, 0xE0, 0x80);
                    }
                }

                // Highlight valid moves
                for (ct.valid_moves[0..ct.valid_move_count]) |move| {
                    if (row == @as(usize, @intCast(move[0])) and col == @as(usize, @intCast(move[1]))) {
                        if (ct.board[row][col] != null) {
                            square_color = rgb(0xFF, 0x80, 0x80); // Capture square
                        } else {
                            square_color = rgb(0xC0, 0xE0, 0xA0); // Move square
                        }
                    }
                }

                // Highlight hover
                if (ct.hover_square) |hov| {
                    if (row == @as(usize, @intCast(hov[0])) and col == @as(usize, @intCast(hov[1]))) {
                        if (square_color != rgb(0xE0, 0xE0, 0x80)) {
                            square_color = rgb(0xD0, 0xD0, 0xB0);
                        }
                    }
                }

                fb.fillRect(sq_x, sq_y, square_size, square_size, square_color);
            }
        }

        // Draw pieces
        for (0..8) |row| {
            for (0..8) |col| {
                const piece = ct.board[row][col];
                if (piece != null) {
                    const sq_x = board_x + @as(i32, @intCast(col)) * square_size;
                    const sq_y = board_y + @as(i32, @intCast(row)) * square_size;
                    const cx = sq_x + square_size / 2;
                    const cy = sq_y + square_size / 2;

                    const piece_color = if (piece.?.color == .white) rgb(0xFF, 0xFF, 0xFF) else rgb(0x20, 0x20, 0x20);
                    const outline_color = if (piece.?.color == .white) rgb(0x60, 0x60, 0x60) else rgb(0xE0, 0xE0, 0xE0);

                    const symbol: []const u8 = switch (piece.?.piece_type) {
                        .king => if (piece.?.color == .white) "K" else "k",
                        .queen => if (piece.?.color == .white) "Q" else "q",
                        .rook => if (piece.?.color == .white) "R" else "r",
                        .bishop => if (piece.?.color == .white) "B" else "b",
                        .knight => if (piece.?.color == .white) "N" else "n",
                        .pawn => if (piece.?.color == .white) "P" else "p",
                    };

                    // Draw piece shadow
                    fb.fillEllipse(cx + 1, cy + 2, 18, 18, rgb(0x40, 0x40, 0x40));
                    // Draw piece body
                    fb.fillEllipse(cx, cy, 18, 18, piece_color);
                    fb.drawEllipse(cx, cy, 18, 18, outline_color);
                    // Draw symbol
                    fb.drawTextTransparent(cx - 8, cy - 10, symbol, outline_color);
                }
            }
        }

        // Status bar
        const sy = wy + wh - 60;
        fb.fillRect(wx, sy, ww, 60, rgb(0xE8, 0xE8, 0xF0));
        fb.fillRect(wx, sy, ww, 1, rgb(0xC0, 0xC0, 0xD0));

        // Turn indicator
        const turn_str = if (ct.current_turn == .white) "White's Turn" else "Black's Turn";
        const turn_color = if (ct.current_turn == .white) rgb(0xFF, 0xFF, 0xFF) else rgb(0x40, 0x40, 0x40);

        fb.fillEllipse(wx + 40, sy + 30, 15, 15, turn_color);
        fb.drawEllipse(wx + 40, sy + 30, 15, 15, rgb(0x80, 0x80, 0x80));
        fb.drawTextTransparent(wx + 65, sy + 22, turn_str, rgb(0x30, 0x30, 0x40));

        // Score
        var white_buf: [32]u8 = undefined;
        const white_str = std.fmt.bufPrint(&white_buf, "W: {d}", .{ct.white_score}) catch "";
        fb.drawTextTransparent(wx + 200, sy + 22, white_str, rgb(0x60, 0x60, 0x60));

        var black_buf: [32]u8 = undefined;
        const black_str = std.fmt.bufPrint(&black_buf, "B: {d}", .{ct.black_score}) catch "";
        fb.drawTextTransparent(wx + 200, sy + 38, black_str, rgb(0x60, 0x60, 0x60));

        // New Game button
        const btn_x = wx + ww - 120;
        const btn_y = sy + 15;
        const btn_w: i32 = 100;
        const btn_h: i32 = 30;

        const new_color = if (ct.hover_new) rgb(0x80, 0xD0, 0x80) else rgb(0x60, 0xB0, 0x60);
        fb.fillRect(btn_x, btn_y, btn_w, btn_h, new_color);
        fb.draw3DRect(btn_x, btn_y, btn_w, btn_h, rgb(0x40, 0x90, 0x40), rgb(0x80, 0xE0, 0x80));
        fb.drawTextTransparent(btn_x + 25, btn_y + 8, "New Game", rgb(0x20, 0x40, 0x20));

        // Check / Checkmate indicator
        if (ct.checkmate) {
            fb.fillRect(wx + 300, sy + 10, 180, 40, rgb(0xFF, 0xE0, 0xE0));
            fb.draw3DRect(wx + 300, sy + 10, 180, 40, rgb(0xE0, 0xA0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            const winner = if (ct.current_turn == .white) "Black" else "White";
            var check_buf: [64]u8 = undefined;
            const check_str = std.fmt.bufPrint(&check_buf, "Checkmate! {s} wins!", .{winner}) catch "";
            fb.drawTextTransparent(wx + 310, sy + 22, check_str, rgb(0x80, 0x00, 0x00));
        } else if (ct.check) {
            fb.fillRect(wx + 300, sy + 10, 180, 40, rgb(0xFF, 0xF0, 0xD0));
            fb.draw3DRect(wx + 300, sy + 10, 180, 40, rgb(0xE0, 0xC0, 0xA0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(wx + 320, sy + 22, "Check!", rgb(0xC0, 0x40, 0x00));
        }
    }
};

fn abs(n: i32) i32 {
    return if (n < 0) -n else n;
}

fn sign(n: i32) i32 {
    return if (n < 0) -1 else if (n > 0) 1 else 0;
}
