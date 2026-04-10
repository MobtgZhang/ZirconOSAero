# Phase 4: Hardware Acceleration and System-Level Integration (Official Scope)

> **Authority for Desktop / Display / csrss / WOW64 / Persistence** in "Phase 4". Clean-room; knowledge sources: OASIS VirtIO, hardware public manuals, Microsoft Learn **behavioral** descriptions. Personal notes directories (e.g. uncommitted `mdcs/`) are **not** contract sources. **"Phase 4" vs. Roadmap / letter Phases D–G**: [cn/README.md](../cn/README.md) §Phase table.

## Goals and Non-Goals

### Phase4-Core (Must-Deliver: Present and Integration)

- **VirtIO-GPU 2D**: PCI enumeration, MMIO, queues, `SET_SCANOUT`, `RESOURCE_ATTACH_BACKING` (single segment or multiple mem_entries), `RESOURCE_FLUSH`; silent fallback to GOP/linear framebuffer when no device.
- **Present backend strategy**: `display_backend.zig` switches between `gop_linear` and `virtio_scanout`; `-Dforce_gop_present=true` forces GOP (diagnostic/contrast).
- **WDDM relationship**: only **`wddm_abstraction.zig` concept layering** and `WddmRuntimePhase` telemetry; **does not** implement Windows KMD/UMD binary IOCTL protocol; does **not** use `DxgkDdi*` as implemented DDI names for external commitments.
- **Compositor backend (CompositorBackend)**: CPU full-path composition + optional "VirtIO responsible for scanout only"; **does not** offload Aero box blur to GPU by default.
- **csrss + LPC**: window station/desktop lifecycle via **`CsrApiNumber` + [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) vNext** fixed layouts; `user32` is API layer, aligned with `subsystem.handleApiCall`.
- **WOW64**: for **DWM / user32 related** x86 service paths, give **explicit** `STATUS_SUCCESS` (demo subset) or **`STATUS_NOT_IMPLEMENTED`**, registered in matrix; Phase G dedicated doc and host test checklist: [PHASE_G_WOW64.md](PHASE_G_WOW64.md) (coexists with this "Phase 4").
- **NTFS + ZOSH1**: on **`D:\`** volume provide **ZOSH1 load/export path constants** symmetrical with **`C:\`** (small files); full RegF still long-term.

### Phase4-Plus (Optional; not confused with Core)

- **VirGL / `CMD_SUBMIT_3D` non-empty payload**: self-authored command stream (do not copy Mesa source); user-mode submission boundary: [MM_Section_Roadmap.md](../cn/MM_Section_Roadmap.md).
- **GPU-assisted blur**: only when `tryVirglBlurBoxDelegation` etc. **truly returns true** does `dwm` reduce CPU box blur; otherwise keep `dwm_blur_budget` model.

## 6–8 Week Milestone Table (Suggested Order)

| Week | Deliverable | Verification |
|------|------------|--------------|
| 1 | `.gitignore` / `.cursorignore`; this doc + Roadmap + VirtioVirglMVP scope aligned | doc PR review |
| 1–2 | `force_gop_present` + `display_backend` strategy logging | QEMU serial + `zig build test` |
| 2–3 | `CompositorBackend` + `dwm` reads backend's blur strategy hook | host `dwm_blur_budget_host` non-regression |
| 3–5 | LPC `open_desktop` / `switch_desktop` / `close_desktop` + `port.zig` reply payload | `windowstation_lpc_host` |
| 4–6 | WOW64 DWM/user32 checklist + thunk/stub + matrix | new host tests |
| 5–8 | `hive.zig` NTFS `D:\` ZOSH1 path + boot load order | `ntfs_hive_minimum_host` extension |
| ongoing | [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) / [MVT_NT61.md](MVT_NT61.md) / [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md) | CI `zig build test` |

## Cross-References

- [../cn/VirtioVirglMVP.md](../cn/VirtioVirglMVP.md) — VirGL MVP and Phase4-Plus
- [SOFTWARE_COMPOSITOR_WDDM.md](../cn/SOFTWARE_COMPOSITOR_WDDM.md) — software composition and present backend
- [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) — LPC payload and versioning
- [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) — **single source of truth** for completion
- [PHASE_G_WOW64.md](PHASE_G_WOW64.md) — WOW64 testable subset and x86/x64 service number maintenance
