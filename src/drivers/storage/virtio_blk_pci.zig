// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/virtio_blk_pci.zig
// Purpose: VirtIO block PCI（1af4:1042）探测 + **IRP_MJ_READ** 合成盘最小闭环（STORAGE_IO_ROADMAP 烟测）。
//
// This is an independent clean-room implementation.
// Ref: Virtual I/O Device (VIRTIO) Version 1.2 — Block Device；WDK 存储栈行为描述（learn.microsoft.com）。
// Milestone: [docs/cn/STORAGE_IO_ROADMAP.md](../../../docs/cn/STORAGE_IO_ROADMAP.md)

const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

pub const pci_vendor_virtio: u16 = 0x1AF4;
pub const pci_device_virtio_blk: u16 = 0x1042;

var logged_once: bool = false;
var virtio_blk_pci_seen: bool = false;

var stub_driver_idx: u32 = 0;
var stub_device_idx: u32 = 0;
var stub_registered: bool = false;

pub fn isVirtioBlkPciPresent() bool {
    return virtio_blk_pci_seen;
}

pub fn getStubDeviceIndex() u32 {
    return stub_device_idx;
}

fn blkDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .read => {
            irp.syncSystemBuffer();
            if (irp.buffer_ptr == 0) {
                irp.complete(io.STATUS_INVALID_PARAMETER, 0);
                return io.STATUS_INVALID_PARAMETER;
            }
            // `tail`：字节偏移（FAT/引导扇区烟测）；真实 virtioqueue 就绪后改为 LBA×扇区。
            const off: usize = @intCast(irp.tail);
            const dst: [*]u8 = @ptrFromInt(irp.buffer_ptr);
            var copied: usize = 0;
            while (copied < irp.buffer_size) : (copied += 1) {
                const pos = off + copied;
                if (pos >= disk_storage.len) break;
                dst[copied] = disk_storage[pos];
            }
            irp.complete(io.STATUS_SUCCESS, copied);
            return io.STATUS_SUCCESS;
        },
        .write => {
            irp.syncSystemBuffer();
            if (irp.buffer_ptr == 0) {
                irp.complete(io.STATUS_INVALID_PARAMETER, 0);
                return io.STATUS_INVALID_PARAMETER;
            }
            const off: usize = @intCast(irp.tail);
            const src: [*]const u8 = @ptrFromInt(irp.buffer_ptr);
            var copied: usize = 0;
            while (copied < irp.buffer_size) : (copied += 1) {
                const pos = off + copied;
                if (pos >= disk_storage.len) break;
                disk_storage[pos] = src[copied];
            }
            irp.complete(io.STATUS_SUCCESS, copied);
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

/// 8KiB 线性映像（16×512 扇区）；首扇区写入可识别魔数供 `submitReadSectors` 烟测。
var disk_storage: [16 * 512]u8 = undefined;

fn registerStubStack() void {
    if (stub_registered) return;
    stub_registered = true;
    @memset(&disk_storage, 0);
    const sig = "VIRTIO-BLK-IRP";
    @memcpy(disk_storage[0..sig.len], sig);

    const didx = io.registerDriver("\\Driver\\VirtioBlkStub", blkDispatch) orelse {
        klog.warn("VirtIO-Blk: registerDriver failed", .{});
        return;
    };
    stub_driver_idx = didx;
    stub_device_idx = io.createDevice("\\Device\\VirtioBlk0", .disk, didx) orelse {
        klog.warn("VirtIO-Blk: createDevice failed", .{});
        return;
    };
    klog.info("VirtIO-Blk: stub disk IRP device idx=%u", .{stub_device_idx});
}

/// 经 `IRP_MJ_READ` 从合成盘读取（字节偏移 = `lba * 512`）。
pub fn submitReadSectors(lba: u64, buffer: []u8) io.NTSTATUS {
    if (!stub_registered) return io.STATUS_DEVICE_NOT_READY;
    const byte_off = lba * 512;
    if (byte_off >= disk_storage.len) return io.STATUS_INVALID_PARAMETER;
    var irp: io.Irp = .{
        .major_function = .read,
        .buffer_ptr = @intFromPtr(buffer.ptr),
        .system_buffer = @intFromPtr(buffer.ptr),
        .buffer_size = buffer.len,
        .tail = byte_off,
    };
    return io.dispatchIrp(stub_device_idx, &irp);
}

pub fn noteVirtioBlkIfPresent(vendor_id: u16, device_id: u16) void {
    if (vendor_id != pci_vendor_virtio or device_id != pci_device_virtio_blk) return;
    virtio_blk_pci_seen = true;
    registerStubStack();
    if (logged_once) return;
    logged_once = true;
    klog.info("VirtIO-Blk PCI (1af4:1042) detected — IRP stub device registered", .{});
}
