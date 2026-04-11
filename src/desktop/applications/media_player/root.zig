// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/media_player/root.zig
// Purpose: Media Player application exports
//
// This is an independent clean-room implementation.

pub const media_player = @import("media_player_main.zig");
pub const playlist = @import("playlist.zig");
pub const visualization = @import("visualization.zig");

// Re-export types
pub const MediaPlayerWindow = media_player.MediaPlayerWindow;
pub const PlayerState = media_player.PlayerState;
pub const PlaylistManager = playlist.PlaylistManager;
pub const PlaylistItem = playlist.PlaylistItem;
pub const Visualizer = visualization.Visualizer;
