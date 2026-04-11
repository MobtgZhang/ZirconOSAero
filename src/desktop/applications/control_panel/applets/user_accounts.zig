// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/user_accounts.zig
// Purpose: User Accounts Settings Applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const UserAccountsApplet = struct {
    base: applet_base.ControlPanelApplet,
    users: [10]UserAccount,
    user_count: usize,
    selected_user: usize,
    hover_state: HoverArea,

    pub const UserAccount = struct {
        name: [32]u8,
        name_len: usize,
        account_type: AccountType,
        avatar: ?u16,
    };

    pub const AccountType = enum { admin, standard, guest };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, user_item };

    pub fn create(x: i32, y: i32, w: i32, h: i32) UserAccountsApplet {
        var ua = UserAccountsApplet{
            .base = applet_base.ControlPanelApplet.create(.user_accounts, x, y, w, h),
            .users = std.mem.zeroes([10]UserAccount),
            .user_count = 3,
            .selected_user = 0,
            .hover_state = .none,
        };

        @memcpy(ua.users[0].name[0..13], "Administrator");
        ua.users[0].name_len = 13;
        ua.users[0].account_type = .admin;
        ua.users[0].avatar = null;

        @memcpy(ua.users[1].name[0..5], "Guest");
        ua.users[1].name_len = 5;
        ua.users[1].account_type = .guest;
        ua.users[1].avatar = null;

        @memcpy(ua.users[2].name[0..4], "User");
        ua.users[2].name_len = 4;
        ua.users[2].account_type = .standard;
        ua.users[2].avatar = null;

        return ua;
    }

    pub fn onMouseMove(_: *UserAccountsApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *UserAccountsApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("User Accounts");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 200, "User Accounts");
        applet.drawUserList(client.x + 24, cy + 24, client.width - 48);
        cy += 220;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Account Actions");
        applet.drawActions(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawUserList(applet: *UserAccountsApplet, x: i32, y: i32, w: i32) void {
        for (applet.users[0..applet.user_count], 0..) |*user, i| {
            const selected = (@as(usize, @intCast(i)) == applet.selected_user);
            const by = y + @as(i32, @intCast(i)) * 50;
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xFF, 0xFF, 0xFF);

            fb.fillRect(x, by, w, 46, bg);
            fb.draw3DRect(x, by, w, 46, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

            fb.fillRect(x + 4, by + 4, 38, 38, rgb(0xE8, 0xEC, 0xF0));
            fb.drawTextTransparent(x + 50, by + 8, user.name[0..user.name_len], if (selected) rgb(0x10, 0x30, 0x70) else rgb(0x10, 0x10, 0x18));

            const type_str = switch (user.account_type) {
                .admin => "Administrator",
                .standard => "Standard",
                .guest => "Guest",
            };
            fb.drawTextTransparent(x + 50, by + 26, type_str, rgb(0x60, 0x60, 0x70));
        }
    }

    fn drawActions(_: *UserAccountsApplet, x: i32, y: i32, w: i32) void {
        const actions = [_][]const u8{ "Change your account name", "Change your password", "Change your picture", "Manage another account" };
        const btn_w = @divTrunc(w - 12, 4);

        inline for (actions, 0..) |action, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            fb.fillRect(bx, y, btn_w, 60, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, y, btn_w, 60, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 22, action, rgb(0x20, 0x20, 0x30));
        }
    }
};
