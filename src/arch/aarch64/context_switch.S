/* AArch64 cooperative context switch.
 * Layout matches A64ThreadContext in thread_switch.zig (13 x u64 = 104 bytes):
 *   x19, x20, x21, x22, x23, x24, x25, x26, x27, x28, x29(fp), x30(lr), sp
 */

.section .text
.global aarch64_switch_context
.type aarch64_switch_context, @function
.align 4
aarch64_switch_context:
    /* x0 = from (A64ThreadContext*), x1 = to (A64ThreadContext*) */
    /* Save callee-saved registers into *from */
    str x19, [x0, #0]
    str x20, [x0, #8]
    str x21, [x0, #16]
    str x22, [x0, #24]
    str x23, [x0, #32]
    str x24, [x0, #40]
    str x25, [x0, #48]
    str x26, [x0, #56]
    str x27, [x0, #64]
    str x28, [x0, #72]
    str x29, [x0, #80]
    str x30, [x0, #88]
    mov x2, sp
    str x2,  [x0, #96]

    /* Restore callee-saved registers from *to */
    ldr x19, [x1, #0]
    ldr x20, [x1, #8]
    ldr x21, [x1, #16]
    ldr x22, [x1, #24]
    ldr x23, [x1, #32]
    ldr x24, [x1, #40]
    ldr x25, [x1, #48]
    ldr x26, [x1, #56]
    ldr x27, [x1, #64]
    ldr x28, [x1, #72]
    ldr x29, [x1, #80]
    ldr x30, [x1, #88]
    ldr x2,  [x1, #96]
    mov sp, x2
    ret
.size aarch64_switch_context, .-aarch64_switch_context

.global aarch64_thread_trampoline
.type aarch64_thread_trampoline, @function
.align 4
aarch64_thread_trampoline:
    /* Entry address was pushed on the stack by initNewThread */
    ldr x0, [sp]
    add sp, sp, #8
    br x0
.size aarch64_thread_trampoline, .-aarch64_thread_trampoline
