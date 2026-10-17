// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - x86_64 Ring 3 transition.

const gdt = @import("../../hal/x86_64/gdt.zig");
const paging = @import("paging.zig");

pub fn enterUserMode(user_rip: u64, user_rsp: u64, cr3_phys: u64) noreturn {
    asm volatile (
        \\ movq %[user_rip], %%rdi
        \\ movq %[user_rsp], %%rsi
        \\ movq %[cr3], %%rbx
        \\ movw %[user_ss], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ pushfq
        \\ popq %%r8
        \\ orq $0x200, %%r8
        // Construct the IRET frame on the current kernel stack.  It remains
        // reachable through the shared kernel low-half mappings after CR3 is
        // activated.  Writing the frame on the user stack before the switch
        // would target a different physical page and corrupt the return RIP.
        // Build the IRET frame by pushing fields in reverse order.  This keeps
        // the frame on the current kernel stack and avoids explicit memory
        // displacement mistakes during the Ring 0 -> Ring 3 transition.
        \\ pushq %[user_ss]
        \\ pushq %%rsi
        \\ pushq %%r8
        \\ pushq %[user_cs]
        \\ pushq %%rdi
        \\ movq $0x3F8, %%rdx
        \\ movb $0x55, %%al
        \\ outb %%al, %%dx
        \\ movq %%rbx, %%cr3
        \\ movb $0x43, %%al
        \\ outb %%al, %%dx
        \\ invlpg (%%rdi)
        \\ movb $0x44, %%al
        \\ outb %%al, %%dx
        \\ movq $0x5A, %%rax
        \\ movb %%al, (%%rsi)
        \\ iretq
        :
        : [user_rip] "r" (user_rip),
          [user_rsp] "r" (user_rsp),
          [cr3] "r" (cr3_phys),
          [user_ss] "n" (gdt.USER_SS),
          [user_cs] "n" (gdt.USER_CS),
        : .{ .rax = true, .r8 = true, .rdx = true, .memory = true });

    unreachable;
}
