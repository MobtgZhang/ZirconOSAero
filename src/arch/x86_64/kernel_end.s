# SPDX-License-Identifier: MIT OR Apache-2.0
#
# ZirconOSAero - NT 6.1 Compatible Kernel
# Module: src/arch/x86_64/kernel_end.s
# Purpose: Export _kernel_end as first VA past .bss (linker places .kernel_image_end after .bss).
#
# Zig 自托管链接器对脚本里纯赋值 _kernel_end 可能不导出；用独立 NOBITS 节 + 全局符号供 main PFN 保留。

.section .kernel_image_end, "aw", @nobits
.align 16
.global _kernel_end
_kernel_end:
