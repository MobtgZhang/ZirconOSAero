//! Security Reference Monitor (NT style)
//! Token, SID, and access check mechanism

const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

pub const SID = struct {
    authority: u32 = 0,
    sub_authorities: [4]u32 = .{ 0, 0, 0, 0 },
    sub_count: u8 = 0,

    pub fn eql(self: SID, other: SID) bool {
        if (self.authority != other.authority) return false;
        if (self.sub_count != other.sub_count) return false;
        var i: u8 = 0;
        while (i < self.sub_count) : (i += 1) {
            if (self.sub_authorities[i] != other.sub_authorities[i]) return false;
        }
        return true;
    }
};

pub const SYSTEM_SID = SID{ .authority = 5, .sub_authorities = .{ 18, 0, 0, 0 }, .sub_count = 1 };
pub const ADMIN_SID = SID{ .authority = 5, .sub_authorities = .{ 32, 544, 0, 0 }, .sub_count = 2 };
pub const USER_SID = SID{ .authority = 5, .sub_authorities = .{ 21, 1, 0, 0 }, .sub_count = 2 };
pub const ANONYMOUS_SID = SID{ .authority = 5, .sub_authorities = .{ 7, 0, 0, 0 }, .sub_count = 1 };

pub const PRIV_DEBUG: u64 = 1 << 0;
pub const PRIV_SHUTDOWN: u64 = 1 << 1;
pub const PRIV_LOAD_DRIVER: u64 = 1 << 2;
pub const PRIV_TCB: u64 = 1 << 3;
pub const PRIV_CREATE_TOKEN: u64 = 1 << 4;
pub const PRIV_ASSIGN_PRIMARY: u64 = 1 << 5;
pub const PRIV_IMPERSONATE: u64 = 1 << 6;
pub const PRIV_ALL: u64 = 0xFFFFFFFFFFFFFFFF;

pub const Token = struct {
    header: ob.ObjectHeader = .{ .obj_type = .token },
    owner: SID = SYSTEM_SID,
    primary_group: SID = SYSTEM_SID,
    privileges: u64 = 0,
    session_id: u32 = 0,
    is_elevated: bool = true,
    token_id: u32 = 0,
    impersonation_level: u8 = 0,

    pub fn hasPrivilege(self: *const Token, priv: u64) bool {
        return (self.privileges & priv) == priv;
    }
};

var next_token_id: u32 = 1;

pub fn createSystemToken() Token {
    const id = next_token_id;
    next_token_id += 1;
    return .{
        .header = .{ .obj_type = .token },
        .owner = SYSTEM_SID,
        .primary_group = SYSTEM_SID,
        .privileges = PRIV_ALL,
        .session_id = 0,
        .is_elevated = true,
        .token_id = id,
    };
}

pub fn createUserToken(session_id: u32) Token {
    const id = next_token_id;
    next_token_id += 1;
    return .{
        .header = .{ .obj_type = .token },
        .owner = USER_SID,
        .primary_group = USER_SID,
        .privileges = 0,
        .session_id = session_id,
        .is_elevated = false,
        .token_id = id,
    };
}

pub fn checkAccess(token: *const Token, required_access: u32, object_access: u32) bool {
    if (token.owner.eql(SYSTEM_SID)) return true;
    if (token.is_elevated) return true;
    return (object_access & required_access) == required_access;
}

pub fn checkPrivilege(token: *const Token, priv: u64) bool {
    return token.hasPrivilege(priv);
}

pub fn init() void {
    next_token_id = 1;
    klog.info("Security: Reference Monitor initialized", .{});
}
