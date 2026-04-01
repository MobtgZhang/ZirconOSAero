// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Host-only tests mirroring src/se/token.zig access-check semantics (DAC subset).
// Independent clean-room; no Windows source referenced.
// Ref: Microsoft Learn — access control concepts (high level).

const std = @import("std");

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;

const SID = struct {
    authority: u32 = 0,
    sub_authorities: [4]u32 = .{ 0, 0, 0, 0 },
    sub_count: u8 = 0,

    fn eql(self: SID, other: SID) bool {
        if (self.authority != other.authority) return false;
        if (self.sub_count != other.sub_count) return false;
        var i: u8 = 0;
        while (i < self.sub_count) : (i += 1) {
            if (self.sub_authorities[i] != other.sub_authorities[i]) return false;
        }
        return true;
    }
};

const SYSTEM_SID = SID{ .authority = 5, .sub_authorities = .{ 18, 0, 0, 0 }, .sub_count = 1 };
const USER_SID = SID{ .authority = 5, .sub_authorities = .{ 21, 1, 0, 0 }, .sub_count = 2 };

const Token = struct {
    owner: SID = SYSTEM_SID,
    is_elevated: bool = true,
    privileges: u64 = 0,
};

const PRIV_DEBUG: u64 = 1 << 0;

fn checkAccess(token: *const Token, required_access: u32, object_access: u32) bool {
    if (token.owner.eql(SYSTEM_SID)) return true;
    if (token.is_elevated) return true;
    return (object_access & required_access) == required_access;
}

fn checkPrivilege(token: *const Token, priv: u64) bool {
    return (token.privileges & priv) == priv;
}

test "checkAccess system SID grants all" {
    const sys = Token{ .owner = SYSTEM_SID, .is_elevated = true, .privileges = 0xFFFF_FFFF_FFFF_FFFF };
    try std.testing.expect(checkAccess(&sys, 0xFFFF_FFFF, 0) == true);
}

test "checkAccess user token requires object DAC bits" {
    const user = Token{ .owner = USER_SID, .is_elevated = false, .privileges = 0 };
    try std.testing.expect(checkAccess(&user, GENERIC_READ | GENERIC_WRITE, GENERIC_READ) == false);
    try std.testing.expect(checkAccess(&user, GENERIC_READ, GENERIC_READ | GENERIC_WRITE) == true);
}

test "checkPrivilege" {
    const sys = Token{ .owner = SYSTEM_SID, .is_elevated = true, .privileges = PRIV_DEBUG };
    try std.testing.expect(checkPrivilege(&sys, PRIV_DEBUG) == true);
    const user = Token{ .owner = USER_SID, .is_elevated = false, .privileges = 0 };
    try std.testing.expect(checkPrivilege(&user, PRIV_DEBUG) == false);
}
