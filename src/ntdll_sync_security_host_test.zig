const std = @import("std");
const ntdll = @import("libs/ntdll.zig");
const ob = @import("ob/object.zig");
const token = @import("se/token.zig");

const hooks = ntdll.TestHooks;

const ACCESS_NOT_GRANTED: u32 = 0x0020_0000;

fn checkDefaultSyncSecurity(hdr: *ob.ObjectHeader) !void {
    const user_token = token.createUserToken(0);
    var elevated_token = token.createUserToken(0);
    elevated_token.is_elevated = true;

    try std.testing.expect(hdr.security != null);
    try std.testing.expectEqual(&hdr.security_storage, hdr.security.?);
    try std.testing.expect(!hdr.security.?.checkAccess(&user_token, ACCESS_NOT_GRANTED));
    try std.testing.expect(hdr.security.?.checkAccess(&elevated_token, ACCESS_NOT_GRANTED));
}

test "event pool initializes default security" {
    const ptr = hooks.allocEventObjectFn(false, ntdll.SYNCHRONIZATION_EVENT) orelse return error.NoMemory;
    try checkDefaultSyncSecurity(@ptrFromInt(ptr));
}

test "mutex pool initializes default security" {
    const ptr = hooks.allocMutexObjectFn(false) orelse return error.NoMemory;
    try checkDefaultSyncSecurity(@ptrFromInt(ptr));
}

test "semaphore pool initializes default security" {
    const ptr = hooks.allocSemaphoreObjectFn(0, 1) orelse return error.NoMemory;
    try checkDefaultSyncSecurity(@ptrFromInt(ptr));
}

test "event creation validates event type" {
    try std.testing.expectEqual(ntdll.STATUS_SUCCESS, hooks.validateEventCreateEventTypeFn(ntdll.NOTIFICATION_EVENT));
    try std.testing.expectEqual(ntdll.STATUS_SUCCESS, hooks.validateEventCreateEventTypeFn(ntdll.SYNCHRONIZATION_EVENT));
    try std.testing.expectEqual(ntdll.STATUS_INVALID_PARAMETER, hooks.validateEventCreateEventTypeFn(2));
}
