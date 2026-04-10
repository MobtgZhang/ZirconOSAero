# NT 6.1 Explicitly Deferred Surfaces (Non-Blocking Kernel Milestones)

> This document is consistent with [Roadmap.md](Roadmap.md) §6 **Deferred surfaces**. It tracks items that are **not** kernel milestone blockers before **MM / SMP / process isolation / I/O baseline** are stable.

## Deferred Items

| Track | Description |
|-------|-------------|
| Full WDDM / GPU off-screen composition | Current: CPU framebuffer + software compositing demo path; does not claim Windows 7 display driver model parity. Optional milestones in `virtio_gpu` / `HAL_USB_NET_ROADMAP.md`. |
| Full Win32 / user32 / gdi32 | Subsystem and shell in `src/subsystems/win32/`, `src/desktop/aero/`; expand after kernel objects and VM semantics tighten. |
| Full WOW64 / `wow64cpu`-class semantics | Phase G has landed a **testable subset** (thunk, marshal, UTF-16 file and HKLM\SOFTWARE redirection, `ProcessWow64Information`, ZOA slot `NtTerminateThread`); **still deferred**: x86 user-mode instruction-level emulation and SEH32, commercial `ntdll32` loading, full HKCR/HKCU logical view mirroring, API-by-API full parity with commercial SysWOW64. |
| NT 32-level priority / full boost | Scheduler is an approximation; see [SCHEDULER_API.md](../cn/SCHEDULER_API.md). |
| Full TCP / production-grade networking | IPv4/UDP is roadmap prototype; see [HAL_USB_NET_ROADMAP.md](../cn/HAL_USB_NET_ROADMAP.md). |
| ACPI AML interpreter | Without AML, depends on static tables and QEMU path; AML introduction requires separate milestone and audit. |
| ACPI S1–S4, `_PTS`/`_WAK`, EC full sleep | **I10**: shutdown/reset can go through FADT fixed register subset; **deep sleep and AML state machine** decoupled from this milestone. |

## Cross-Process HWND and Shared Surfaces (Non-Current Goal)

This repository **does not** treat "process A's thread directly manipulating process B's `HWND` queue" or "kernel `RedirectedSurface` cross-process VM sharing" as an NT 6.1 subset acceptance item.

**Future sketch** (clean-room, no internal NT structure speculation): via (1) explicit **IOCTL** or **LPC large message** carrying "target session + surface id + capability token"; (2) Object Manager **handle duplication** with desktop gate expansion; (3) section view mapping user bitmap to **single-owner process** compositing path. Before landing, must bump [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) version and add host payload layout tests.

## Maintenance

When adjusting deferred boundaries, synchronize this file, [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md), root [README.md](../../README.md), and [Subsystems.md](Subsystems.md).
