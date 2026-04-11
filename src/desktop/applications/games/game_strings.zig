// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/games/game_strings.zig
// Purpose: Game UI strings
//
// This is an independent clean-room implementation.

pub const GameStrings = struct {
    pub const en = struct {
        pub const game_center_title = "Games";
        pub const start_game = "Start Game";
        pub const view_details = "View Details";
        pub const how_to_play = "How to Play";
        pub const high_scores = "High Scores";
        pub const new_game = "New Game";
        pub const game_over = "Game Over";
        pub const you_win = "You Win!";
        pub const score = "Score";
        pub const time = "Time";
        pub const moves = "Moves";
    };

    pub const zh_cn = struct {
        pub const game_center_title = "游戏";
        pub const start_game = "开始游戏";
        pub const view_details = "查看详情";
        pub const how_to_play = "游戏帮助";
        pub const high_scores = "最高分";
        pub const new_game = "新游戏";
        pub const game_over = "游戏结束";
        pub const you_win = "你赢了!";
        pub const score = "分数";
        pub const time = "时间";
        pub const moves = "步数";
    };
};

pub var active_lang: enum { en, zh_cn } = .en;

pub fn gameString(comptime field: []const u8) []const u8 {
    if (active_lang == .zh_cn) {
        return @field(GameStrings.zh_cn, field);
    }
    return @field(GameStrings.en, field);
}
