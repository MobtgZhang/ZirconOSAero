//! Explorer State Manager - Windows 7 Style File Explorer
//!
//! This module manages all explorer navigation state, directory reading,
//! selection, and library functionality. Clean-room implementation based on
//! publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const vfs = @import("../../../fs/vfs.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");
const explorer_format = @import("explorer_format.zig");
const icons = @import("../icons/root.zig");
const shell_mui = @import("../strings/shell_mui.zig");

// ── Explorer View Types ──────────────────────────────────────────────────────

pub const ExplorerShellView = enum { computer, libraries };

pub const ExplorerLocation = union(enum) {
    libraries_root,
    computer_root,
    drive_root: u8,
};

pub const EXPLORER_LIST_SEL_NONE: u32 = 0xFFFF_FFFF;

// ── Navigation History ────────────────────────────────────────────────────────

const MAX_NAV_HISTORY: usize = 32;

pub const ExplorerNavEntry = struct {
    location: ExplorerLocation,
    subpath: ?[]u8 = null,
};

var explorer_nav_back_stack: [MAX_NAV_HISTORY]ExplorerNavEntry = undefined;
var explorer_nav_forward_stack: [MAX_NAV_HISTORY]ExplorerNavEntry = undefined;
var explorer_nav_back_count: usize = 0;
var explorer_nav_forward_count: usize = 0;

fn explorerPushNavHistory() void {
    if (explorer_nav_back_count < MAX_NAV_HISTORY) {
        explorer_nav_back_stack[explorer_nav_back_count] = .{
            .location = explorer_current_location,
            .subpath = if (explorer_has_subdir) explorer_subdir.path[0..explorer_subdir.path_len] else null,
        };
        explorer_nav_back_count += 1;
    }
    explorer_nav_forward_count = 0;
}

pub fn explorerCanNavigateBack() bool {
    return explorer_nav_back_count > 0;
}

pub fn explorerCanNavigateForward() bool {
    return explorer_nav_forward_count > 0;
}

pub fn explorerCanNavigateUp() bool {
    return explorer_current_location == .computer_root or explorer_has_subdir;
}

pub fn explorerNavigateBack() void {
    if (explorer_nav_back_count == 0) return;

    if (explorer_nav_forward_count < MAX_NAV_HISTORY) {
        explorer_nav_forward_stack[explorer_nav_forward_count] = .{
            .location = explorer_current_location,
            .subpath = if (explorer_has_subdir) explorer_subdir.path[0..explorer_subdir.path_len] else null,
        };
        explorer_nav_forward_count += 1;
    }

    explorer_nav_back_count -= 1;
    const entry = explorer_nav_back_stack[explorer_nav_back_count];
    applyExplorerLocation(entry.location);
}

pub fn explorerNavigateForward() void {
    if (explorer_nav_forward_count == 0) return;

    if (explorer_nav_back_count < MAX_NAV_HISTORY) {
        explorer_nav_back_stack[explorer_nav_back_count] = .{
            .location = explorer_current_location,
            .subpath = if (explorer_has_subdir) explorer_subdir.path[0..explorer_subdir.path_len] else null,
        };
        explorer_nav_back_count += 1;
    }

    explorer_nav_forward_count -= 1;
    const entry = explorer_nav_forward_stack[explorer_nav_forward_count];
    applyExplorerLocation(entry.location);
}

pub fn explorerNavigateUp() void {
    if (explorer_has_subdir) {
        explorerPushNavHistory();
        explorerNavigateUpFromSubdirectory();
    } else if (explorer_current_location == .computer_root) {
        explorerPushNavHistory();
        setExplorerView(.libraries);
    }
}

// ── Explorer State ───────────────────────────────────────────────────────────

var explorer_view_state: ExplorerShellView = .libraries;
var explorer_current_location: ExplorerLocation = .libraries_root;
var explorer_list_selected: u32 = EXPLORER_LIST_SEL_NONE;
var explorer_computer_drive_selected: u8 = 0;

// ── Subdirectory Navigation ──────────────────────────────────────────────────

const MAX_SUBDIR_DEPTH: usize = 16;

pub const ExplorerSubdirectory = struct {
    letter: u8,
    path: [256]u8,
    path_len: usize,
    path_parts: [MAX_SUBDIR_DEPTH][]const u8,
    depth: usize,
};

pub const ExplorerSubdirectoryPath = struct { letter: u8, path: []const u8 };

var explorer_subdir: ExplorerSubdirectory = .{
    .letter = 0,
    .path = undefined,
    .path_len = 0,
    .path_parts = undefined,
    .depth = 0,
};
var explorer_has_subdir: bool = false;

pub fn explorerHasSubdirectory() bool {
    return explorer_has_subdir;
}

pub fn getExplorerSubdirectoryPath() ?ExplorerSubdirectoryPath {
    if (!explorer_has_subdir) return null;
    return .{
        .letter = explorer_subdir.letter,
        .path = explorer_subdir.path[0..explorer_subdir.path_len],
    };
}

pub fn explorerNavigateToSubdirectory(letter: u8, entry_name: []const u8) void {
    if (!explorer_has_subdir or explorer_subdir.letter != letter) {
        explorer_has_subdir = true;
        explorer_subdir.letter = letter;
        explorer_subdir.path_len = 0;
        explorer_subdir.depth = 0;
    }

    if (explorer_subdir.depth >= MAX_SUBDIR_DEPTH) return;

    if (explorer_subdir.path_len > 0 and explorer_subdir.path[explorer_subdir.path_len - 1] != '\\') {
        if (explorer_subdir.path_len < explorer_subdir.path.len) {
            explorer_subdir.path[explorer_subdir.path_len] = '\\';
            explorer_subdir.path_len += 1;
        }
    }

    const name_len = @min(entry_name.len, explorer_subdir.path.len - explorer_subdir.path_len);
    @memcpy(explorer_subdir.path[explorer_subdir.path_len..][0..name_len], entry_name[0..name_len]);
    explorer_subdir.path_parts[explorer_subdir.depth] = entry_name[0..name_len];
    explorer_subdir.path_len += name_len;
    explorer_subdir.depth += 1;

    explorerPushNavHistory();
    setExplorerView(.computer);
    explorer_current_location = .{ .drive_root = letter };
    explorer_list_selected = EXPLORER_LIST_SEL_NONE;
}

pub fn explorerNavigateUpFromSubdirectory() void {
    if (!explorer_has_subdir or explorer_subdir.depth == 0) {
        explorer_has_subdir = false;
        return;
    }

    explorer_subdir.depth -= 1;

    var new_len: usize = 0;
    var i: usize = 0;
    while (i < explorer_subdir.depth) : (i += 1) {
        if (new_len > 0 and explorer_subdir.path[new_len - 1] != '\\') {
            if (new_len < explorer_subdir.path.len) {
                explorer_subdir.path[new_len] = '\\';
                new_len += 1;
            }
        }
        const part = explorer_subdir.path_parts[i];
        const copy_len = @min(part.len, explorer_subdir.path.len - new_len);
        @memcpy(explorer_subdir.path[new_len..][0..copy_len], part[0..copy_len]);
        new_len += copy_len;
    }
    explorer_subdir.path_len = new_len;

    if (explorer_subdir.depth == 0) {
        explorer_has_subdir = false;
    }
}

fn applyExplorerLocation(loc: ExplorerLocation) void {
    switch (loc) {
        .libraries_root => {
            setExplorerView(.libraries);
            explorer_has_subdir = false;
        },
        .computer_root => {
            setExplorerView(.computer);
            explorer_has_subdir = false;
            explorer_computer_drive_selected = 0;
        },
        .drive_root => |L| {
            setExplorerView(.computer);
            explorer_current_location = loc;
            explorer_has_subdir = false;
            explorer_computer_drive_selected = L;
        },
    }
    explorer_list_selected = EXPLORER_LIST_SEL_NONE;
}

// ── View and Location Setters ───────────────────────────────────────────────

pub fn setExplorerView(view: ExplorerShellView) void {
    explorer_view_state = view;
}

pub fn getExplorerView() ExplorerShellView {
    return explorer_view_state;
}

pub fn getExplorerLocation() ExplorerLocation {
    return explorer_current_location;
}

pub fn getExplorerListSelectedRow() u32 {
    return explorer_list_selected;
}

pub fn setExplorerListSelectedRow(row: u32) void {
    explorer_list_selected = row;
}

pub fn getExplorerComputerDriveSelected() u8 {
    return explorer_computer_drive_selected;
}

pub fn setExplorerComputerDriveSelected(letter: u8) void {
    explorer_computer_drive_selected = letter;
}

pub fn clearExplorerSelection() void {
    explorer_list_selected = EXPLORER_LIST_SEL_NONE;
}

// ── Libraries ────────────────────────────────────────────────────────────────

pub const ExplorerLibraryKind = enum(u8) {
    documents,
    pictures,
    videos,
    music,
};

var explorer_current_library: ExplorerLibraryKind = .documents;
var explorer_library_detail_active: bool = false;

pub fn explorerGetCurrentLibrary() ExplorerLibraryKind {
    return explorer_current_library;
}

pub fn explorerIsLibraryDetailActive() bool {
    return explorer_library_detail_active;
}

pub fn explorerNavigateToLibrary(library: ExplorerLibraryKind) void {
    explorerPushNavHistory();
    explorer_current_library = library;
    explorer_library_detail_active = true;
}

pub fn explorerCloseLibraryDetail() void {
    explorerPushNavHistory();
    explorer_library_detail_active = false;
}

// ── Sorting ─────────────────────────────────────────────────────────────────

pub const ExplorerSortField = enum(u8) {
    name,
    date,
    size,
    type_,
};

pub const ExplorerSortOrder = enum(u8) {
    ascending,
    descending,
};

var explorer_sort_field: ExplorerSortField = .name;
var explorer_sort_order: ExplorerSortOrder = .ascending;

pub fn getExplorerSortField() ExplorerSortField {
    return explorer_sort_field;
}

pub fn getExplorerSortOrder() ExplorerSortOrder {
    return explorer_sort_order;
}

pub fn setExplorerSortField(field: ExplorerSortField) void {
    if (explorer_sort_field == field) {
        explorer_sort_order = switch (explorer_sort_order) {
            .ascending => .descending,
            .descending => .ascending,
        };
    } else {
        explorer_sort_field = field;
        explorer_sort_order = .ascending;
    }
}

fn toSnapshotSortBy(field: ExplorerSortField) explorer_vol_snap.SortBy {
    return switch (field) {
        .name => .name,
        .date => .date,
        .size => .size,
        .type_ => .type_,
    };
}

fn isSortAscending(order: ExplorerSortOrder) bool {
    return order == .ascending;
}

// ── Directory Reading ────────────────────────────────────────────────────────

pub fn readExplorerDriveRootSorted(letter: u8, out: []explorer_vol_snap.ExplorerListEntry) usize {
    return explorer_vol_snap.readDirectoryGeneric(
        letter,
        null,
        out,
        toSnapshotSortBy(explorer_sort_field),
        isSortAscending(explorer_sort_order),
    );
}

pub fn readExplorerSubdirectorySorted(letter: u8, subpath: []const u8, out: []explorer_vol_snap.ExplorerListEntry) usize {
    return explorer_vol_snap.readDirectoryGeneric(
        letter,
        subpath,
        out,
        toSnapshotSortBy(explorer_sort_field),
        isSortAscending(explorer_sort_order),
    );
}

pub fn getExplorerSelectedEntry() ?explorer_vol_snap.ExplorerListEntry {
    const sel = explorer_list_selected;
    if (sel == EXPLORER_LIST_SEL_NONE) return null;

    const subpath = if (explorer_has_subdir) explorer_subdir.path[0..explorer_subdir.path_len] else null;
    const letter = switch (explorer_current_location) {
        .drive_root => |L| L,
        else => return null,
    };

    var entries: [64]explorer_vol_snap.ExplorerListEntry = undefined;
    const n = explorer_vol_snap.readDirectoryGeneric(
        letter,
        subpath,
        entries[0..],
        toSnapshotSortBy(explorer_sort_field),
        isSortAscending(explorer_sort_order),
    );

    if (sel >= n) return null;
    return entries[sel];
}

pub fn getExplorerSelectedEntrySize(buf: []u8) []const u8 {
    const entry = getExplorerSelectedEntry() orelse return "";
    return explorer_vol_snap.formatEntrySize(buf, entry.is_directory, entry.file_size);
}

// ── View Mode ────────────────────────────────────────────────────────────────

pub const ExplorerViewMode = enum(u8) {
    large_icon,
    medium_icon,
    small_icon,
    list,
    details,
    content,
};

var explorer_view_mode: ExplorerViewMode = .large_icon;

pub fn getExplorerViewMode() ExplorerViewMode {
    return explorer_view_mode;
}

pub fn setExplorerViewMode(mode: ExplorerViewMode) void {
    explorer_view_mode = mode;
}

// ── Context Menu ─────────────────────────────────────────────────────────────

pub const ExplorerContextMenuKind = enum(u8) {
    none,
    file,
    folder,
    empty_area,
    drive,
    multiple_selection,
};

var explorer_context_menu_kind: ExplorerContextMenuKind = .none;

pub fn getExplorerContextMenuKind() ExplorerContextMenuKind {
    return explorer_context_menu_kind;
}

pub fn setExplorerContextMenuKind(kind: ExplorerContextMenuKind) void {
    explorer_context_menu_kind = kind;
}

pub fn clearExplorerContextMenu() void {
    explorer_context_menu_kind = .none;
}

// ── Volume Snapshot ──────────────────────────────────────────────────────────

var explorer_vol_snapshot_buf: [vfs.MAX_MOUNT_POINTS]explorer_vol_snap.ExplorerVolume = undefined;
var explorer_vol_snapshot_count: usize = 0;

pub fn explorerEnsureVolumeSnapshot() void {
    explorer_vol_snapshot_count = explorer_vol_snap.refreshVolumes(explorer_vol_snapshot_buf[0..]);
}

pub fn explorerVolumes() []const explorer_vol_snap.ExplorerVolume {
    return explorer_vol_snapshot_buf[0..explorer_vol_snapshot_count];
}

pub fn explorerVolumeByLetter(letter: u8) ?explorer_vol_snap.ExplorerVolume {
    return explorer_vol_snap.volumeByLetter(explorer_vol_snapshot_buf[0..explorer_vol_snapshot_count], letter);
}

// ── Address Bar Helpers ──────────────────────────────────────────────────────

pub fn getExplorerAddressBarKind() explorer_format.AddressBarKind {
    return switch (explorer_view_state) {
        .libraries => .libraries,
        .computer => switch (explorer_current_location) {
            .drive_root => .drive,
            else => .computer,
        },
    };
}

pub fn getExplorerAddressDriveLetter() u8 {
    return switch (explorer_current_location) {
        .drive_root => |L| L,
        else => 'C',
    };
}

pub fn getExplorerTitleSubline(buf: []u8) []const u8 {
    return switch (explorer_view_state) {
        .libraries => "",
        .computer => switch (explorer_current_location) {
            .drive_root => |L| explorer_format.formatDriveRootPath(buf, L),
            else => "",
        },
    };
}
