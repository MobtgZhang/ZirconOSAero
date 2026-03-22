//! Compile-time embedded default configuration data.
//! This file lives in the config/ directory so that @embedFile can
//! resolve the .conf files relative to this source file's location.

pub const system_conf = @embedFile("system.conf");
pub const boot_conf = @embedFile("boot.conf");
pub const desktop_conf = @embedFile("desktop.conf");
