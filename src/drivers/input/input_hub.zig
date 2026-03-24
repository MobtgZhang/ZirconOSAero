//! 输入总线聚合：VirtIO-Input PCI 与 PS/2 8042 同一轮询入口，避免 mouse.zig ↔ virtio 循环依赖。
const builtin = @import("builtin");

pub fn pollAll() void {
    const virtio_input_pci = @import("virtio_input_pci.zig");
    virtio_input_pci.poll();
    if (builtin.target.cpu.arch == .x86_64) {
        const mouse = @import("mouse.zig");
        // 始终排空 PS/2：与 VirtIO-Input 并行，QEMU 上常见双路鼠标。
        mouse.poll();
    }
}
