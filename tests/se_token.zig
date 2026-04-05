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
const PRIV_TCB: u64 = 1 << 1;

fn checkAccess(token: *const Token, required_access: u32, object_access: u32) bool {
    if (token.owner.eql(SYSTEM_SID)) return true;
    if (token.is_elevated) return true;
    return (object_access & required_access) == required_access;
}

fn checkPrivilege(token: *const Token, priv: u64) bool {
    return (token.privileges & priv) == priv;
}

/// 与 `src/se/token.zig` `seAccessCheckMask` 同构（主机镜像，避免拉整棵内核依赖）。
fn seAccessCheckMask(token: *const Token, desired: u32, object_grants: u32) bool {
    if (token.owner.eql(SYSTEM_SID)) return true;
    if (token.is_elevated) return true;
    return (object_grants & desired) == desired;
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

test "seAccessCheckMask grants must cover desired" {
    const user = Token{ .owner = USER_SID, .is_elevated = false, .privileges = 0 };
    try std.testing.expect(seAccessCheckMask(&user, GENERIC_READ, GENERIC_READ | GENERIC_WRITE));
    try std.testing.expect(!seAccessCheckMask(&user, GENERIC_READ | GENERIC_WRITE, GENERIC_READ));
}

// 与 `src/se/token.zig` `seProcessOpenAllowed` 非提升分支同构（主机镜像）。
const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_INFORMATION: u32 = 0x0400;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const SYNCHRONIZE_WIN32: u32 = 0x00100000;

fn seProcessOpenAllowedNonElevated(win32_desired_access: u32) bool {
    const allow = PROCESS_QUERY_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE_WIN32;
    return (win32_desired_access & ~allow) == 0;
}

test "seProcessOpenAllowed user may query not terminate" {
    try std.testing.expect(seProcessOpenAllowedNonElevated(PROCESS_QUERY_INFORMATION));
    try std.testing.expect(seProcessOpenAllowedNonElevated(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE_WIN32));
    try std.testing.expect(!seProcessOpenAllowedNonElevated(PROCESS_TERMINATE));
    try std.testing.expect(!seProcessOpenAllowedNonElevated(PROCESS_QUERY_INFORMATION | PROCESS_TERMINATE));
}

/// 与 `src/se/token.zig` `seAccessActiveDesktopForWin32k` 同构（主机镜像，供 GUI LPC 门闸文档锚点）。
fn seAccessActiveDesktopForWin32kMirror(tok: *const Token, process_desktop_idx: u32, active_desktop_idx: u32) bool {
    if (process_desktop_idx == active_desktop_idx) return true;
    if (tok.owner.eql(SYSTEM_SID)) return true;
    if (tok.is_elevated and checkPrivilege(tok, PRIV_TCB)) return true;
    return false;
}

test "seAccessActiveDesktopForWin32k mirror denies wrong desktop for plain user" {
    const user = Token{ .owner = USER_SID, .is_elevated = false, .privileges = 0 };
    try std.testing.expect(!seAccessActiveDesktopForWin32kMirror(&user, 1, 0));
    try std.testing.expect(seAccessActiveDesktopForWin32kMirror(&user, 0, 0));
}

test "seAccessActiveDesktopForWin32k mirror allows TCB elevated cross-desktop" {
    var user = Token{ .owner = USER_SID, .is_elevated = true, .privileges = PRIV_TCB };
    try std.testing.expect(seAccessActiveDesktopForWin32kMirror(&user, 5, 0));
}

const SYNCHRONIZE: u32 = 0x00100000;
const GENERIC_ALL: u32 = 0x10000000;

/// 与 `src/se/token.zig` `seAccessCheckMask` 同构（主机镜像，K6.3）。
fn seAccessCheckMaskMirror(is_system_or_elevated: bool, desired: u32, object_grants: u32) bool {
    if (is_system_or_elevated) return true;
    return (object_grants & desired) == desired;
}

test "seAccessCheckMask mirror denies when grants do not cover desired" {
    try std.testing.expect(!seAccessCheckMaskMirror(false, GENERIC_READ, SYNCHRONIZE));
    try std.testing.expect(seAccessCheckMaskMirror(false, SYNCHRONIZE, GENERIC_READ | SYNCHRONIZE));
}

test "seAccessCheckMask mirror allows elevated bypass" {
    try std.testing.expect(seAccessCheckMaskMirror(true, GENERIC_ALL, 0));
}

/// 与 `src/se/token.zig` `effectiveGrantsFromDaclPresent` 同构。
fn effectiveGrantsFromDaclPresentMirror(dacl_present: bool, aggregated_allow: u32) u32 {
    if (!dacl_present) return 0xFFFF_FFFF;
    return aggregated_allow;
}

/// 与 `src/se/token.zig` `seAccessCheckWithDacl` 同构（主机镜像）。
fn seAccessCheckWithDaclMirror(is_system_or_elevated: bool, desired: u32, dacl_present: bool, aggregated_allow: u32) bool {
    const grants = effectiveGrantsFromDaclPresentMirror(dacl_present, aggregated_allow);
    return seAccessCheckMaskMirror(is_system_or_elevated, desired, grants);
}

test "seAccessCheckWithDacl mirror: no DACL grants full mask for non-elevated check path" {
    try std.testing.expect(seAccessCheckWithDaclMirror(false, GENERIC_READ, false, 0));
}

test "seAccessCheckWithDacl mirror: DACL present uses aggregated allow" {
    try std.testing.expect(seAccessCheckWithDaclMirror(false, GENERIC_READ, true, GENERIC_READ | GENERIC_WRITE));
    try std.testing.expect(!seAccessCheckWithDaclMirror(false, GENERIC_READ | GENERIC_WRITE, true, GENERIC_READ));
}
