# ZirconOSAero system services

**As-built:** Only **Process Server** (PID 1) and **SMSS** (PID 2) are **separate user-mode processes** talking to the kernel over LPC. **Object / I/O / Security** policy is still **inside the kernel** (`src/ob/`, `src/io/`, `src/se/`); standalone “ObServer / IoServer / …” processes are **not** shipped yet. This page documents **both** what runs today and **planned** splits.

**LPC user-mode split contract (draft)**：[docs/cn/LPC_USER_SERVERS_CONTRACT.md](../cn/LPC_USER_SERVERS_CONTRACT.md) (message boundaries when policy moves out of the kernel).

## 1. Service architecture

```
┌──────────────────────────────────────────────────┐
│                  Applications                     │
├──────────────────────────────────────────────────┤
│ Subsystems (Win32 / POSIX planned / WOW64 / …)   │
├──────────────────────────────────────────────────┤
│ User-mode service processes (implemented today)   │
│   ┌────────────┐      ┌────────────┐             │
│   │ PsServer   │      │   SMSS     │             │
│   │   PID 1    │      │   PID 2    │             │
│   └─────┬──────┘      └─────┬──────┘             │
│         └─────────┬─────────┘                    │
│                   │ LPC/IPC                       │
├───────────────────┼──────────────────────────────┤
│ Kernel — microkernel + Executive (OB / IO / SE /   │
│ MM / PS / loader / VFS …)                         │
└──────────────────────────────────────────────────┘
```

**Planned (not drawn as boxes above):** user-mode **Object / I/O / Security** servers and tighter loader boundaries — §3.

## 2. Implemented services

### 2.1 Process Server (PID 1)

- **Source**: `src/servers/server.zig`
- **LPC port**: `\LPC\PsServer`
- **Role**: Process/thread management over LPC (**subset** of a real PS; parity and coverage — [NT61_CONTRACT_MATRIX.md](../cn/NT61_CONTRACT_MATRIX.md), `server.zig`)

| Operation | Description |
|-----------|-------------|
| Create process | PID, address space, handle table, token |
| Create thread | TID, kernel stack, user stack |
| Terminate process | Tear down handles and memory |
| Query | Process/thread lists and state |
| Suspend/resume | **Partial** — verify against `server.zig` / tests before assuming NT parity |

### 2.2 Session Manager — SMSS (PID 2)

- **Source**: `src/servers/smss.zig`
- **LPC port**: `\LPC\SmssServer`
- **Role**: Sessions and subsystem bring-up

| Operation | Description |
|-----------|-------------|
| Sessions | Create and manage user sessions |
| Subsystem registration | Register Native/Win32/POSIX subsystems |
| Subsystem startup | Start subsystem servers in dependency order |
| Coordination | Coordinate service lifetimes |

## 3. Planned services

These are still embedded in the kernel or simplified; the plan is to migrate them to standalone processes:

| Service | Planned path | Role | Current state |
|---------|--------------|------|----------------|
| Object Server (obsvr) | `servers/obsvr/` | Namespace policy, directories/symlinks | In kernel (`src/ob/`) |
| I/O Server (iosvr) | `servers/iosvr/` | Device namespace, VFS policy, driver load | In kernel (`src/io/`) |
| Security Server (secsvr) | `servers/secsvr/` | Token/ACL policy | In kernel (`src/se/`) |
| Loader (ldsvr) | `servers/ldsvr/` | ELF/PE mapping, relocations, imports | In kernel (`src/loader/`) |

## 4. LPC ports

Names below include **future** split targets. **As-built**, only rows marked **User process** are backed by a standalone server binary; others may be **kernel-side registrations**, stubs, or roadmap — confirm in `src/` before tooling or AI assumes a process exists.

| Port | Logical owner | Use | As-built |
|------|---------------|-----|----------|
| `\LPC\PsServer` | Process Server | Process/thread RPCs | **User process** (PID 1) |
| `\LPC\SmssServer` | Session Manager | Session/subsystem | **User process** (PID 2) |
| `\LPC\ObServer` | Object Manager | Object/namespace ops | **Kernel / placeholder** until §3 split |
| `\LPC\IoServer` | I/O Manager | Device and I/O | **Kernel / placeholder** until §3 split |
| `\LPC\NativeSubsys` | Native subsystem | Native API | **Verify** (`subsystem` / kernel paths) |
| `\LPC\Win32Subsys` | Win32 subsystem | Win32 API | **Verify** (`subsystem.zig` / csrss-style) |

## 5. Message format

```
Message {
    sender:   u32
    receiver: u32
    opcode:   u32
    data:     [64]u8
}
```

### Patterns

| Operation | Role |
|-----------|------|
| CreatePort | Server creates a named port |
| ConnectPort | Client connects |
| RequestWaitReply | Client sends and waits |
| Reply | Server responds |
| Listen | Server accepts connections |

## 6. Boot order (Phase 5)

High-level intent from the roadmap; **exact ordering and which port names exist in-kernel vs user-mode** can differ by build — read `main.zig` / server bring-up.

```
Phase 5 (conceptual)
  1. Register / create LPC ports needed for bring-up (Ps + SMSS at minimum; Ob/Io names may be kernel-side)
  2. Start Process Server (PID 1)
  3. Start Session Manager / SMSS (PID 2)
  4. SMSS drives subsystem startup chain
Phase 5 end
```
