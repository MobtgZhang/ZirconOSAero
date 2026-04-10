# Unfinished Items Rolling Checklist (vs. Implementation Status and Graphics Scaffold)

> Cross-references: [IMPLEMENTATION_STATUS_NT61.md](IMPLEMENTATION_STATUS_NT61.md), [PROCESS_NT61.md](PROCESS_NT61.md), [NT61_GRAPHICS_SCAFFOLD.md](NT61_GRAPHICS_SCAFFOLD.md), [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md).
> **Phase naming**: Phase B/C/D/E... here are **not** Roadmap Phase 0–11. See [cn/README.md](../cn/README.md) §Phase table.

**Copyright**: MSDN/WDK / hardware + VirtIO public specs only; no Windows/ReactOS/Wine source.

---

## A (Build and Baseline) — Partially done, can continue hardening

| Item | Status | Notes |
|------|--------|-------|
| A0 Completion narrative | ongoing | Authority: [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md), [MVT_NT61.md](MVT_NT61.md) |
| A1 MBR/VBR/Stage2 | fixed mainline | continue `make build-zbm-bios` / smoke regression |
| A2 Desktop `root.zig` freestanding | partial | `zig build desktop-aero-freestanding`; full `root.zig` dependency chain and kernel HAL wiring still TODO |
| A3 Resources / dependencies | partial | `fetch-assets` placeholder art; real wallpaper/font flow can be further automated |
| A4 RISC-V UEFI entry | added `main_riscv64.zig` | GNU-EFI linking and real hardware verification still depend on community path |
| A5 Zig version | aligned with CI | sync `build.zig.zon` + workflow when upgrading Zig |

---

## P / Q (PowerShell / QEMU) — Related roads closed (≠ kernel overall completion)

- PowerShell / ZirconShell: **removed** from kernel and menu paths; contract matrix §5.2 and BuiltinApps roadmap note **user-mode .NET** (outside repo). "Done" here means **removal/redirect**, not other kernel subsystems delivered.
- QEMU window and resolution: **default** `QEMU_GTK_ZOOM=zoom-to-fit=off` (1:1, consistent with `build.conf` `RESOLUTION`); scaling modes: `make run-qemu-zoom-fit`; **SDL backend**: `make run-qemu-sdl`.

---

## Phase B — Graphics Foundation (significant remaining work)

- **B1** Double buffering, dirty rectangles, VSync beat deep integration with existing `framebuffer`/`display` (not just comments).
- **B2** VirtIO-GPU (1af4:1050) 2D: PCI/MMIO, queue bring-up, `SET_SCANOUT`, `RESOURCE_ATTACH_BACKING`, `present` + `RESOURCE_FLUSH` already done; host tests (`virtio_gpu_spec.zig`), present backend (`display_backend.zig`). **Still TODO / Phase4-Plus**: second-plane off-screen resources, non-empty `SUBMIT_3D` payload, user-mode submission boundary (see [../cn/VirtioVirglMVP.md](../cn/VirtioVirglMVP.md), [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)).
- **B3** Scalar 2D: compositing, rounded corners, box-blur approximation (respecting kernel no-SIMD rule).

---

## Phase C — Win32k Toward Windows and Messages

- **C1** Window table, Z-order, `CreateWindowEx`/`SetWindowPos` expansion with [win32k/mod.zig](../../src/subsystems/win32k/mod.zig).
- **C2** Per-thread message queue, `PostMessage`/`GetMessage`, routing with [input_hub](../../src/drivers/input/input_hub.zig).
- **C3** `WM_NCPAINT` / hit-test skeleton.
- **C4** `HDC`, `WM_PAINT` invalidation region.
- **C5** Fonts: stb_truetype or equivalent; avoid binding FreeType upfront.

---

## Phase D — Compositor (DWM Direction)

> **Naming note**: This Phase D is **GPU/CPU composition and off-screen scenarios**. For **Win32 message pump + `WM_DWM*` + csrss LPC** Phase D checklist, see [PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md) and [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) "Phase D" section.

- **D1–D4** Off-screen surfaces, scene graph, Aero blur, animation scheduling alignment with [dwm_compositor](../../src/drivers/video/core/dwm_compositor.zig).
- **D5** Desktop loop event-driven, default reducing reliance on `desktop_idle_spin` (fix IRQ path first, then change default).

---

## Phase E — Shell (Explorer Equivalent)

Per your direction: **user-mode .NET**, not in this kernel repo. Kernel side only retains **syscall / Section / LPC** support (with Phase F).

---

## Phase F — Integration

- **F1** win32k into kernel, handle validation, aligned with user-mode syscall table (public documentation behavior).
- **F2** Real SMP: APIC, IPI, per-CPU (beyond `smp_atomic_host` test).
- **F3** Scheduler: Priority Boost/Decay, foreground quota (cross-reference existing [scheduler.zig](../../src/ke/scheduler.zig) and matrix; avoid duplicating already-existing policies).
- **F4** QEMU E2E: screenshot or serial assertions into CI.
- **F5** Documentation and "aero-only theme" narrative continuously aligned with Makefile/build.

---

## Recommended Next Iteration Priority (Engineering Order)

1. **B2 frontier**: PCI enumerate VirtIO-GPU → MMIO + queue init → single-mode scanout (x86_64 QEMU first).
2. **B1 + D5**: double buffering and desktop wake path (reduce spin) in same milestone; avoid half-baked changes.
3. **C1 + C2**: minimal `HWND` table + single-queue demo, then expand to multi-thread.
4. **F3**: add computable boost/decay formula test cases in host tests, then into kernel path.
