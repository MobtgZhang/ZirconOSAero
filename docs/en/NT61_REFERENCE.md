# NT 6.1 Technical Documentation (English Entry Point)

> **Status labels** and **document ownership**: [DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND and §维护约定.
> **Phase naming cross-reference**: see table below.

This is the **English entry point** for NT 6.1 technical documentation. The repository maintains many deep NT 6.1 specs in **both English and Chinese**. If a document is not yet available in English, the Chinese version in [`docs/cn/`](../cn/) is authoritative.

## Phase Numbering (Do Not Conflate)

| Name | Where | Meaning |
|------|-------|---------|
| **Kernel init Phase 0–12** | [Boot.md](Boot.md), `src/main.zig` | Ordered bring-up steps inside the kernel |
| **Roadmap Phase 0–11** | [Roadmap.md](Roadmap.md), root `README.md` | Milestone **scope** headings — **not** "everything done" |
| **Phases D–G**, **desktop Phase 4** | tables below | Separate trackers; **not** the same indices as 0–11 |

## Core Trio (Chinese authoritative; English equivalents exist)

| Topic | Chinese (primary) | English (parallel) |
|-------|------------------|-------------------|
| Contract / status matrix | [cn/NT61_CONTRACT_MATRIX.md](../cn/NT61_CONTRACT_MATRIX.md) | [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) |
| Verification steps | [cn/MVT_NT61.md](../cn/MVT_NT61.md) | [MVT_NT61.md](MVT_NT61.md) |
| Kernel backlog K0–K8 | [cn/NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) | — (Chinese only) |

## NT 6.1 Technical Reference

### Contract, Verification, and Kernel Backlog

| Document | Description |
|----------|-------------|
| [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) | Subsystem promise boundary and status matrix (Done/Partial/Stub/Planned/Verified) |
| [MVT_NT61.md](MVT_NT61.md) | Reproducible verification steps and `zig build test` mapping |
| [IMPLEMENTATION_STATUS_NT61.md](IMPLEMENTATION_STATUS_NT61.md) | Honest narrative of current focus areas |
| [NT61_PR_GATES.md](NT61_PR_GATES.md) | PR merge checklist (K0) |
| [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) | Long-term full NT API surface (not current delivery) |
| [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) | Deferred surfaces not blocking MM/SMP/isolation milestones |

### Graphics, Desktop, DWM, Win32k

| Document | Description |
|----------|-------------|
| [NT61_GRAPHICS_SCAFFOLD.md](NT61_GRAPHICS_SCAFFOLD.md) | Graphics and Win32k scaffold (Phase B/C/D/F) |
| [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) | DWM notification delivery model vs. csrss/LPC |
| [AeroDesktopRuntime.md](AeroDesktopRuntime.md) | Aero desktop runtime architecture and input debugging |
| [DesktopManagerSpec.md](DesktopManagerSpec.md) | Desktop manager overall spec (Session/WinSta/Desktop/DWM) |
| [NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md) | Window message / user32 contract trace table |

### Phases D–G and Phase 4 (hardware integration)

| Document | Phase scope |
|----------|------------|
| [PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md) | Phase D: Win32 message pump + DWM/LPC docking |
| [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) | Phase E: Native API deep completion |
| [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) | Phase F: `NtCreateUserProcess` / user process creation |
| [PHASE_G_WOW64.md](PHASE_G_WOW64.md) | Phase G: WOW64 / SysWOW64 behavioral subset |
| [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) | Phase 4: hardware acceleration and system integration |

### LPC and IPC

| Document | Description |
|----------|-------------|
| [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) | LPC and Win32 subsystem handshake ABI |
| [LPC_NT61_CALL_CHAIN.md](LPC_NT61_CALL_CHAIN.md) | `Nt*Port` kernel call chain and `owner_pid` flow |
| [LPC_USER_SERVERS_CONTRACT.md](LPC_USER_SERVERS_CONTRACT.md) | LPC and user-mode service split contract draft |
| [LPC_LARGE_MESSAGE.md](LPC_LARGE_MESSAGE.md) | LPC large messages and `MSG_DATA_SIZE` boundary |

### Memory Management

| Document | Description |
|----------|-------------|
| [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) | NT 6.1 VM and display-related ABI correspondence |
| [MemoryManagement_NT61_LoongArch64_NewWorld.md](MemoryManagement_NT61_LoongArch64_NewWorld.md) | LoongArch64 "New World" memory management spec |

### Shell and Assets

| Document | Description |
|----------|-------------|
| [NT61_ShellIcons.md](NT61_ShellIcons.md) | Shell icons and ZirconOS resource DLL strategy |
| [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) | Unfinished items rolling checklist (vs. implementation status) |

### Syscall and SSDT

| Document | Description |
|----------|-------------|
| [cn/SyscallABI.md](../cn/SyscallABI.md) | x86_64 syscall ABI (Chinese; primary) |
| [cn/SSDT_Roadmap.md](../cn/SSDT_Roadmap.md) | SSDT roadmap (Chinese; primary) |

## Full Classified Index

For all documents (EN + CN + specs), see: [DOCS_INDEX.md](../DOCS_INDEX.md).

## Key Maintenance Links

| Document | Purpose |
|----------|---------|
| [DOCS_INDEX.md](../DOCS_INDEX.md) | Classified list + status legend + maintenance rules |
| [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) | Toolchain and reproducible build checklist |
| [COPYRIGHT_AND_SOURCES.md](COPYRIGHT_AND_SOURCES.md) | Copyright boundaries and allowed knowledge sources |
