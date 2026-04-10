# NT 6.1 Full Native / Win32 API Capability Backlog (Separated from Core Iterations)

> **Status labels**: see [DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND.
> **Authority for current delivery**: [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) K0–K8 and [MVT_NT61.md](MVT_NT61.md). This backlog **does not** indicate implementation.
> **Contract matrix / API skeleton division of labor**: [DOCS_INDEX.md](../DOCS_INDEX.md) §维护约定.
> **PR gates**: `zig build test` → **nt61_full_api_backlog_anchors_host** (at least one real assertion per section, sourced from `ssdt_nt61` / constants).

**Copyright**: MSDN / WDK / hardware + VirtIO public specs only; no Windows/ReactOS/Wine source.

## 1. Executive and Synchronization (Ke / Nt*)

- `NtAlertThread`, `NtDelayExecution`, `NtSuspendThread`, `NtResumeThread`, etc. (`NtDelayExecution`: kernel wired to SSDT 0x31, negative interval approximated with `yield`; precise timing: [TimerPrecisionRoadmap.md](../cn/TimerPrecisionRoadmap.md)).
- Full semantics for mutexes, semaphores, timers, multi-object waits; IRQL documented behavior.

## 2. Virtual Memory (Mm / Nt*)

- `NtProtectVirtualMemory`, `NtLockVirtualMemory`, `NtReadVirtualMemory` / `NtWriteVirtualMemory` (cross-process), AWE.

## 3. I/O and Devices (Io / Nt*)

- `NtDeviceIoControlFile`, `FsRtl`/`Cc` cache semantics extension.
- Named pipes, mail slots, I/O completion ports (IOCP) subset.

## 4. Objects and Namespace (Ob)

- Full directory objects, symbolic link resolution, `NtOpen*` family and handle attribute flag matrix.

## 5. Process and Thread (Ps)

- `NtCreateProcessEx`, job objects, debug objects, full PEB/TEB and WOW64 context.

## 6. Security (Se)

- Full ACL/SACL parsing, `SeAccessCheck` and audit policy; impersonation token level matrix.

## 7. LPC / ALPC

- Full `NtReplyWaitReceivePort` family, production path for large messages and section view binding.

## 8. Registry (Cm / Nt*)

- `NtOpenKeyEx`, `NtEnumerateKey`, `NtSetValueKey`, etc. for hive persistence and transactions (per NT 6.1 documentation boundary).

## 9. System Information and Debugging (Nt* / Kd)

- `NtQuerySystemInformation` / `NtSetSystemInformation` — full `SYSTEM_INFORMATION_CLASS` prioritized landing.
- Kernel debugging and profiling APIs.

## 10. User-Mode Binary Compatibility (Loader / PE)

- PE export table, import binding, delay-load; ABI alignment with real `ntdll.dll` binaries is a separate milestone (see [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) Win32 boundary note).

## Implementation Checkpoints

- **Phase 0–1 (gates + ABI)**: `bash scripts/verify-compliance.sh`; `zig build test` includes **nt61_abi_layout_host**; `KUSER_SHARED_DATA` mapping and `TEB` offsets: `src/mm/kuser_shared.zig`, `src/sdk/teb_nt61_x64.zig`.
- **Phase 5–7 (Native expansion)**: expand `Nt*` / registry / LPC per section in PRs, synchronize [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) and `tests/`.
- **Phase 8 (win32k)**: `src/subsystems/win32k/` + [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md).

## 11. NtUser* / win32k SSDT Waves (x64 Win7 SP1 Public Indices)

Source: **public syscall enumeration** (e.g. j00ru `windows-syscalls`); implementation must be clean-room; only names and numbers aligned.

| Wave | Services (examples) | Public index (SP1 x64) | Status |
|------|---------------------|------------------------|--------|
| W5-A (wired) | `NtUserGetMessage` | `0x58` | **SSDT wired + subset semantics** |
| W5-A | `NtUserPeekMessage` | `0x59` | same as above |
| W5-B (next batch) | `NtUserPostMessage` / `NtUserSendMessage` / `NtUserSetWindowPos` etc. | see table | Planned |
| WOW64 | Same names, x86 table entries + x64 semantic aliases | `wow64/ssdt_x86_win7_sp1.zig`, `wow64/x64_semantic_alias.zig`; [PHASE_G_WOW64.md](PHASE_G_WOW64.md) | Partial |

Detailed message/API ↔ test ID mapping: [NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md).

## Maintenance

Add new entries as section or table rows appended to this file; **contract matrix** §3 / §8 only link to summaries, avoid drifting from `src/` implementation state.
