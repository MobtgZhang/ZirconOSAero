const std = @import("std");
const security_descriptor = @import("se/security_descriptor.zig");

comptime {
    std.testing.refAllDecls(security_descriptor);
}
