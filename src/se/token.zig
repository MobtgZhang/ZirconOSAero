//! Security Reference Monitor (NT style)
//! Token, SID, and access check mechanism
//!
//! 访问检查失败时，调用方可经 `se/audit.zig` 的 `logAccessDenied` / `logObjectOpenDenied` 写入审计（与 `NTSTATUS` 返回值配合）。
//!
//! 里程碑（clean-room，仅 WDK/MS Learn 行为描述）：**令牌模拟（impersonation）**、完整 **SACL/ACL** 编辑器与对象审计策略为长期项；当前为演示路径子集。跟踪：[docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K6.3。
// **P4-B2**：线程级 `Impersonate*` / 还原令牌的 IRQL 与亲和约束为文档化简化；生产语义见 WDK `SeImpersonateClientEx` 类说明。

const std = @import("std");
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

/// NT Phase 3: object access via the process handle table (delegates to `ob.HandleTable.checkAccess`).
pub fn checkHandleAccess(table: *const ob.HandleTable, handle: ob.Handle, required: ob.ACCESS_MASK) bool {
    return table.checkAccess(handle, required);
}

/// Whether `desired_access` is allowed for a generic file object (DACs simplified).
pub fn canOpenFileForAccess(tok: *const Token, desired_access: ob.ACCESS_MASK) bool {
    const object_grants: u32 = ob.GENERIC_READ | ob.GENERIC_WRITE | ob.GENERIC_EXECUTE | ob.SYNCHRONIZE;
    return checkAccess(tok, desired_access, object_grants);
}

/// 最小 SeAccessCheck 等价路径：`desired` 须由 `object_grants` 掩码完全覆盖（与 WDK 访问掩码语义同构的简化）。
/// Ref: https://learn.microsoft.com/windows-hardware/drivers/ddi/wdm/nf-wdm-seaccesscheck （行为级；无 Windows 源码）。
pub fn seAccessCheckMask(tok: *const Token, desired: ob.ACCESS_MASK, object_grants: ob.ACCESS_MASK) bool {
    if (tok.owner.eql(SYSTEM_SID)) return true;
    if (tok.is_elevated) return true;
    return (object_grants & desired) == desired;
}

/// K6.3 子集：进程绑定桌面与**活动桌面**不一致时拒绝对话级 GUI（与 csrss `handleApiCall` 门闸一致）。
/// 系统 SID 或 **已提升且含 TCB** 的令牌可跨桌面（服务路径占位；完整 DACL 见路线图）。
/// Ref: https://learn.microsoft.com/windows/win32/winstation/window-stations-and-desktops
pub fn seAccessActiveDesktopForWin32k(tok: *const Token, process_desktop_idx: u32, active_desktop_idx: u32) bool {
    if (process_desktop_idx == active_desktop_idx) return true;
    if (tok.owner.eql(SYSTEM_SID)) return true;
    if (tok.is_elevated and tok.hasPrivilege(PRIV_TCB)) return true;
    return false;
}

pub fn init() void {
    next_token_id = 1;
    klog.info("Security: Reference Monitor initialized", .{});
}

test "seAccessActiveDesktopForWin32k denies inactive desktop for plain user" {
    var tok = createUserToken(0);
    try std.testing.expect(seAccessActiveDesktopForWin32k(&tok, 1, 0) == false);
    try std.testing.expect(seAccessActiveDesktopForWin32k(&tok, 0, 0));
}

test "seAccessActiveDesktopForWin32k allows system sid cross-desktop" {
    const tok = createSystemToken();
    try std.testing.expect(seAccessActiveDesktopForWin32k(&tok, 9, 0));
}

test "seAccessActiveDesktopForWin32k allows elevated TCB cross-desktop" {
    var tok = createUserToken(0);
    tok.is_elevated = true;
    tok.privileges = PRIV_TCB;
    try std.testing.expect(seAccessActiveDesktopForWin32k(&tok, 3, 0));
}
