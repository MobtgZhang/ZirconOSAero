# Aero Desktop Runtime Architecture and Input Debugging

This document describes the **desktop path actually running on QEMU/real hardware** (kernel framebuffer + main loop), its relationship with the `src/desktop/aero/` asset repository, and the troubleshooting sequence when the mouse does not move.

## 1. Data Flow (Kernel)

1. **`src/main.zig`**: after desktop is ready, loops: `input_hub.pollAll()`, `mouse.popEvent()`, `display.handleMouseMove` / `handleClick`; then `display.renderDesktopFrameEx(scene_dirty, ...)` and `present()`.
2. **`src/drivers/input/input_hub.zig`**: `virtio_input_pci.poll()`; on **x86_64** only called when VirtIO-Input PCI is **not** attached. **IRQ12** in `arch/x86_64/mod.zig` `handleMouseIrq` similarly skips, avoiding double-source displacement with QEMU default virtio-mouse/tablet.
3. **`src/drivers/input/virtio_input_pci.zig`**: parses Linux `input_event` and calls `mouse.deliverMouseEvent`.
4. **`src/drivers/video/core/display.zig`**: syncs smoothed coordinates from `mouse.getX/Y`; scene compositing via `renderer_aero.renderFrameEx(false)`; pointer drawn by **software cursor layer** (save-under).
5. **`src/drivers/video/desktop/renderer_aero.zig`**: draws wallpaper preset, desktop icons, Explorer, taskbar, Start menu, etc.

`src/desktop/aero/` provides **resource manifest**, theme defaults (`nt61_aero_defaults`), and reusable libraries; icon IDs and wallpaper filenames must align with kernel path.

## 2. Non-x86 Main Loop Idle

`src/arch.zig` `waitForInterrupt` uses **short spin** on **non-x86_64** instead of WFI, so it can still poll `input_hub` without full IRQ (see source comments).

**LoongArch64**: `waitForInterruptDesktop()` **always** short-spins (decoupled from `idle 0` timer/IRQ wake path). VirtIO-Input currently relies on **MMIO polling**; if PCH/LIOINTC does not reliably wire device MSI/line IRQ to `ke/interrupt_loongarch.zig`, pointer update frequency approaches main-loop throughput rather than "one frame per device IRQ".

**x86_64 desktop** default calls `waitForInterruptDesktop()`: `-Ddesktop_idle_spin=true` (default) → short spin; `-Ddesktop_idle_spin=false` → `sti` + `hlt`, requires IRQ1/IRQ12 and VirtIO line/MSI to reliably wake CPU.

## 3. Mouse Not Moving: Troubleshooting Chain

| Step | Check |
|------|-------|
| Boot log | Whether VirtIO-Input PCI successfully attached; whether `no 1af4:1052` (device missing) appears |
| Boot log | `Input:` line: `VirtIO_Input_PCI=active` |
| Boot log | `InputDiag:` line: `MOUSE_DEBUG` / `AGENT_NDJSON` / `AMD_IGPU` / `idle_spin` switch summary |
| Boot log | After entering desktop: `Desktop: fb ... mouse=(x,y) bounds=`: if coordinates stuck at corner and bounds inconsistent with GOP, may be clamped by `clampPosition` |
| Emulator | Whether `virtio-mouse-pci` / `virtio-keyboard-pci` in Makefile match current `ARCH` |
| Isolate AMD | `make AMD_IGPU=false` (or `zig build -Damd_igpu=false`) to exclude AMD PCI/BAR probe |
| Isolate Intel | `make INTEL_IGPU=false` (default false); toggle to exclude Intel probe |
| Optional `MOUSE_DEBUG=true` | Serial `mouseDbg`: whether `desktop tick` increments; whether `virtio inst` `used.idx` changes with operations |
| Optional `AGENT_NDJSON=true` | Serial `AGENT_LOG:` lines; `hypothesisId` meanings: see `src/debug/agent_ndjson.zig` (H1/H2/H3/H4/H6/H7) |
| Optional `desktop_bisect=true` | `zig build -Ddesktop_bisect=true`: adds `klog.debug` around `renderDesktopFrameEx` and outputs `scheduler` tick delta |
| "Frozen" | Usually **single-frame CPU box blur too long** (high-res GOP). Check `DesktopGOP:` serial dimensions; lower blur constants in `nt61_aero_defaults` or see [DesktopManagerSpec.md](DesktopManagerSpec.md) §8 |
| LoongArch | `vm.remapIdentityVirtPageUncached` and VirtIO ring GPA |
| Real hardware USB | No USB HID mouse driver currently; only PS/2 and VirtIO-Input PCI are reliable |

## 3.0 Blur Stats Baseline (PR Regression Comparison)

`-Ddwm_blur_stats=true`: each frame outputs serial **`dwm blur frame:`** (fields: `box_blur_calls`, `budget_denials`, `tint_only_calls`). Compare **same build + same QEMU resolution** before/after PR. Not compared against real Windows 7 values.

| Scenario | Expected trend |
|----------|---------------|
| Cold boot first frame (`present_count==0`) | `box_blur_calls` noticeably low or near 0; `tint_only_calls` varies with shell |
| Static desktop, no Start menu | `box_blur_calls` correlates with window/taskbar strip count |
| Opening Start menu / shell flyout | `setGlassLiteBlurEnabled` + `renderGlassTintOnly` path → `tint_only_calls` up, `box_blur_calls` relatively controlled |

## 4. QEMU Window and Resolution

Default `QEMU_GTK_ZOOM=zoom-to-fit=off` (1:1); use `make run-qemu-zoom-fit` for window-fit scaling. For host-side scaling on x86, use `make run-qemu-sdl` (SDL).

## 5. Key Source Paths

- Main loop: `src/main.zig`
- Input hub: `src/drivers/input/input_hub.zig`
- Display: `src/drivers/video/core/display.zig`
- Renderer: `src/drivers/video/desktop/renderer_aero.zig`
- Compositor: `src/drivers/video/core/dwm_compositor.zig`
- VirtIO input: `src/drivers/input/virtio_input_pci.zig`
- VirtIO GPU: `src/drivers/video/virtio/virtio_gpu_pci.zig`

## 6. Related Docs

- [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) — subsystem status
- [DesktopManagerSpec.md](DesktopManagerSpec.md) — desktop manager spec
- [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) — DWM notification model
- [SOFTWARE_COMPOSITOR_WDDM.md](../cn/SOFTWARE_COMPOSITOR_WDDM.md) — compositor and WDDM
- [PointerPolicy_NT61.md](../cn/PointerPolicy_NT61.md) — pointer policy
- [MVT_NT61.md](MVT_NT61.md) — verification steps
