# ZirconOSAero architecture

## 1. Design position

**ZirconOSAero = NT 6.1–target hybrid microkernel + user-mode subsystems + Zig**

Core ideas:

- **Hybrid microkernel + in-kernel Executive (as-built)**: mechanisms (scheduling, VM, IPC, syscalls) **and** NT-style managers (**Object, MM, PS, IO, Security**, loaders) run **in kernel** today; only **Process Server** and **SMSS** are separate user-mode services. Further user-mode splits are **roadmap** — [Servers.md](Servers.md), [LPC_USER_SERVERS_CONTRACT.md](../cn/LPC_USER_SERVERS_CONTRACT.md).
- **NT-style model**: objects / handles / namespaces / service-oriented design
- **Zig**: compile-time power and no libc dependency for a controlled boundary
- **Phased compatibility**: Native + ELF → PE → Win32 subsystem → WOW64

## 2. Layered model

**As-built vs diagram traps:** Older docs drew **Object Manager / I/O Manager / Security / Loader** in a “user-mode services” band. In **this** tree they are **kernel Executive** code (`src/ob/`, `src/io/`, `src/se/`, `src/loader/`, …). The figure below matches **current layout**; §2.2 lists **planned** user-mode splits.

### 2.0 As-built (matches `src/` today)

```
┌──────────────────────────────────────────────┐
│                Applications                   │
│       Win32 Apps  ·  POSIX (planned) · Native │
├──────────────────────────────────────────────┤
│        Subsystems (user mode, partial)        │
│     Win32  ·  WOW64  ·  Native (ntdll, …)    │
├──────────────────────────────────────────────┤
│     User-mode services (only these today)     │
│     Process Server (PID 1) · SMSS (PID 2)    │
├──────────────────────────────────────────────┤
│                  Kernel                       │
│  Microkernel: Sched · VM · LPC · Syscall ·   │
│               Interrupts / sync / timers      │
│  Executive:   OB · MM · PS · IO · Security    │
│               FS/VFS · Loader (PE/ELF)        │
├──────────────────────────────────────────────┤
│          HAL (CPU, APIC/PIC, timers, …)       │
├──────────────────────────────────────────────┤
│               Hardware                        │
└──────────────────────────────────────────────┘
```

### 2.0.1 Planned user-mode policy split (not current)

Independent **Object / I/O / Security** server processes (and tighter loader service boundaries) are **design targets** only; see [Servers.md](Servers.md) §3 and [LPC_USER_SERVERS_CONTRACT.md](../cn/LPC_USER_SERVERS_CONTRACT.md).

### 2.1 Kernel mode

#### Microkernel core

The kernel provides only **mechanisms**, not policy:

| Area | Role |
|------|------|
| Scheduling | Threads, multi-level priorities, timer preempt (`ke/scheduler.zig`; see [SCHEDULER_API.md](../cn/SCHEDULER_API.md)) |
| Virtual memory | Address spaces, map/unmap, protection |
| IPC | LPC ports, synchronous request/reply, message queues |
| Interrupts/exceptions | IDT dispatch, IRQ handling, fault delivery |
| System calls | x86_64: `syscall`/`sysret` + SSDT subset ([SyscallABI.md](../cn/SyscallABI.md)) |
| Handle primitives | Duplicate, close, cross-process transfer |

#### Executive core

Inspired by the NT Executive, key managers remain in kernel mode:

| Module | Path | Role |
|--------|------|------|
| Object Manager | `src/ob/` | Object types, namespace, handle tables |
| Memory Manager | `src/mm/` | Physical frames, virtual memory, heap |
| Process Manager | `src/ps/` | Process/thread objects |
| I/O Manager | `src/io/` | Devices, drivers, IRP framework |
| Security | `src/se/` | Tokens, SIDs, access checks |

#### HAL (hardware abstraction layer)

| Area | Notes |
|------|-------|
| CPU | Segments, TSS, control registers |
| APIC / PIC | Interrupt controllers |
| PIT | Programmable interval timer |
| I/O ports | Port I/O |
| Serial | COM1 logging |
| VGA | Text mode |
| Framebuffer | Graphics |

### 2.2 User mode

#### System services

| Service | Role | As-built |
|---------|------|----------|
| Process Server (PID 1) | Process/thread lifecycle RPCs | **User mode** — `src/servers/server.zig` |
| Session Manager (SMSS, PID 2) | Sessions, subsystem registration/startup | **User mode** — `src/servers/smss.zig` |
| Object / I/O / Security “servers” | Policy split like NT usermode services | **Not separate processes** — logic in kernel `src/ob/`, `src/io/`, `src/se/` |
| Loader service | PE/ELF mapping, relocations, imports | **Kernel** `src/loader/` today; user-mode split **planned** |

LPC port names for future splits are documented in [Servers.md](Servers.md); many are **contract placeholders** until processes exist.

#### Subsystems

Application compatibility surfaces:

| Subsystem | Notes |
|-----------|-------|
| Native | ZirconOSAero native API subset |
| Win32 | kernel32 / user32 / gdi32 / ntdll subset |
| POSIX | libc/POSIX mapping (planned) |
| WOW64 | 32-bit PE thunking + ABI glue |

## 3. Object model

The object model is central to the NT-style design: kernel resources are uniformly object-oriented.

### 3.1 Object header

Each kernel object carries a common header:

```
ObjectHeader {
    type_index     object type index
    ref_count      reference count
    handle_count   handle count
    name           optional name
    flags          object flags
}
```

### 3.2 Object types

These are **in-tree object kinds** registered with the Object Manager — **not** a claim that each type has Windows-complete semantics, syscall coverage, or tests. Many are **Partial**; see [`object.zig`](../../src/ob/object.zig) and [NT61_CONTRACT_MATRIX.md](../cn/NT61_CONTRACT_MATRIX.md).

| Type | Description |
|------|-------------|
| Process | Process object |
| Thread | Thread object |
| Token | Security token |
| Event | Event synchronization |
| Mutex | Mutex |
| Semaphore | Semaphore |
| Port | LPC port |
| File | File object |
| Device | Device object |
| Driver | Driver object |
| Directory | Namespace directory |
| SymbolicLink | Symlink |
| Section | Memory-mapped section |

### 3.3 Handle table

Each process has its own handle table; handles do not expose raw kernel pointers:

- `ObCreateObject` — create object  
- `ObReferenceObject` — take a reference  
- `ObOpenObjectByName` — open by name  
- `ObInsertHandle` — insert handle  
- `ObCloseHandle` — close handle  

### 3.4 Namespace

Logical NT-style namespace sketch — **not** every branch is fully walkable or backed by the same depth as Windows. **`LPC\ObServer` / `IoServer` names do not imply** standalone user-mode processes today ([Servers.md](Servers.md)).

```
\
├── ObjectTypes/
├── Devices/
├── Sessions/
├── KnownDlls/
├── BaseNamedObjects/
└── LPC/
    ├── PsServer
    ├── ObServer
    ├── IoServer
    ├── SmssServer
    ├── NativeSubsys
    └── Win32Subsys
```

## 4. IPC design

IPC is foundational; **this codebase is a hybrid** — large policy pieces still run in-kernel alongside LPC.

### 4.1 Kernel primitives

- Message queues  
- Synchronous request/reply  
- Shared memory sections  
- Event notification  

### 4.2 LPC port layer

NT LPC–style operations:

| Operation | Role |
|-----------|------|
| CreatePort | Create a named port |
| ConnectPort | Client connects |
| RequestWaitReply | Send and wait for reply |
| Reply | Server replies |
| Listen | Listen for connections |

Message layout: 64-byte payload with sender, receiver, opcode, and data.

## 5. Security model

An NT-style security framework is reserved; the current code is simplified:

| Concept | Role |
|---------|------|
| Token | Security token attached to processes |
| SID | Security identifier |
| Access mask | Permission bits |
| ACL | Access control (simplified) |

Access checks run on object open so handles, isolation, and service permissions have a coherent base.

## 6. Design principles

| Principle | Meaning |
|-----------|---------|
| Mechanisms first, policy later | Get scheduling/VM/IPC right; move policy to services |
| Interfaces first | Define RPC/syscall/object interfaces before filling implementations |
| Observability | Keep serial/logging paths for debugging |
| Incremental compatibility | PE/Win32/WOW64 in stages |
| Replaceable implementations | Services can be restarted/replaced; crash isolation matters |

## 7. Non-goals

To keep scope manageable:

- **Not a full NT reimplementation** — no bit-for-bit ABI match  
- **No Win32 in the kernel** — windowing/GDI live in the subsystem  
- **Not targeting large apps first** — boot, process creation, IPC, minimal userland first  
- **No full Windows driver compatibility**  
- **No full GDI/DirectX/SMP tuning in v1.0**  
