//! Shell UI strings — English default.
//!
//! Future integration with Windows-style language packs (MUI / NLS):
//! - Provide alternate string tables per `LangId` (e.g. `zh-CN`, `de-DE`) loaded from
//!   resource DLLs or `\\SystemRoot\\System32\\languagename\\*.mui`-style bundles.
//! - At boot, call `setActiveLang` after reading `HKLM\\SYSTEM\\CurrentControlSet\\Control\\Nls\\Language`
//!   (or a kernel stub) and point `active` to the selected table.
//! - Optional: `registerShellStrings(comptime LangId, table: ShellStringTable) void` to merge
//!   OEM/custom packs without editing this file.
//!
//! Until NLS is wired, all UI reads from `en` via `active`.

pub const LangId = enum(u8) {
    en_us = 0,
};

pub var active_lang: LangId = .en_us;

/// Call from SMSS / session setup once NLS reads the user default locale (stub until then).
pub fn setActiveLang(id: LangId) void {
    active_lang = id;
    // Future: map `id` to `zh_cn` / `de_de` string tables or load `.mui` resources.
}

/// English (US) — default table. Add `zh_cn`, `de_de`, etc. as sibling structs when adding packs.
pub const en = struct {
    pub const w2k_title_c_drive = "Local Disk (C:)";
    pub const w2k_addr_c_drive = "Local Disk (C:)";

    pub const explorer_menu = [_][]const u8{
        "File(F)", "Edit(E)", "View(V)", "Favorites(A)", "Tools(T)", "Help(H)",
    };
    pub const explorer_tools = [_][]const u8{
        "Back", "Forward", "Up", "Search", "Folders", "History",
    };
    pub const address_label = "Address(D)";
    pub const go = "Go";

    pub const file_viewer_title = "ZirconOS File Viewer";
    pub const file_label = "File:";
    pub const location_label = "Location:";
    pub const file_page_note = "(Kernel shell preview — NT-compatible binaries)";
    pub const file_page_hint = "Use the toolbar Back / Up or the link below to return.";
    pub const back_to_list = "<< Back to folder list";

    pub const folder_pane_title = "Folders";
    pub const tree_desktop = "Desktop";
    pub const tree_my_documents = "My Documents";
    pub const tree_my_computer = "My Computer";
    pub const tree_local_disk_c = "Local Disk (C:)";

    pub const col_name = "Name";
    pub const col_size = "Size";
    pub const col_type = "Type";

    pub const status_c_drive = "3 objects (2 hidden) (Free space: 21.9 GB)";
    pub const status_zero_bytes = "0 bytes";
    pub const status_my_computer = "My Computer";
    pub const status_file_props = "File properties preview";
};

/// Formats status bar line for System32 view (`"{n} objects | {path}"`).
pub fn formatFooterObjects(buf: []u8, n: u32, path: []const u8) []const u8 {
    const std = @import("std");
    return std.fmt.bufPrint(buf, "{d} objects | {s}", .{ n, path }) catch "objects";
}

/// Resolved active table. Language-pack loader should switch this to `zh_cn`, `de_de`, … when ready.
pub const active = en;
