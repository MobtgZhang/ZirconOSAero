// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! Security Descriptor (SECURITY_DESCRIPTOR) and ACL/ACE implementation
//! Compatible with NT6.1.7601 security descriptor format specification
//! Clean-room implementation based on Microsoft public documentation

const std = @import("std");
const SID = @import("sid.zig").SID;
const ACCESS_MASK = u32;

/// ACE (Access Control Entry) structure
/// Compatible with NT61 ACE format
pub const ACE = struct {
    pub const Type = enum(u8) {
        access_allowed = 0x00,
        access_denied = 0x01,
        system_audit = 0x02,
        system_alarm = 0x03,
    };

    pub const Flags = packed struct(u8) {
        object_inherit: bool = false,
        container_inherit: bool = false,
        no_propagate_inherit: bool = false,
        inherit_only: bool = false,
        inherited_ace: bool = false,
        reserved: u3 = 0,
    };

    type: Type,
    flags: Flags,
    size: u16 = @sizeOf(ACE),
    access_mask: ACCESS_MASK,
    sid: SID,

    pub fn initAllowed(access_mask: ACCESS_MASK, sid: SID) ACE {
        return .{
            .type = .access_allowed,
            .flags = .{},
            .access_mask = access_mask,
            .sid = sid,
        };
    }

    pub fn initDenied(access_mask: ACCESS_MASK, sid: SID) ACE {
        return .{
            .type = .access_denied,
            .flags = .{},
            .access_mask = access_mask,
            .sid = sid,
        };
    }
};

/// ACL (Access Control List) structure
/// Supports DACL (Discretionary ACL) and SACL (System ACL)
pub const ACL = struct {
    pub const Revision = enum(u8) {
        revision2 = 2,
        revision3 = 3,
    };

    revision: Revision = .revision2,
    size: u16 = @sizeOf(ACL),
    ace_count: u16 = 0,
    reserved: u16 = 0,
    aces: [32]ACE = undefined, // Max 32 ACEs per ACL for now

    /// Add an ACE to the ACL
    pub fn addAce(self: *ACL, ace: ACE) bool {
        if (self.ace_count >= 32) return false;
        self.aces[self.ace_count] = ace;
        self.ace_count += 1;
        self.size += @sizeOf(ACE);
        return true;
    }

    /// Remove an ACE at the specified index
    pub fn removeAce(self: *ACL, index: u16) bool {
        if (index >= self.ace_count) return false;
        var i = index;
        while (i < self.ace_count - 1) : (i += 1) {
            self.aces[i] = self.aces[i + 1];
        }
        self.ace_count -= 1;
        self.size -= @sizeOf(ACE);
        return true;
    }

    /// Find all ACEs matching the specified SID
    pub fn findAcesForSid(self: *const ACL, sid: SID) []const ACE {
        var count: usize = 0;
        for (self.aces[0..self.ace_count]) |ace| {
            if (ace.sid.eql(sid)) count += 1;
        }
        if (count == 0) return &.{};
        var result = std.heap.page_allocator.alloc(ACE, count) catch return &.{};
        var idx: usize = 0;
        for (self.aces[0..self.ace_count]) |ace| {
            if (ace.sid.eql(sid)) {
                result[idx] = ace;
                idx += 1;
            }
        }
        return result;
    }
};

/// SECURITY_DESCRIPTOR structure
/// Compatible with NT61 security descriptor format
pub const SECURITY_DESCRIPTOR = struct {
    pub const Control = packed struct(u16) {
        owner_defaulted: bool = false,
        group_defaulted: bool = false,
        dacl_present: bool = false,
        dacl_defaulted: bool = false,
        sacl_present: bool = false,
        sacl_defaulted: bool = false,
        dacl_auto_inherit_req: bool = false,
        sacl_auto_inherit_req: bool = false,
        dacl_auto_inherited: bool = false,
        sacl_auto_inherited: bool = false,
        dacl_protected: bool = false,
        sacl_protected: bool = false,
        rm_control_valid: bool = false,
        self_relative: bool = true,
        reserved: u2 = 0,
    };

    revision: u8 = 1,
    sbz1: u8 = 0,
    control: Control = .{},
    owner: ?*SID = null,
    group: ?*SID = null,
    dacl: ?*ACL = null,
    sacl: ?*ACL = null,

    /// Create a default security descriptor with full access for SYSTEM and administrators
    pub fn initDefault() SECURITY_DESCRIPTOR {
        var sd = SECURITY_DESCRIPTOR{
            .control = .{ .dacl_present = true },
            .owner = undefined,
            .group = undefined,
        };

        const dacl = std.heap.page_allocator.create(ACL) catch return sd;
        dacl.* = .{};

        const sid_mod = @import("sid.zig");
        // Full access for SYSTEM
        _ = dacl.addAce(ACE.initAllowed(0xFFFF_FFFF, sid_mod.SYSTEM_SID));
        // Full access for administrators
        _ = dacl.addAce(ACE.initAllowed(0xFFFF_FFFF, sid_mod.ADMIN_SID));
        // Read/execute access for regular users
        _ = dacl.addAce(ACE.initAllowed(0x001F_FFF1, sid_mod.USER_SID));

        sd.owner = @constCast(&sid_mod.SYSTEM_SID);
        sd.group = @constCast(&sid_mod.SYSTEM_SID);
        sd.dacl = dacl;
        return sd;
    }

    /// Create a security descriptor with no DACL (full access for everyone)
    pub fn initNullDacl() SECURITY_DESCRIPTOR {
        const sid_mod = @import("sid.zig");
        return .{
            .control = .{ .dacl_present = false },
            .owner = @constCast(&sid_mod.SYSTEM_SID),
            .group = @constCast(&sid_mod.SYSTEM_SID),
        };
    }

    /// Check access to this security descriptor for the given token
    pub fn checkAccess(self: *const SECURITY_DESCRIPTOR, user_token: *const anyopaque, desired_access: ACCESS_MASK) bool {
        const token_mod = @import("token.zig");
        const tok: *const token_mod.Token = @ptrCast(@alignCast(user_token));
        // SYSTEM always has full access
        if (tok.owner.eql(token_mod.SYSTEM_SID)) return true;

        // Elevated tokens get full access
        if (tok.is_elevated) return true;

        // If no DACL present, allow full access
        if (!self.control.dacl_present or self.dacl == null) return true;

        const dacl = self.dacl.?;
        var allowed_access: ACCESS_MASK = 0;
        var denied_access: ACCESS_MASK = 0;

        // Process all ACEs in order
        for (dacl.aces[0..dacl.ace_count]) |ace| {
            // Check if ACE applies to this token
            if (!tok.owner.eql(ace.sid)) continue;

            switch (ace.type) {
                .access_denied => {
                    denied_access |= ace.access_mask;
                    // If any desired access is denied, fail immediately
                    if ((desired_access & denied_access) != 0) return false;
                },
                .access_allowed => {
                    allowed_access |= ace.access_mask;
                    // If all desired access is allowed, succeed immediately
                    if ((desired_access & allowed_access) == desired_access) return true;
                },
                else => {
                    // Ignore SACL entries for DAC access check
                    continue;
                },
            }
        }

        // Check if all desired access is allowed
        return (desired_access & allowed_access) == desired_access;
    }
};

/// Object security information
/// Attached to all kernel objects for access control
pub const ObjectSecurity = struct {
    sd: SECURITY_DESCRIPTOR,

    pub fn initDefault() ObjectSecurity {
        return .{
            .sd = SECURITY_DESCRIPTOR.initDefault(),
        };
    }

    pub fn initNullDacl() ObjectSecurity {
        return .{
            .sd = SECURITY_DESCRIPTOR.initNullDacl(),
        };
    }

    pub fn checkAccess(self: *const ObjectSecurity, user_token: *const anyopaque, desired_access: ACCESS_MASK) bool {
        return self.sd.checkAccess(user_token, desired_access);
    }
};

test "SECURITY_DESCRIPTOR default allows SYSTEM full access" {
    const token_mod = @import("token.zig");
    const sd = SECURITY_DESCRIPTOR.initDefault();
    const sys_token = token_mod.createSystemToken();
    try std.testing.expect(sd.checkAccess(&sys_token, 0xFFFF_FFFF));
}

test "SECURITY_DESCRIPTOR default allows admin full access" {
    const token_mod = @import("token.zig");
    const sd = SECURITY_DESCRIPTOR.initDefault();
    var admin_token = token_mod.createUserToken(0);
    admin_token.is_elevated = true;
    try std.testing.expect(sd.checkAccess(&admin_token, 0xFFFF_FFFF));
}

test "SECURITY_DESCRIPTOR default allows user read access but denies write" {
    const token_mod = @import("token.zig");
    const sd = SECURITY_DESCRIPTOR.initDefault();
    const user_token = token_mod.createUserToken(0);
    // Read access should be allowed
    try std.testing.expect(sd.checkAccess(&user_token, 0x0000_0001));
    // Write/delete access should be denied
    try std.testing.expect(!sd.checkAccess(&user_token, 0x0001_0000));
}

test "Null DACL allows all access" {
    const token_mod = @import("token.zig");
    const sd = SECURITY_DESCRIPTOR.initNullDacl();
    const user_token = token_mod.createUserToken(0);
    try std.testing.expect(sd.checkAccess(&user_token, 0xFFFF_FFFF));
}
