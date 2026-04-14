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
pub const spider_solitaire = @import("spider_solitaire.zig");
pub const freecell = @import("freecell.zig");
pub const inkball = @import("inkball.zig");
pub const purble_place = @import("purble_place.zig");
pub const mahjong_titans = @import("mahjong_titans.zig");
pub const chess_titans = @import("chess_titans.zig");
pub const game_strings = @import("game_strings.zig");

// Re-export types
pub const GameCenter = game_center.GameCenter;
pub const GameInfo = game_center.GameInfo;
pub const GameId = game_center.GameId;
pub const MinesweeperGame = minesweeper.MinesweeperGame;
pub const SolitaireGame = solitaire.SolitaireGame;
pub const HeartsGame = hearts.HeartsGame;
pub const SpiderSolitaireGame = spider_solitaire.SpiderSolitaireGame;
pub const FreeCellGame = freecell.FreeCellGame;
pub const InkBallGame = inkball.InkBallGame;
pub const PurblePlaceGame = purble_place.PurblePlaceGame;
pub const MahjongTitansGame = mahjong_titans.MahjongTitansGame;
pub const ChessTitansGame = chess_titans.ChessTitansGame;
pub const Card = spider_solitaire.Card;
pub const Suit = spider_solitaire.Suit;
pub const CardValue = spider_solitaire.CardValue;
pub const BallColor = inkball.BallColor;
pub const MiniGame = purble_place.MiniGame;
pub const TileSuit = mahjong_titans.TileSuit;
pub const PieceType = chess_titans.PieceType;
pub const PieceColor = chess_titans.PieceColor;
