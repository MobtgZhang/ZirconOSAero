# NT 6.1 Graphics and Win32k Scaffold Notes

> This page corresponds to the **Phase B / C / D / F** incremental deliverables in the implementation plan (clean-room, public documentation behavior only).
> **Unfinished items table** (rolling): [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md).

**Phase naming**: Phase B/C/D/F here are **not** the same as Roadmap Phase 0–11. See [cn/README.md](../cn/README.md) §Phase table.

## Phase B — `gpu_device.zig`

- [`src/drivers/video/core/gpu_device.zig`](../../src/drivers/video/core/gpu_device.zig) provides `GpuDevice` + `VTable`, currently a **ramfb placeholder**.
- [`src/drivers/video/virtio/virtio_gpu_spec.zig`](../../src/drivers/video/virtio/virtio_gpu_spec.zig) is VirtIO-GPU **command and header layout** (public spec constants); [`virtio_gpu_pci.zig`](../../src/drivers/video/virtio/virtio_gpu_pci.zig) probes when PCI enumerates **1af4:1050** and logs; control queue and scanout wiring awaits milestone completion.
- Future: implement command subset (`RESOURCE_CREATE_2D`, `SET_SCANOUT`, `FLUSH`, etc.) on `gpu_device`, referencing the [VirtIO 1.2 spec](https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html).
- Kernel build disables SIMD: pixel blending and blur must use **scalar** or architecture-allowed alternatives.

## Phase C — `win32k/mod.zig`

- [`src/subsystems/win32k/mod.zig`](../../src/subsystems/win32k/mod.zig) provides `HWND` / `Window` table, Z-order traversal, and **per-thread message queue** minimal implementation (`PostMessage` / `peekMessage`); full routing to `input_hub` is still TODO.

## Phase D — Compositor and Event-Driven

- Desktop main loop evolution: **VSync / input / surface dirty-mark** wakeup to reduce spinning (see [`AeroDesktopRuntime.md`](AeroDesktopRuntime.md)). `display_flip_journal.zig` records `present` generations and reduces `input_hub` tail polling density during idle streaks.
- Aero blur: multi-pass box blur approximating Gaussian; degrades to semi-transparent fill if performance is insufficient.

## Phase F — Scheduling and SMP

- See [`NT61_CONTRACT_MATRIX.md`](NT61_CONTRACT_MATRIX.md) and `src/ke/scheduler.zig` for authority. **Priority Boost / Decay, foreground quota** are tracked in `tests/nt61_phase_f_scheduler_gap.zig` comments.

## QEMU Window and Resolution

- See [`AeroDesktopRuntime.md`](AeroDesktopRuntime.md) §4.2.2 and `build.conf` / `make sync-resolution`. **Default** `QEMU_GTK_ZOOM=zoom-to-fit=off` (1:1); use `make run-qemu-zoom-fit` for window-fit scaling.

## Display Mode Change Specification (IOCTL_DISPLAY_SET_MODE)

This section specifies the **in-kernel display mode change** behavior after desktop is ready (`display_state == desktop_mode` and framebuffer initialized). Independent of WDDM/KMD.

### IOCTL: `IOCTL_DISPLAY_SET_MODE` (0x000A0004)

- **Buffer method**: `METHOD_BUFFERED` (kernel IRP uses `buffer_ptr` + `buffer_size`).
- **Minimum input**: `sizeof(DisplaySetModeRequestV1)` (32 bytes, see below).
- **Success**: `STATUS_SUCCESS`, `information = 0`.
- **Errors**:
  - `STATUS_BUFFER_TOO_SMALL`: insufficient `buffer_size`.
  - `STATUS_INVALID_PARAMETER`: `version != 1`, width/height out of range, `bpp != 32`, invalid pitch.
  - `STATUS_INVALID_DEVICE_REQUEST`: not desktop mode or framebuffer not initialized.
  - `STATUS_INSUFFICIENT_RESOURCES`: LoongArch ramfb new size exceeds boot-time reserved scanout bytes.
  - `STATUS_NOT_SUPPORTED`: non-ramfb and cannot fit new size in current physical buffer.

### Struct: `DisplaySetModeRequestV1` (little-endian, C ABI alignment)

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 | version | must be `1` |
| 4 | u32 | flags | reserved, fill `0` |
| 8 | u32 | width | logical width, suggested 320–16384 |
| 12 | u32 | height | logical height, suggested 240–16384 |
| 16 | u8 | bpp | only `32` currently supported |
| 17 | u8 | pixel_bgr | `1` = BGRx order (UEFI GOP common); `0` = RGBx |
| 18 | u8[2] | reserved | fill 0 |
| 20 | u32 | pitch | byte stride; `0` means `width * 4` |
| 24 | u64 | fb_address | framebuffer **physical** base; `0` = keep current base (LoongArch ramfb still `RAMFB_PHYS`) |

**LoongArch64 supplement**: `fb_address != 0` and different from current desktop surface base → must be **page-aligned**; call `hal/loongarch64/ramfb.zig` `runtimeReconfigureAtGuestPhys`. `width×height×4` must not exceed `guest_reserved_scanout_bytes`.

### Kernel Application Sequence

1. `cursor_plane.invalidate()`
2. If VirtIO-GPU scanout active: **detach backing → unref scanout resource**, then rebuild
3. LoongArch: if current scanout is ramfb, call `ramfb.runtimeReconfigure`
4. `framebuffer.init(phys, w, h, pitch, bpp, pixel_bgr)`
5. Update `desktop_ctx.surface`, `dwm.applyPlatformAndResolutionTuning(w, h)`
6. `hdmi.syncFramebufferMode` (stub + metadata)
7. Mouse centering, `setScreenBounds`, `virtio_input_pci.resetPointerBaseline`
8. If GPU brought up: `trySetupScanoutFromFramebuffer()`

### Regression Matrix

| Scenario | QEMU device | Operation |
|---------|-------------|-----------|
| LA64 ramfb | `-device ramfb` | boot 1024×768 → IOCTL 1280×720 → should succeed |
| LA64 ramfb over-limit | same | IOCTL 3840×2160 → should fail if over reserved |
| VirtIO-GPU | `virtio-gpu-pci` + guest RAM scanout | mode switch should still show pixel updates |
| VirtIO input | `virtio-tablet` | pointer bounds reset after switch, no "stuck corner" |
