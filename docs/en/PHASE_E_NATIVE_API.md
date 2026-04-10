# Phase E: Native API Deep Completion (Acceptance Boundary)

> **Naming note**: This "Phase E" is **Native / ntdll / SSDT expansion** only; **≠** Phase E — Shell in [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md). **Phase naming cross-reference**: [cn/README.md](../cn/README.md) §Phase table.

Cross-references: [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) Phase K7 and [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md).

**Long-term items NOT delivered in this phase**: full `SYSTEM_INFORMATION_CLASS`, complete Ob namespace, production-grade ALPC, commercial `ntdll.dll` full equivalence.

**Phase E acceptance principle**: per **testable subset PR** unit; each new syscall must have description in [SSDT_Roadmap.md](../cn/SSDT_Roadmap.md) / [SyscallABI.md](../cn/SyscallABI.md); `zig build test` green (including `ssdt_stub_parity`, `nt61_full_api_backlog_anchors_host`).

---

## E0 — Definition of Done and Gates

| ID | Task | Acceptance |
|----|------|-----------|
| E0.1 | This doc + contract matrix §3 / §8 summary | Matrix and MVT linkable |
| E0.2 | New syscall: `ssdt_nt61` comment source; host/kernel tests | K7.1 |
| E0.3 | `tests/nt61_full_api_backlog_anchors_host.zig` real assertions per section | CI |

---

## E1 — Executive and Synchronization

| ID | Task |
|----|------|
| E1.1 | `NtAlertThread` / alertable with wait/APC consistent — **Partial**: `alert_pending` → `STATUS_ALERTED` (before `STATUS_USER_APC`) |
| E1.2 | `NtDelayExecution` absolute expiration — **Partial**: positive interval no monotonic conversion → immediate `SUCCESS` (see TimerPrecisionRoadmap) |
| E1.3 | Mutex/semaphore handle pool + `ObjectHeader` and `wait.zig` |
| E1.4 | `NtWaitForMultipleObjects`: `WaitAll` — **Partial**: scheduling-off cooperative; scheduling-on `STATUS_NOT_IMPLEMENTED` |

---

## E2 — Virtual Memory

| ID | Task |
|----|------|
| E2.1 | `NtLockVirtualMemory` / `NtUnlockVirtualMemory` stub or minimal implementation |
| E2.2 | `NtReadVirtualMemory` / `NtWriteVirtualMemory` cross-process probe / error codes |
| E2.3 | `NtProtectVirtualMemory` / `NtQueryVirtualMemory` with VAD/PTE audit (ongoing) |

---

## E3 — I/O and Devices

| ID | Task |
|----|------|
| E3.1 | `NtDeviceIoControlFile` subset routing (e.g. RTC IOCTL) |
| E3.2 | Named pipe / mail slot: `NtCreateNamedPipeFile` → `STATUS_NOT_IMPLEMENTED` (mail slot still on roadmap) |

---

## E4 — Objects and Namespace

| ID | Task |
|----|------|
| E4.1 | `NtOpenDirectoryObject` / `NtQueryDirectoryObject` subset |
| E4.2 | `NtDuplicateObject` / `NtQueryObject` parameters and access mask expansion |
| E4.3 | Symbolic link resolution and Ob open path unification (ongoing) |

---

## E5 — Process and Thread

| ID | Task |
|----|------|
| E5.1 | `NtCreateProcess` / `NtCreateProcessEx` distinction; user creation path: [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) |
| E5.2 | `NtQuery/SetInformationProcess` unimplemented classes explicit return codes |
| E5.3 | `NtQueryInformationThread` / `NtSuspendThread` / `NtResumeThread` / `NtOpenProcess` — **Suspend/Resume** still count stubs (honest matrix item) |

---

## E6 — Security

| ID | Task |
|----|------|
| E6.1 | `NtOpenProcessToken` / `NtQueryInformationToken` info class expansion |
| E6.2 | `SeAccessCheck` and handle `DesiredAccess` documented |

---

## E7 — LPC

| ID | Task |
|----|------|
| E7.1 | `NtReplyWaitReceivePort` family consistent with `port.zig` / subsystem behavior |
| E7.2 | Large message / Section view: design + stub |

---

## E8 — Registry

| ID | Task |
|----|------|
| E8.1 | `NtOpenKeyEx`, transaction API: Stub or subset |
| E8.2 | Hive persistence and `registry/` roadmap (see NT61_KERNEL_TODO K7.3) |

---

## E9 — System Information

| ID | Task |
|----|------|
| E9.1 | `NtQuerySystemInformation` multi-class, `ReturnLength` |
| E9.2 | `NtSetSystemInformation` allowed range + not-implemented return codes |

---

## E10 — PE / WOW64

| ID | Task |
|----|------|
| E10.1 | PE delay-load / binding consistent with loader milestone |
| E10.2 | WOW64 x86 SSDT vs. x64 namespace correspondence — **in progress**: [`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig), [PHASE_G_WOW64.md](PHASE_G_WOW64.md), **wow64_x64_semantic_alias_host** |

---

## E11 — Win32k Folded Slots

| ID | Task |
|----|------|
| E11.1 | `NtUser*` folding strategy synchronized with `ssdt_nt61` / SyscallABI |

---

## Maintenance Notes

- **E2.3**: `NtProtectVirtualMemory` / `NtQueryVirtualMemory` VAD/PTE ongoing audit: [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md), contract matrix §3.
- **E4.2 / E4.3**: `NtDuplicateObject` / `NtQueryObject` and `se/token` access mask, `normalizeNtObjectPathResolveSymlinks` and Ob open path: anchored to [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §3 and `zircon_host_ob_test`.
- **E6–E8 / E10–E11**: info class expansion, ALPC large messages, hive, PE delay-load, WOW64 folded slots: use this doc's sections + `[NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md)` K7 as rolling checklist; WOW64 dual-track and dual-table maintenance: [PHASE_G_WOW64.md](PHASE_G_WOW64.md).
