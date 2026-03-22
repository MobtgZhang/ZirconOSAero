//! Compile-time embedded default configuration data.
//! @embedFile 相对于本文件路径加载同目录下的 .conf。

pub const system_conf = @embedFile("system.conf");
pub const boot_conf = @embedFile("boot.conf");
pub const desktop_conf = @embedFile("desktop.conf");
