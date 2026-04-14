// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/root.zig
// Purpose: Built-in applications barrel export
//
// This is an independent clean-room implementation.

pub const base = @import("base/root.zig");
pub const ie_browser = @import("ie_browser/root.zig");
pub const control_panel = @import("control_panel/root.zig");
pub const games = @import("games/root.zig");
pub const accessories = @import("accessories/root.zig");
pub const media_player = @import("media_player/root.zig");

// Re-export common types
pub const AppWindow = base.AppWindow;
pub const AppEvent = base.AppEvent;
pub const AppId = base.AppId;
pub const Rect = base.Rect;
pub const Point = base.Point;
pub const Size = base.Size;

// Re-export all application types
pub const IEBrowser = ie_browser.IEBrowser;
pub const ControlPanel = control_panel.ControlPanel;
pub const GameCenter = games.GameCenter;
pub const MinesweeperGame = games.MinesweeperGame;
pub const SolitaireGame = games.SolitaireGame;
pub const HeartsGame = games.HeartsGame;
pub const Calculator = accessories.Calculator;
pub const NotepadApp = accessories.NotepadApp;
pub const PaintApp = accessories.PaintApp;
pub const CmdShell = accessories.CmdShell;
pub const TaskManager = accessories.TaskManager;
pub const MediaPlayerWindow = media_player.MediaPlayerWindow;
pub const PlayerState = media_player.PlayerState;
pub const PlaylistManager = media_player.PlaylistManager;
pub const Visualizer = media_player.Visualizer;

// Re-export P0 enhanced accessories
pub const SnippingTool = accessories.SnippingTool;
pub const SnipMode = accessories.SnipMode;
pub const WordPadWindow = accessories.WordPadWindow;
pub const SoundRecorderWindow = accessories.SoundRecorderWindow;
pub const SoundRecorderState = accessories.SoundRecorderState;
pub const RecordingQuality = accessories.RecordingQuality;
pub const AudioFormat = accessories.AudioFormat;
pub const StickyNotesWindow = accessories.StickyNotesWindow;
pub const StickyNote = accessories.StickyNote;
pub const NoteColor = accessories.NoteColor;
