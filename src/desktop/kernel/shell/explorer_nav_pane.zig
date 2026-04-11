//! Explorer Navigation Pane - Windows 7 Style Tree View
//!
//! Implements the Navigation Pane with expandable tree nodes for Favorites, Libraries,
//! Computer (drives), and Network. Clean-room implementation based on publicly
//! documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_format = @import("../shell/explorer_format.zig");
const shell_mui = @import("../strings/shell_mui.zig");

const rgb = theme.rgb;

// ── Navigation Tree Types ──────────────────────────────────────────────────

pub const NavNodeKind = enum(u8) {
    heading,
    favorites,
    desktop,
    downloads,
    recent,
    library_root,
    library_documents,
    library_pictures,
    library_videos,
    library_music,
    computer,
    drive,
    network,
};

pub const NavNode = struct {
    kind: NavNodeKind,
    label: []const u8,
    icon: icons.IconId,
    expanded: bool,
    indent: i32,
    child_count: usize,
};

const MAX_NAV_NODES = 32;
var nav_nodes: [MAX_NAV_NODES]NavNode = undefined;
var nav_node_count: usize = 0;

// Navigation pane state
var nav_hover_index: i32 = -1;
var nav_pane_width: i32 = 180;

// ── Navigation Tree Building ──────────────────────────────────────────────────

pub fn buildNavigationTree() void {
    nav_node_count = 0;
    
    // Favorites section
    var fav_label: [32]u8 = undefined;
    const fav_text = shell_mui.loadString(.ex_lib_nav_fav, &fav_label);
    
    nav_nodes[nav_node_count] = .{
        .kind = .heading,
        .label = fav_text,
        .icon = .favorites,
        .expanded = true,
        .indent = 0,
        .child_count = 3,
    };
    nav_node_count += 1;
    
    var desktop_label: [32]u8 = undefined;
    const desktop_text = shell_mui.loadString(.ex_lib_desktop, &desktop_label);
    nav_nodes[nav_node_count] = .{
        .kind = .desktop,
        .label = desktop_text,
        .icon = .shell_desktop,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    var dl_label: [32]u8 = undefined;
    const dl_text = shell_mui.loadString(.ex_lib_downloads, &dl_label);
    nav_nodes[nav_node_count] = .{
        .kind = .downloads,
        .label = dl_text,
        .icon = .downloads,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    var recent_label: [32]u8 = undefined;
    const recent_text = shell_mui.loadString(.ex_lib_recent, &recent_label);
    nav_nodes[nav_node_count] = .{
        .kind = .recent,
        .label = recent_text,
        .icon = .recent_places,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    // Libraries section
    var lib_label: [32]u8 = undefined;
    const lib_text = shell_mui.loadString(.ex_lib_nav_lib, &lib_label);
    nav_nodes[nav_node_count] = .{
        .kind = .library_root,
        .label = lib_text,
        .icon = .library_root,
        .expanded = false,
        .indent = 0,
        .child_count = 4,
    };
    nav_node_count += 1;
    
    var doc_label: [32]u8 = undefined;
    const doc_text = shell_mui.loadString(.ex_lib_documents, &doc_label);
    nav_nodes[nav_node_count] = .{
        .kind = .library_documents,
        .label = doc_text,
        .icon = .documents,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    var pic_label: [32]u8 = undefined;
    const pic_text = shell_mui.loadString(.ex_lib_pictures, &pic_label);
    nav_nodes[nav_node_count] = .{
        .kind = .library_pictures,
        .label = pic_text,
        .icon = .pictures,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    var vid_label: [32]u8 = undefined;
    const vid_text = shell_mui.loadString(.ex_lib_videos, &vid_label);
    nav_nodes[nav_node_count] = .{
        .kind = .library_videos,
        .label = vid_text,
        .icon = .videos,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    var mus_label: [32]u8 = undefined;
    const mus_text = shell_mui.loadString(.ex_lib_music, &mus_label);
    nav_nodes[nav_node_count] = .{
        .kind = .library_music,
        .label = mus_text,
        .icon = .music,
        .expanded = false,
        .indent = 10,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    // Computer section
    var comp_label: [32]u8 = undefined;
    const comp_text = shell_mui.loadString(.ex_lib_nav_comp, &comp_label);
    nav_nodes[nav_node_count] = .{
        .kind = .computer,
        .label = comp_text,
        .icon = .computer,
        .expanded = false,
        .indent = 0,
        .child_count = 0,
    };
    nav_node_count += 1;
    
    // Add drive nodes
    explorer_state.explorerEnsureVolumeSnapshot();
    const vols = explorer_state.explorerVolumes();
    
    var drive_count: usize = 0;
    for (vols) |v| {
        if (nav_node_count >= MAX_NAV_NODES) break;
        
        var vol_label_buf: [48]u8 = undefined;
        const vol_label = explorer_format.formatDriveNavLabel(&vol_label_buf, v.letter);
        
        nav_nodes[nav_node_count] = .{
            .kind = .drive,
            .label = vol_label,
            .icon = v.iconId(),
            .expanded = false,
            .indent = 10,
            .child_count = 0,
        };
        nav_node_count += 1;
        drive_count += 1;
    }
    
    // Update computer node child count
    for (0..nav_node_count) |i| {
        if (nav_nodes[i].kind == .computer) {
            nav_nodes[i].child_count = drive_count;
        }
    }
    
    // Network section
    var net_label: [32]u8 = undefined;
    const net_text = shell_mui.loadString(.ex_lib_nav_net, &net_label);
    nav_nodes[nav_node_count] = .{
        .kind = .network,
        .label = net_text,
        .icon = .network,
        .expanded = false,
        .indent = 0,
        .child_count = 0,
    };
    nav_node_count += 1;
}

// ── Navigation Tree State ──────────────────────────────────────────────────

pub fn getNavPaneWidth() i32 {
    return nav_pane_width;
}

pub fn setNavPaneWidth(w: i32) void {
    nav_pane_width = @max(150, @min(350, w));
}

pub fn getNavHoverIndex() i32 {
    return nav_hover_index;
}

pub fn setNavHoverIndex(idx: i32) void {
    nav_hover_index = idx;
}

pub fn getNavNodeCount() usize {
    return nav_node_count;
}

pub fn getNavNode(index: usize) ?NavNode {
    if (index >= nav_node_count) return null;
    return nav_nodes[index];
}

pub fn isNavNodeExpanded(index: usize) bool {
    if (index >= nav_node_count) return false;
    return nav_nodes[index].expanded;
}

pub fn toggleNavNodeExpanded(index: usize) void {
    if (index >= nav_node_count) return;
    nav_nodes[index].expanded = !nav_nodes[index].expanded;
}

// ── Navigation Tree Rendering ────────────────────────────────────────────────

const NAV_ITEM_H: i32 = 20;
const NAV_CHEVRON_W: i32 = 16;
const NAV_ICON_SIZE: i32 = 16;

pub fn renderNavigationPane(x: i32, y: i32, width: i32, height: i32) void {
    buildNavigationTree();
    
    // Background
    fb.fillRect(x, y, width, height, rgb(0xFC, 0xFC, 0xFE));
    
    var iy: i32 = y + 4;
    const end_y = y + height;
    
    for (0..nav_node_count) |i| {
        if (iy + NAV_ITEM_H > end_y) break;
        
        const node = nav_nodes[i];
        const is_heading = node.kind == .heading;
        const row_h: i32 = if (is_heading) 18 else NAV_ITEM_H;
        
        const is_hover = (@as(i32, @intCast(i)) == nav_hover_index);
        const is_selected = isNodeSelected(node.kind, node.label);
        
        // Highlight background
        if (is_hover and !is_heading) {
            fb.fillRect(x + 2, iy, width - 4, row_h, rgb(0xD8, 0xE8, 0xF8));
        }
        
        if (is_selected and !is_heading) {
            fb.fillRect(x + 2, iy, width - 4, row_h, rgb(0xC8, 0xE0, 0xF0));
            fb.drawRect(x + 2, iy, width - 4, row_h, rgb(0xA0, 0xC0, 0xE0));
        }
        
        const text_x = x + 4 + node.indent + NAV_ICON_SIZE + 4;
        const icon_x = x + 4 + node.indent;
        const icon_y = iy + (row_h - NAV_ICON_SIZE) / 2;
        
        // Chevron for expandable nodes
        if (node.child_count > 0 and !is_heading) {
            const chevron = if (node.expanded) "▼" else "▶";
            fb.drawTextTransparent(x + 4 + node.indent - NAV_CHEVRON_W, iy + (row_h - 14) / 2, chevron, rgb(0x50, 0x50, 0x50));
        }
        
        // Icon
        icons.drawThemedIcon(node.icon, icon_x, icon_y, 1, .aero, is_selected);
        
        // Text
        const text_color: u32 = if (is_heading)
            rgb(0x50, 0x58, 0x60)
        else if (is_selected)
            rgb(0x00, 0x3C, 0x80)
        else
            rgb(0x18, 0x18, 0x18);
        
        fb.drawTextTransparent(text_x, iy + (row_h - 14) / 2, node.label, text_color);
        
        iy += row_h;
    }
}

fn isNodeSelected(kind: NavNodeKind, label: []const u8) bool {
    const view = explorer_state.getExplorerView();
    const loc = explorer_state.getExplorerLocation();
    
    switch (view) {
        .libraries => {
            switch (kind) {
                .library_root => return true,
                .desktop => {
                    var buf: [32]u8 = undefined;
                    const s = shell_mui.loadString(.ex_lib_desktop, &buf);
                    return std.mem.eql(u8, label, s);
                },
                .downloads => {
                    var buf: [32]u8 = undefined;
                    const s = shell_mui.loadString(.ex_lib_downloads, &buf);
                    return std.mem.eql(u8, label, s);
                },
                .recent => {
                    var buf: [32]u8 = undefined;
                    const s = shell_mui.loadString(.ex_lib_recent, &buf);
                    return std.mem.eql(u8, label, s);
                },
                else => return false,
            }
        },
        .computer => {
            switch (kind) {
                .computer => {
                    return @as(bool, loc == .computer_root);
                },
                .drive => {
                    if (loc == .drive_root) |L| {
                        var vol_label_buf: [48]u8 = undefined;
                        const vol_label = explorer_format.formatDriveNavLabel(&vol_label_buf, L);
                        return std.mem.eql(u8, label, vol_label);
                    }
                    return false;
                },
                else => return false,
            }
        },
    }
}

// ── Navigation Hit Testing ──────────────────────────────────────────────────

pub fn hitTestNavigationPane(px: i32, py: i32, nav_x: i32, nav_y: i32, nav_w: i32, nav_h: i32) ?usize {
    if (px < nav_x or px >= nav_x + nav_w or py < nav_y or py >= nav_y + nav_h) {
        return null;
    }
    
    buildNavigationTree();
    
    var iy: i32 = nav_y + 4;
    const end_y = nav_y + nav_h;
    
    for (0..nav_node_count) |i| {
        const node = nav_nodes[i];
        const is_heading = node.kind == .heading;
        const row_h: i32 = if (is_heading) 18 else NAV_ITEM_H;
        
        if (py >= iy and py < iy + row_h) {
            return i;
        }
        
        iy += row_h;
        if (iy >= end_y) break;
    }
    
    return null;
}

pub fn getNavNodeAtPoint(index: usize) ?NavNode {
    return getNavNode(index);
}

// ── Navigation Actions ──────────────────────────────────────────────────────

pub fn handleNavNodeClick(index: usize) void {
    if (index >= nav_node_count) return;
    
    const node = nav_nodes[index];
    
    switch (node.kind) {
        .heading => {},
        .favorites, .desktop, .downloads, .recent => {
            explorer_state.setExplorerView(.libraries);
        },
        .library_root => {
            explorer_state.setExplorerView(.libraries);
        },
        .library_documents => {
            explorer_state.explorerNavigateToLibrary(.documents);
        },
        .library_pictures => {
            explorer_state.explorerNavigateToLibrary(.pictures);
        },
        .library_videos => {
            explorer_state.explorerNavigateToLibrary(.videos);
        },
        .library_music => {
            explorer_state.explorerNavigateToLibrary(.music);
        },
        .computer => {
            explorer_state.setExplorerView(.computer);
        },
        .drive => {
            const label = node.label;
            var letter: u8 = 'C';
            
            // Parse drive letter from label
            for (label, 0..) |c, idx| {
                if (c == ':' and idx > 0) {
                    letter = label[idx - 1];
                    if (letter >= 'a' and letter <= 'z') {
                        letter = letter - 'a' + 'A';
                    }
                    break;
                }
            }
            
            explorer_state.setExplorerView(.computer);
            explorer_state.setExplorerComputerDriveSelected(letter);
        },
        .network => {},
    }
}

pub fn handleNavChevronClick(index: usize) void {
    if (index >= nav_node_count) return;
    const node = nav_nodes[index];
    if (node.child_count > 0) {
        toggleNavNodeExpanded(index);
    }
}

// ── Navigation Pane Resize ─────────────────────────────────────────────────

pub fn isInNavResizeZone(px: i32, nav_x: i32, nav_w: i32) bool {
    return px >= nav_x + nav_w - 4 and px <= nav_x + nav_w + 4;
}
