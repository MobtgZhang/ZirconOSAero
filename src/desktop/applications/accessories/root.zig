// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/root.zig
// Purpose: System accessories (calculator, notepad, etc.)
//
// This is an independent clean-room implementation.

pub const calculator = @import("calculator.zig");
pub const notepad = @import("notepad.zig");
pub const char_map = @import("char_map.zig");
pub const sysinfo = @import("sysinfo.zig");
pub const paint = @import("paint.zig");
pub const snipping_tool = @import("snipping_tool.zig");
pub const cmd_shell = @import("cmd_shell.zig");
pub const task_manager = @import("task_manager.zig");
pub const wordpad = @import("wordpad.zig");
pub const on_screen_keyboard = @import("on_screen_keyboard.zig");
pub const magnifier = @import("magnifier.zig");
pub const disk_cleanup = @import("disk_cleanup.zig");
pub const sound_recorder = @import("sound_recorder.zig");
pub const disk_defrag = @import("disk_defrag.zig");
pub const sticky_notes = @import("sticky_notes.zig");
pub const accessories_strings = @import("accessories_strings.zig");

// Re-export types
pub const Calculator = calculator.Calculator;
pub const CalculatorMode = calculator.CalculatorMode;
pub const NotepadApp = notepad.NotepadApp;
pub const CharMap = char_map.CharMap;
pub const SysInfo = sysinfo.SysInfo;
pub const PaintApp = paint.PaintApp;
pub const PaintTool = paint.PaintTool;
pub const SnippingTool = snipping_tool.SnippingTool;
pub const SnipMode = snipping_tool.SnipMode;
pub const CmdShell = cmd_shell.CmdShell;
pub const TaskManager = task_manager.TaskManager;
pub const TaskManagerTab = task_manager.TaskManagerTab;
pub const WordPadWindow = wordpad.WordPadWindow;
pub const OnScreenKeyboard = on_screen_keyboard.OSKWindow;
pub const MagnifierWindow = magnifier.MagnifierWindow;
pub const DiskCleanupWindow = disk_cleanup.DiskCleanupWindow;
pub const SoundRecorderWindow = sound_recorder.SoundRecorderWindow;
pub const SoundRecorderState = sound_recorder.RecorderState;
pub const RecordingQuality = sound_recorder.RecordingQuality;
pub const AudioFormat = sound_recorder.AudioFormat;
pub const DiskDefragWindow = disk_defrag.DiskDefragWindow;
pub const StickyNotesWindow = sticky_notes.StickyNotesWindow;
pub const StickyNote = sticky_notes.StickyNote;
pub const NoteColor = sticky_notes.NoteColor;
