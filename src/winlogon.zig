//! WinLogon - User Login Manager for ZirconOS Aero Desktop
//! Implements user authentication, session management, and the
//! Windows Vista/7 style login screen with user avatar circle,
//! large display name, password field with reveal button, and
//! user selection screen.
//! Reference: ReactOS winlogon (base/system/winlogon/)

const theme = @import("theme.zig");

pub const COLORREF = theme.COLORREF;

// ── User Account ──

pub const MAX_USERS: usize = 16;
pub const MAX_USERNAME_LEN: usize = 64;
pub const MAX_PASSWORD_LEN: usize = 128;
pub const MAX_DISPLAY_NAME_LEN: usize = 64;

pub const UserRole = enum(u8) {
    administrator = 0,
    standard = 1,
    guest = 2,
    system = 3,
};

pub const UserFlags = struct {
    password_required: bool = true,
    account_disabled: bool = false,
    account_locked: bool = false,
    password_never_expires: bool = false,
    auto_logon: bool = false,
};

pub const UserAccount = struct {
    username: [MAX_USERNAME_LEN]u8 = [_]u8{0} ** MAX_USERNAME_LEN,
    username_len: usize = 0,
    display_name: [MAX_DISPLAY_NAME_LEN]u8 = [_]u8{0} ** MAX_DISPLAY_NAME_LEN,
    display_name_len: usize = 0,
    password_hash: u64 = 0,
    role: UserRole = .standard,
    flags: UserFlags = .{},
    logon_count: u32 = 0,
    failed_logon_count: u32 = 0,
    avatar_id: u32 = 0,
    sid: u32 = 0,
    is_active: bool = false,

    pub fn getUsername(self: *const UserAccount) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn getDisplayName(self: *const UserAccount) []const u8 {
        if (self.display_name_len > 0) {
            return self.display_name[0..self.display_name_len];
        }
        return self.username[0..self.username_len];
    }
};

// ── Login Session ──

pub const SessionState = enum(u8) {
    no_session = 0,
    welcome_screen = 1,
    credentials_prompt = 2,
    authenticating = 3,
    loading_profile = 4,
    logged_in = 5,
    locking = 6,
    locked = 7,
    unlocking = 8,
    logging_off = 9,
    shutting_down = 10,
    switch_user = 11,
};

pub const LogonType = enum(u8) {
    welcome_screen = 0,
    classic_dialog = 1,
    auto_logon = 2,
    network_logon = 3,
};

pub const LoginSession = struct {
    session_id: u32 = 0,
    user_index: u32 = 0,
    state: SessionState = .no_session,
    logon_type: LogonType = .welcome_screen,
    logon_time: u64 = 0,
    desktop_name: [32]u8 = [_]u8{0} ** 32,
    desktop_name_len: usize = 0,
    window_station: [32]u8 = [_]u8{0} ** 32,
    window_station_len: usize = 0,
    token_handle: u32 = 0,
    is_active: bool = false,
};

pub const AuthResult = enum(u8) {
    success = 0,
    invalid_username = 1,
    invalid_password = 2,
    account_disabled = 3,
    account_locked = 4,
    password_expired = 5,
    session_limit = 6,
};

pub const ShutdownAction = enum(u8) {
    shutdown = 0,
    restart = 1,
    logoff = 2,
    standby = 3,
    hibernate = 4,
    switch_user = 5,
};

// ── Welcome Screen UI State (Vista/7 style) ──

pub const WelcomeScreenState = struct {
    selected_user: i32 = -1,
    password_visible: bool = false,
    password_buffer: [MAX_PASSWORD_LEN]u8 = [_]u8{0} ** MAX_PASSWORD_LEN,
    password_len: usize = 0,
    error_message: [128]u8 = [_]u8{0} ** 128,
    error_message_len: usize = 0,
    show_shutdown_menu: bool = false,
    animation_frame: u32 = 0,
    hint_visible: bool = false,
    show_password_reveal: bool = false,
    avatar_hover: i32 = -1,
};

// ── Global State ──

var users: [MAX_USERS]UserAccount = [_]UserAccount{.{}} ** MAX_USERS;
var user_count: usize = 0;
var next_sid: u32 = 1000;

var current_session: LoginSession = .{};
var welcome_state: WelcomeScreenState = .{};

var winlogon_initialized: bool = false;
var total_logon_attempts: u64 = 0;
var total_successful_logons: u64 = 0;

// ── User Management ──

pub fn createUser(
    username: []const u8,
    display_name: []const u8,
    password: []const u8,
    role: UserRole,
) ?*UserAccount {
    if (user_count >= MAX_USERS) return null;

    var user = &users[user_count];
    user.* = .{};
    user.is_active = true;
    user.role = role;
    user.sid = next_sid;
    next_sid += 1;

    const un = @min(username.len, MAX_USERNAME_LEN);
    @memcpy(user.username[0..un], username[0..un]);
    user.username_len = un;

    const dn = @min(display_name.len, MAX_DISPLAY_NAME_LEN);
    @memcpy(user.display_name[0..dn], display_name[0..dn]);
    user.display_name_len = dn;

    user.password_hash = hashPassword(password);
    if (password.len == 0) {
        user.flags.password_required = false;
    }

    user_count += 1;
    return user;
}

pub fn findUser(username: []const u8) ?*UserAccount {
    for (users[0..user_count]) |*user| {
        if (user.is_active and strEqlI(user.getUsername(), username)) {
            return user;
        }
    }
    return null;
}

pub fn getUserByIndex(index: usize) ?*const UserAccount {
    if (index < user_count and users[index].is_active) {
        return &users[index];
    }
    return null;
}

pub fn getActiveUserCount() usize {
    var count: usize = 0;
    for (users[0..user_count]) |*user| {
        if (user.is_active and user.role != .system) count += 1;
    }
    return count;
}

// ── Authentication ──

pub fn authenticate(username: []const u8, password: []const u8) AuthResult {
    total_logon_attempts += 1;

    const user = findUser(username) orelse return .invalid_username;

    if (user.flags.account_disabled) return .account_disabled;
    if (user.flags.account_locked) return .account_locked;

    if (user.flags.password_required) {
        const hash = hashPassword(password);
        if (hash != user.password_hash) {
            user.failed_logon_count += 1;
            if (user.failed_logon_count >= 5) {
                user.flags.account_locked = true;
            }
            return .invalid_password;
        }
    }

    user.logon_count += 1;
    user.failed_logon_count = 0;
    total_successful_logons += 1;
    return .success;
}

pub fn beginLogon(user_index: u32) AuthResult {
    if (user_index >= user_count) return .invalid_username;
    const user = &users[user_index];
    if (!user.is_active) return .invalid_username;

    welcome_state.selected_user = @intCast(user_index);
    welcome_state.password_len = 0;
    welcome_state.error_message_len = 0;

    if (!user.flags.password_required) {
        return completeLogon(user_index);
    }

    current_session.state = .credentials_prompt;
    return .success;
}

pub fn submitPassword(password: []const u8) AuthResult {
    if (welcome_state.selected_user < 0) return .invalid_username;
    const idx: usize = @intCast(welcome_state.selected_user);
    if (idx >= user_count) return .invalid_username;

    const user = &users[idx];
    const result = authenticate(user.getUsername(), password);

    if (result == .success) {
        return completeLogon(@intCast(idx));
    }

    setErrorMessage(switch (result) {
        .invalid_password => "The user name or password is incorrect.",
        .account_disabled => "Your account has been disabled.",
        .account_locked => "Your account has been locked due to too many failed sign-in attempts.",
        else => "Sign-in failed.",
    });

    return result;
}

fn completeLogon(user_index: u32) AuthResult {
    current_session.state = .loading_profile;
    current_session.user_index = user_index;
    current_session.session_id += 1;
    current_session.is_active = true;

    const ws_name = "WinSta0";
    @memcpy(current_session.window_station[0..ws_name.len], ws_name);
    current_session.window_station_len = ws_name.len;

    const desk_name = "Default";
    @memcpy(current_session.desktop_name[0..desk_name.len], desk_name);
    current_session.desktop_name_len = desk_name.len;

    current_session.state = .logged_in;
    return .success;
}

// ── Session Control ──

pub fn logoff() void {
    if (current_session.state != .logged_in) return;
    current_session.state = .logging_off;
    current_session.is_active = false;
    current_session.state = .no_session;
    welcome_state = .{};
    showWelcomeScreen();
}

pub fn lockWorkstation() void {
    if (current_session.state != .logged_in) return;
    current_session.state = .locked;
    welcome_state.password_len = 0;
    welcome_state.error_message_len = 0;
}

pub fn unlockWorkstation(password: []const u8) AuthResult {
    if (current_session.state != .locked) return .invalid_username;
    const idx: usize = current_session.user_index;
    if (idx >= user_count) return .invalid_username;

    const user = &users[idx];
    const result = authenticate(user.getUsername(), password);

    if (result == .success) {
        current_session.state = .logged_in;
    }
    return result;
}

pub fn switchUser() void {
    if (current_session.state != .logged_in) return;
    current_session.state = .switch_user;
    showWelcomeScreen();
}

pub fn shutdown(action: ShutdownAction) void {
    current_session.state = .shutting_down;
    last_shutdown_action = action;
}

var last_shutdown_action: ShutdownAction = .shutdown;

pub fn getShutdownAction() ShutdownAction {
    return last_shutdown_action;
}

pub fn isShuttingDown() bool {
    return current_session.state == .shutting_down;
}

pub fn cancelShutdown() void {
    if (current_session.state == .shutting_down) {
        current_session.state = .logged_in;
    }
}

pub fn showWelcomeScreen() void {
    current_session.state = .welcome_screen;
    welcome_state = .{};
}

// ── Welcome Screen Rendering Info (Vista/7 style) ──

pub const WelcomeUserInfo = struct {
    username: []const u8,
    display_name: []const u8,
    avatar_id: u32,
    has_password: bool,
    role: UserRole,
    is_selected: bool,
};

pub fn getWelcomeUserList(buffer: []WelcomeUserInfo) usize {
    var count: usize = 0;
    for (users[0..user_count], 0..) |*user, i| {
        if (!user.is_active or user.role == .system) continue;
        if (count >= buffer.len) break;

        buffer[count] = .{
            .username = user.getUsername(),
            .display_name = user.getDisplayName(),
            .avatar_id = user.avatar_id,
            .has_password = user.flags.password_required,
            .role = user.role,
            .is_selected = (welcome_state.selected_user == @as(i32, @intCast(i))),
        };
        count += 1;
    }
    return count;
}

pub fn getWelcomeScreenColors() struct {
    bg_top: COLORREF,
    bg_bottom: COLORREF,
    panel: COLORREF,
    text: COLORREF,
    avatar_ring: COLORREF,
    password_field_border: COLORREF,
} {
    const colors = theme.getColors();
    return .{
        .bg_top = colors.login_bg_top,
        .bg_bottom = colors.login_bg_bottom,
        .panel = colors.login_panel,
        .text = colors.login_text,
        .avatar_ring = theme.RGB(0xFF, 0xFF, 0xFF),
        .password_field_border = theme.RGB(0x7A, 0xB0, 0xDA),
    };
}

// ── State Query ──

pub fn getSessionState() SessionState {
    return current_session.state;
}

pub fn isLoggedIn() bool {
    return current_session.state == .logged_in;
}

pub fn isLocked() bool {
    return current_session.state == .locked;
}

pub fn getCurrentUser() ?*const UserAccount {
    if (!current_session.is_active) return null;
    if (current_session.user_index >= user_count) return null;
    return &users[current_session.user_index];
}

pub fn getCurrentUsername() []const u8 {
    const user = getCurrentUser() orelse return "Unknown";
    return user.getDisplayName();
}

pub fn getSessionId() u32 {
    return current_session.session_id;
}

pub fn getErrorMessage() []const u8 {
    return welcome_state.error_message[0..welcome_state.error_message_len];
}

pub fn getTotalLogonAttempts() u64 {
    return total_logon_attempts;
}

pub fn getTotalSuccessfulLogons() u64 {
    return total_successful_logons;
}

pub fn isPasswordRevealed() bool {
    return welcome_state.show_password_reveal;
}

pub fn togglePasswordReveal() void {
    welcome_state.show_password_reveal = !welcome_state.show_password_reveal;
}

// ── Helpers ──

fn hashPassword(password: []const u8) u64 {
    var hash: u64 = 0x534543555245;
    for (password) |c| {
        hash = hash *% 31 +% @as(u64, c);
    }
    return hash;
}

fn setErrorMessage(msg: []const u8) void {
    const n = @min(msg.len, welcome_state.error_message.len);
    @memcpy(welcome_state.error_message[0..n], msg[0..n]);
    welcome_state.error_message_len = n;
}

fn strEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const ax = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const by = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (ax != by) return false;
    }
    return true;
}

// ── Initialization ──

pub fn init() void {
    user_count = 0;
    current_session = .{};
    welcome_state = .{};
    total_logon_attempts = 0;
    total_successful_logons = 0;

    _ = createUser("Administrator", "Administrator", "admin", .administrator);
    _ = createUser("User", "ZirconOS User", "", .standard);
    if (findUser("User")) |u| {
        u.flags.password_required = false;
    }
    _ = createUser("Guest", "Guest", "", .guest);
    if (findUser("Guest")) |g| {
        g.flags.password_required = false;
    }

    winlogon_initialized = true;
    showWelcomeScreen();
}
