// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/root.zig
// Purpose: Win7 Games package
//
// This is an independent clean-room implementation.

pub const game_center = @import("game_center.zig");
pub const minesweeper = @import("minesweeper.zig");
pub const solitaire = @import("solitaire.zig");
pub const hearts = @import("hearts.zig");
pub const game_strings = @import("game_strings.zig");

// Re-export types
pub const GameCenter = game_center.GameCenter;
pub const GameInfo = game_center.GameInfo;
pub const GameId = game_center.GameId;
pub const MinesweeperGame = minesweeper.MinesweeperGame;
pub const SolitaireGame = solitaire.SolitaireGame;
pub const HeartsGame = hearts.HeartsGame;
