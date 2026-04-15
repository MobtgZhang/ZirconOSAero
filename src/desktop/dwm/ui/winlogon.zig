// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// WinLogon - D3D10 渲染的登录屏幕组件
// 支持用户选择、密码输入、锁屏界面

const std = @import("std");
const dwm = @import("../root.zig");
const theme = @import("../config/theme.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");

// ============================================================================
// 常量定义
// ============================================================================

pub const LOGON_WIDTH: i32 = 400;
pub const LOGON_HEIGHT: i32 = 300;
pub const USER_ICON_SIZE: i32 = 64;
pub const PASSWORD_BOX_HEIGHT: i32 = 32;

// ============================================================================
// 登录状态
// ============================================================================

pub const LoginState = enum(u8) {
    Welcome,
    SelectingUser,
    EnteringPassword,
    Authenticating,
    Success,
    Error,
};

pub const UserAccount = struct {
    id: u32,
    username: []const u8,
    display_name: []const u8,
    icon_id: u32,
    logged_in: bool,
};

var g_login_state: LoginState = undefined;
var g_user_accounts: [8]UserAccount = undefined;
var g_account_count: usize = 0;
var g_selected_user: ?*UserAccount = null;
var g_password_buffer: [64]u8 = undefined;
var g_password_len: usize = 0;
var g_error_message: []const u8 = "";
var g_surface_id: u32 = 0;
var g_initialized: bool = false;
var g_session_locked: bool = false;

// ============================================================================
// 登录屏幕初始化
// ============================================================================

pub fn initWinLogon() void {
    if (g_initialized) return;

    // 创建登录屏幕表面
    g_surface_id = surface_mgr.createSurface(LOGON_WIDTH, LOGON_HEIGHT, .{
        .has_alpha = true,
        .is_visible = false,
        .needs_blur = theme.isGlassEnabled(),
        .is_glass = true,
    });

    // 添加默认用户
    addDefaultUsers();

    // 初始化状态
    g_login_state = .Welcome;
    g_selected_user = null;
    g_password_len = 0;
    g_error_message = "";
    g_session_locked = false;

    g_initialized = true;
}

pub fn deinitWinLogon() void {
    if (!g_initialized) return;

    _ = surface_mgr.destroySurface(g_surface_id);
    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 默认用户
// ============================================================================

fn addDefaultUsers() void {
    g_account_count = 0;

    addUserAccount(1, "Administrator", "管理员", 15);
    addUserAccount(2, "Guest", "访客", 15);
}

fn addUserAccount(id: u32, username: []const u8, display_name: []const u8, icon_id: u32) void {
    if (g_account_count >= 8) return;

    const user = &g_user_accounts[g_account_count];
    user.* = .{
        .id = id,
        .username = username,
        .display_name = display_name,
        .icon_id = icon_id,
        .logged_in = false,
    };

    g_account_count += 1;
}

// ============================================================================
// 用户管理
// ============================================================================

pub fn selectUser(user: *UserAccount) void {
    g_selected_user = user;
    g_login_state = .EnteringPassword;
    g_password_len = 0;
    @memset(&g_password_buffer, 0);
    g_error_message = "";
}

pub fn deselectUser() void {
    g_selected_user = null;
    g_login_state = .SelectingUser;
    g_password_len = 0;
    @memset(&g_password_buffer, 0);
}

pub fn getSelectedUser() ?*UserAccount {
    return g_selected_user;
}

pub fn getUserCount() usize {
    return g_account_count;
}

pub fn getUsers() []UserAccount {
    return g_user_accounts[0..g_account_count];
}

// ============================================================================
// 密码输入
// ============================================================================

pub fn appendPasswordChar(c: u8) void {
    if (g_password_len < 63) {
        g_password_buffer[g_password_len] = c;
        g_password_len += 1;
        g_password_buffer[g_password_len] = 0;
    }
}

pub fn backspacePassword() void {
    if (g_password_len > 0) {
        g_password_len -= 1;
        g_password_buffer[g_password_len] = 0;
    }
}

pub fn clearPassword() void {
    g_password_len = 0;
    @memset(&g_password_buffer, 0);
}

pub fn getPassword() []const u8 {
    return g_password_buffer[0..g_password_len];
}

pub fn getPasswordMasked() []u8 {
    var masked: [64]u8 = undefined;
    for (0..g_password_len) |i| {
        masked[i] = '*';
    }
    masked[g_password_len] = 0;
    return masked[0..g_password_len];
}

// ============================================================================
// 认证
// ============================================================================

pub fn attemptLogin() bool {
    if (g_selected_user == null) return false;

    g_login_state = .Authenticating;

    // 这里应该调用实际的认证系统
    // 目前只是模拟认证成功
    const password = getPassword();

    if (password.len == 0) {
        g_error_message = "请输入密码";
        g_login_state = .Error;
        return false;
    }

    // 模拟：任何非空密码都可以登录
    g_selected_user.?.logged_in = true;
    g_login_state = .Success;

    return true;
}

pub fn getErrorMessage() []const u8 {
    return g_error_message;
}

// ============================================================================
// 锁屏
// ============================================================================

pub fn lockSession() void {
    g_session_locked = true;
    g_login_state = .Welcome;

    // 显示登录屏幕
    const screen_size = compositor.getScreenSize();
    surface_mgr.moveSurface(g_surface_id,
        (@as(i32, @intCast(screen_size.w)) - LOGON_WIDTH) / 2,
        (@as(i32, @intCast(screen_size.h)) - LOGON_HEIGHT) / 2);
    surface_mgr.setSurfaceVisible(g_surface_id, true);
    surface_mgr.setSurfaceZOrder(g_surface_id, 1000);
}

pub fn unlockSession() void {
    g_session_locked = false;
    g_login_state = .Welcome;
    surface_mgr.setSurfaceVisible(g_surface_id, false);

    // 清除所有用户的登录状态
    for (0..g_account_count) |i| {
        g_user_accounts[i].logged_in = false;
    }
}

pub fn isSessionLocked() bool {
    return g_session_locked;
}

// ============================================================================
// 状态管理
// ============================================================================

pub fn getLoginState() LoginState {
    return g_login_state;
}

pub fn resetToWelcome() void {
    g_login_state = .Welcome;
    g_selected_user = null;
    g_password_len = 0;
    @memset(&g_password_buffer, 0);
    g_error_message = "";
}

pub fn resetToUserSelection() void {
    g_login_state = .SelectingUser;
    g_selected_user = null;
    g_password_len = 0;
    @memset(&g_password_buffer, 0);
    g_error_message = "";
}

// ============================================================================
// 输入处理
// ============================================================================

pub fn onMouseMove(px: i32, py: i32) void {
    _ = px;
    _ = py;
    // 鼠标移动处理
}

pub fn onClick(px: i32, py: i32) ?enum { user_select, login_button, shutdown_button, cancel_button, none } {
    _ = px;
    _ = py;
    // 点击处理
    return null;
}

// ============================================================================
// 渲染
// ============================================================================

pub fn render() void {
    if (!g_initialized) return;

    if (surface_mgr.getSurface(g_surface_id)) |sfc| {
        sfc.markFullDirty();
    }
}

pub fn getSurfaceId() u32 {
    return g_surface_id;
}