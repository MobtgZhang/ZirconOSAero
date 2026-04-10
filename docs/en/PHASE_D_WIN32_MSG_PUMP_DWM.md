# Phase D: Win32 Message Pump and DWM Message Docking — Detailed Checklist (Clean-room)

> **Naming note**: This "Phase D" is **message pump + DWM notification / LPC docking**; **≠** Phase D — Compositor in [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md). Compositor depth: see that file's D1–D5 and [AeroDesktopRuntime.md](AeroDesktopRuntime.md). **Phase naming cross-reference**: [cn/README.md](../cn/README.md) §Phase table.

**Knowledge sources**: Microsoft Learn / WDK public descriptions and Intel SDM whitelist only; syscall numbers from community public index, annotated in source comments; **no** internal draft path references as external authority.

**Compliance**: independent implementation; copying Windows/ReactOS/Wine source **prohibited**; API names and public constant values are ABI domain.

---

## D0 — Definition of Done and Current Audit

| ID | Task | Acceptance |
|----|------|-----------|
| D0.1 | Freeze Phase D "do / do-not": message queue consistency, `WM_DWM*` dispatch and listeners, `GetMessage`/`PeekMessage` known gaps vs. Learn kept retrievable (matrix §5 + this doc) | Contract matrix and `msg_pm_semantics.zig` comments synchronized |
| D0.2 | Explicit **do-not**: full hook chains, DDE, input method pipeline, bit-exact equivalence with commercial `user32` | Matrix §5.1 non-goals already covered → cross-reference only |
| D0.3 | Update [MVT_NT61.md](MVT_NT61.md): every Phase D testable item added must register command and module | PR gate |
| D0.4 | **Frozen definition**: Phase D "Done" = §D1–D3 main path in `zig build test` host steps + contract matrix §4–§5 three-state consistent; **does not** claim bit-exact commercial `user32` equivalence | This doc + matrix |
| D0.5 | **Constant single source**: conflicts between `nt61_aero_defaults.zig` / `zircon_aero_defaults.zig` / `dwm_nt61_api_contract.zig` → matrix [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4 footnote | `comptime` test + **dwm_messages_nt61_host** |

---

## D1 — Message Pump Kernel Semantics (`user32` / syscall)

| ID | Task | Main Path |
|----|------|-----------|
| D1.1 | **`NtUserGetMessage`**: multi-thread `blockThread` + `wakeOneMsgWaiter` vs. `PostMessage`/`PostThreadMessage` wake consistency audit; whether single-thread **`STATUS_PENDING`** strategy needs "configurable busy-wait upper bound" or documentation | `user32.zig` `getMessageAWithYield`, `ntUserGetMessageSyscall`; `syscall.zig` |
| D1.2 | **`NtUserPeekMessage` vs. Learn**: **in progress** — empty queue `STATUS_NO_MORE_ENTRIES` + zero `MSG*` (user-mapped FALSE; not `STATUS_PENDING`) | `ntUserPeekMessageSyscall`, `PeekMessageA` |
| D1.3 | **`PM_REMOVE` / `PM_NOYIELD`**: ensure `PeekMessage` path **does not** incorrectly share yield/block with `GetMessage`; `allowSchedulerYieldForPeekFlags` consistent with implementation (comments + host test) | `msg_pm_semantics.zig` |
| D1.4 | **min/max filtering**: `getMessageFiltered` rotating non-matching messages vs. Learn "discard/reorder" gap; add host test case or document boundary | `Window.getMessageFiltered` / `peekMessageFiltered` |
| D1.5 | **`WM_QUIT`**: delivery, cross-thread visibility, `GetMessage` returning `FALSE` (if via ntdll wrapper) | `user32` queue and syscall return convention |
| D1.6 | **`DispatchMessage` / `NtUserDispatchMessage`**: `WindowClass.wndproc_id` + `registerKernelWndProc` kernel table; user VA `WndProc` still on roadmap | [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §5, `user32.zig` |
| D1.7 | **Input routing**: `input_hub` → window hit → `PostMessage` order and foreground thread; consistent with [PointerPolicy_NT61.md](../cn/PointerPolicy_NT61.md) | `input_hub.zig`, `user32` |
| D1.8 | **`PostQuitMessage`**: **in progress** — only `PostThreadMessage(WM_QUIT)` to calling thread, aligned with Learn (no longer posts one per window in process) | `user32.zig` |

---

## D2 — csrss / LPC and Message Pump Authoritative Source

| ID | Task | Main Path |
|----|------|-----------|
| D2.1 | **`get_message`**: `csrFillOneMessageForLpc` and `peekMessageAForThread` **tid** from same source as `CreateWindowEx` `thread_id`; `tid==0` prohibited (`resolveGetMessageClientTid`) | `user32.zig`, `csr_lpc_policy.zig`, `subsystem.zig` |
| D2.2 | **`post_message` / reply payload**: consistent with `packMsgForLpc`, 44-byte `MSG` layout; version magic synchronized with [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) | `ipc`, `subsystem` |
| D2.3 | **GUI port ACL**: `seAccessActiveDesktopForWin32k` consistent with active desktop (placeholder to upgrade to real token check) | `se/token.zig`, matrix §4.1 |
| D2.4 | **`register_dwm_listener` (v1)**: payload `0x014D5744` + tid; kernel table and `csr_dwm_listeners` both ends consistent | `csr_dwm_listeners.zig`, `LPC_NT61_HANDSHAKE` |

---

## D3 — DWM Messages and Compositor Trigger Docking

| ID | Task | Main Path |
|----|------|-----------|
| D3.1 | **`WM_DWMCOMPOSITIONCHANGED` etc.**: `user32.broadcastDwm*` consistent with `dwm.zig` / `syncPolicyFromRegistry` trigger table | [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) |
| D3.2 | **Startup exemption**: no HWND → no `WM_DWM*` dispatch (noise control); re-dispatch registry diff after HWND exists | `dwm_config_registry_sync.zig`, `dwm_nt61_integration_host` |
| D3.3 | **Thumbnail / Live Preview**: `WM_DWMSENDICONICTHUMBNAIL`, `WM_DWMSENDICONICLIVEPREVIEWBITMAP` `lParam` packing and `thumb_refresh_min_ticks` throttle | `dwm_nt61_api_contract.zig`, `display`/`user32` |
| D3.4 | **`DwmRegisterThumbnail` pixel path**: `DWM_TNP_*` subset and `blitRegisteredDwmThumbnailsToFramebuffer` behavior; if already Partial in matrix §4.1 → add test only | `dwm_compositor.zig`, `display.zig` |
| D3.5 | **Listener thread queue**: priority when listener threads share message model with regular GUI threads (whether DWM notifications preempt) — documented policy | This doc + `DesktopManagerSpec` |

---

## D4 — Desktop Loop and Idle Policy (Coordinated with Compositor)

| ID | Task | Main Path |
|----|------|-----------|
| D4.1 | Reduce reliance on **`desktop_idle_spin`**: wake main loop when message or compositor dirty region exists. **In progress**: `runDesktopMainLoop` doc comment + append `input_hub` polling when `msgPumpThreadsBlockedApprox()`; `idle_streak` × `display_flip_journal.extraInputPollBudget` tail poll | [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) D5, `display.zig`, `main.zig` |
| D4.2 | IRQ / timer path binding with **Present hints**; avoid changing only spin or only compositor halfway | `AeroDesktopRuntime.md`, CI smoke |
| D4.3 | **`display_flip_journal`** and `notifyFramePresented` / idle coordination: per-frame flush count and `input_hub` tail poll budget from same source (see `display_flip_journal.zig` comments) | `display_flip_journal.zig`, `display.zig` |

---

## D5 — Tests and Matrix

| ID | Task | Acceptance |
|----|------|-----------|
| D5.1 | Extend existing host tests: **msg_pm_semantics**, **csr_lpc_policy**, **dwm_messages_nt61**, **dwm_nt61_integration** — one semantic → one assertion | `zig build test` |
| D5.2 | Optional QEMU: `scripts/qemu_desktop_perf_baseline.sh` step 5 — serial `grep -E 'WM_DWM|get_message|present|flip_journal'` | soft threshold, not hard CI |
| D5.3 | Update [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4–§5 rows: Partial/Done consistent with implementation | PR |
| D5.4 | **Soft performance threshold**: idle CPU usage or per-frame `memcpy` upper bound — documented in `DesktopManagerSpec` / this doc D4; exceeding does not fail CI | documentation |

---

## Maintenance

When updating this document, synchronize [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) Phase D index row and root `README_cn.md` if "message pump / DWM" external statements are affected.

**Acceptance boundary (A–F plan)**: items not marked **Done** in D1–D5 use this doc's tables + contract matrix §4–§5 as **frozen acceptance**; incremental implementation must add corresponding host test or matrix row. **WOW64** and x86 `NtConnectPort` / `NtRequestWaitReplyPort` demo path: [PHASE_G_WOW64.md](PHASE_G_WOW64.md).
