/* LoongArch64 AP (Application Processor) Entry Point
 * AP 启动序列：与 RISC-V 实现对齐，但针对 LoongArch CSR 调整。
 *
 * 启动流程：
 * 1. QEMU/OpenSBI 通过 IOCSR mailbox 唤醒 AP，PC 跳转到 loongarch_ap_entry
 * 2. AP 执行以下最小初始化：
 *    - 禁用中断（ECFG.IM = 0）
 *    - 设置栈指针（从 BSP 设置的全局变量读取）
 *    - 加载页表根地址（CSR.PGDL）
 *    - 配置 trap vector（CSR.EENTRY + CSR.ECFG）
 * 3. 调用 Zig 函数 loongarch_ap_init() 进入 idle 循环
 *
 * 全局变量（存储在 .bss，由 BSP 在 wakeApplicationProcessorsStub 中设置）：
 *   la64_ap_stack_top: AP 栈顶地址
 *   la64_ap_pgdl: AP 页表根地址（PGDL CSR 值）
 *   loongarch_exc_vectors: 异常向量基址（由链接脚本确定）
 */

    .section .text.ap_entry, "ax", @progbits
    .globl loongarch_ap_entry
    .type loongarch_ap_entry, @function
    .align 4

loongarch_ap_entry:
    /* 禁用所有中断：ECFG.IM = 0 */
    /* LoongArch CSR 地址：ECFG = 0x4 */
    csrwr    $zero, 0x4              /* ECFG = 0，禁用所有中断 */

    /* 从 .bss 加载 AP 栈顶地址到 t0 */
    la.local $t0, la64_ap_stack_top
    ld.d     $sp, $t0, 0              /* SP = [la64_ap_stack_top] */

    /* 从 .bss 加载页表根地址到 t1 */
    la.local $t0, la64_ap_pgdl
    ld.d     $t1, $t0, 0              /* t1 = [la64_ap_pgdl] */

    /* 如果页表根有效，设置 PGDL 并刷新 TLB */
    beq      $t1, $zero, .Lno_paging

    /* 设置 PGDL CSR（页表根地址） */
    csrwr    $t1, 0x18               /* PGDL = t1 */

    /* INVTLB.ALL：全局刷新 TLB */
    /* op=0 表示清除所有 TLB 条目；rj/rk=r0 表示不限定 ASID/VA */
    invtlb   0, $r0, $r0

.Lno_paging:
    /* 配置 trap vector：EENTRY 指向 loongarch_exc_vectors */
    la.local $t0, loongarch_exc_vectors
    csrwr    $t0, 0xc               /* EENTRY = loongarch_exc_vectors */

    /* 配置 ECFG：VS=7（512B 向量间距），IM=0（禁用中断） */
    /* VS 位于 ECFG[18:16]，设置为 7 → 向量间距 = 4 << 7 = 512B */
    /* 注意：实际值是 7 << 14 = 0x1c000（不是 7 << 16），这是硬件实现决定的 */
    li.w     $t2, 0x1c000            /* ECFG.VS=7, IM=0 */
    csrwr    $t2, 0x4                /* ECFG = 0x1c000 */

    /* 内存屏障确保 CSR 写入完成 */
    dbar     0

    /* 加载 AP boot params 指针到 t0，传递给 Zig */
    la.local $t0, la64_ap_boot_params_ptr
    ld.d     $t0, $t0, 0              /* t0 = [la64_ap_boot_params_ptr] */

    /* 调用 Zig 函数 loongarch_ap_init() - t0 已设置 */
    bl       loongarch_ap_init

    /* loongarch_ap_init() 不返回，进入 idle 循环 */
.Lhang:
    idle     0                     /* 等待中断/事件 */
    b        .Lhang

.size loongarch_ap_entry, .-loongarch_ap_entry

/* Per-hart 全局变量（由 BSP 在启动前写入，AP 在启动后读取）
 * 存储在 .bss，必须在低 2GiB 线性映射区域
 */
    .section .bss.ap_smp, "aw", @nobits
    .align 8

/* AP 栈顶地址（BSP 将其设置为 ap_stacks[hart_id] + AP_STACK_SIZE） */
la64_ap_stack_top:
    .quad   0

/* AP 页表根地址（BSP 设置为内核页表基址） */
la64_ap_pgdl:
    .quad   0

/* AP 启动参数结构指针（BSP 填充，AP 读取） */
la64_ap_boot_params_ptr:
    .quad   0