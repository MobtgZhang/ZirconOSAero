//! Boot entry dispatch. Keeps firmware ABI details out of application-facing code.

const builtin = @import("builtin");

pub fn start(magic: u32, info_addr: usize) noreturn {
    switch (builtin.target.cpu.arch) {
        .x86_64 => @import("boot_native.zig").start(magic, info_addr),
        else => @import("../kernel/boot_generic.zig").start(magic, info_addr),
    }
}
