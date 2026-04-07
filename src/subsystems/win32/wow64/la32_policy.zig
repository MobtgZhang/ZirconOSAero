//! LoongArch32（LA32）与 x86 WOW64 **不同** ABI；此处仅 VA 上界等常数占位，供将来独立装载器使用。

pub const la32_user_va_max: u32 = 0x7FFF_FFFF;
