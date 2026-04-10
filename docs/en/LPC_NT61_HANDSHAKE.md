# LPC and Win32 Subsystem Handshake ABI (NT 6.1 Target)

> Describes **clean-room** conventions between LPC ports in ZirconOSAero kernel and user-mode **csrss / Win32**. Behaviors aligned with Microsoft public documentation on **ports, connections, and messages**. Does **not** reference Windows/ReactOS source.

**Phased milestones**: cross-referenced with [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9.2 **csrss-style subsystem and LPC milestones**. This document focuses on handshake fields and `PortKind`, not full csrss protocol completion.

## Naming and Port Types

- **Server port**: created by `NtCreatePort`, held by service process; name passed via `OBJECT_ATTRIBUTES` / `UNICODE_STRING` (see [`src/lpc/port.zig`](../../src/lpc/port.zig)).
- **Client connection**: `NtConnectPort` looks up registered port by name and establishes client-side handle.
- **Request-reply**: `NtRequestWaitReplyPort` (roadmap expansion) must be consistent with **single message boundary** and timeout semantics; currently unimplemented path returns `STATUS_NOT_IMPLEMENTED` at syscall layer.

## vNext: Desktop Handle and Switching (Phase 4, `CsrApiNumber` 0x10028–0x1002A)

Fixed header **`0x44534B31`** (little-endian four bytes, "DSK1") at `data[0..4]` distinguishes from non-versioned payloads.

| Opcode | Name | Request `data` layout | Reply |
|--------|------|---------------------|-------|
| `0x10028` | `open_desktop` | `0..4`: magic `DSK1`; `4`: `name_len` (u8); `5..5+name_len`: UTF-8 name | `data[0..4]` = `i32` status (0 = success); on success `data[4..8]` = **1-based** `HDESK` (u32 LE) |
| `0x10029` | `switch_desktop` | same name layout (magic `DSK1`) | `data[0..4]` = `i32` (0 = success, -1 = not found) |
| `0x1002A` | `close_desktop` | `0..4`: magic **`0x44534C31`** ("DSL1"); `4..8` = 1-based `HDESK` (u32 LE) | `data[0..4]` = `i32` (0 = success, -1 = failure) |

**Security**: `subsystem.handleApiCall` still checks active desktop before delegation (consistent with existing `register_window`).

## `register_dwm_listener` (`CsrApiNumber` 0x10027)

- **Old payload** (still supported): `data[0..4]` little-endian DWORD thread id; when `tid==0`, csrss side falls back to client `pid` via `csr_lpc_policy.resolveDwmListenerTid`.
- **v1 payload** (recommended): `data[0..4]` = magic `0x014D5744` (little-endian, "DWM`0x01`"); `data[4..8]` = thread id (little-endian). Distinguished from old version; avoids `tid==1` vs. version byte conflict.
- Listener table held by [`csr_dwm_listeners.zig`](../../src/subsystems/win32/csr_dwm_listeners.zig); `user32.broadcastDwm*` calls `PostThreadMessage` to table threads.

## Field Handshake with Subsystem (csrss)

- Fields on port objects related to large messages / section views (e.g. `section_view_handle`) are **placeholders**; after mapping with [`src/mm/section.zig`](../../src/mm/section.zig), must synchronize **view token or base address encoding** rules in this document and [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md).
- **Byte order and alignment**: message buffers use **little-endian**, natural alignment; when fixed header length changes, increment **handshake version constant** (`Port.handshake_version` in `src/lpc/port.zig`; currently **`2`** — marks large message/timeout field evolution and csrss single-source progression; small message layout remains v1-compatible). Host anchor: **lpc_handshake_version_host**.
- **csrss synchronous reply**: when `opcode` is in `0x10000..0x1FFFF` (`CsrApiNumber`) and `port.setCsrRequestHandler` is registered, `NtRequestWaitReplyPort` constructs `ipc.Message` reply directly in same kernel model (no async service thread needed).
- **Section views and large messages**: binding rules for `Port.section_view_handle` and `NtMapViewOfSection` return tokens: follow [MM_Section_Roadmap.md](../cn/MM_Section_Roadmap.md); **current limit**: single LPC kernel message body is fixed **`ipc.MSG_DATA_SIZE` (64)** bytes; larger payloads require section view cooperation or explicit `STATUS_NOT_IMPLEMENTED` return.
- **Call chain**: see [LPC_NT61_CALL_CHAIN.md](LPC_NT61_CALL_CHAIN.md) (`NtCreatePort` / `NtConnectPort` / `NtRequestWaitReplyPort` and `owner_pid`).
- **csrss GUI small message layout**: `post_message` / `get_message` fixed field offsets consistent with `subsystem.handleApiCall`; host **`csr_lpc_policy_host`** and **`win32k_api_semantics_host`** synchronized with `post_message_*_off` / `get_message_*_off` in [`src/subsystems/win32/csr_lpc_policy.zig`](../../src/subsystems/win32/csr_lpc_policy.zig).

## Verification

- Connection/create path: see [MVT_NT61.md](MVT_NT61.md) for CI and user-mode test cases.
- `PortKind` enum underlying values (`message = 0`, `connection_listener = 1`) fixed by host test **lpc_portkind_host**; modifying `src/lpc/port.zig` requires updating [`tests/lpc_portkind_host.zig`](../../tests/lpc_portkind_host.zig).
- Regression: changes to `NtCreatePort` / `NtConnectPort` must keep `zig build test` and existing syscall dispatch probes (user pointer `probe`) non-regressing.
