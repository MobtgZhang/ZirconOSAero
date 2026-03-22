# ZirconOS architecture

## 1. Design position

**ZirconOS = NT-style hybrid microkernel + user-mode subsystems + Zig**

Core ideas:

- **Microkernel + user-mode services**: keep the kernel small; policy lives in user-mode servers/subsystems
- **NT-style model**: objects / handles / namespaces / service-oriented design
- **Zig**: compile-time power and no libc dependency for a controlled boundary
- **Phased compatibility**: Native + ELF → PE → Win32 subsystem → WOW64

## 2. Layered model

```
┌──────────────────────────────────────────────┐
│                Applications                   │
│       Win32 Apps  ·  POSIX Apps  ·  Native    │
├──────────────────────────────────────────────┤
│              Subsystems (user mode)           │
│     Win32  ·  POSIX  ·  WOW64  ·  Native     │
├──────────────────────────────────────────────┤
│           System Services (user mode)          │
│  Process Server · Object Manager · I/O Mgr    │
│  Security  ·  Session Manager  ·  Loader      │
├──────────────────────────────────────────────┤
│            Microkernel (kernel mode)           │
│  Scheduler · IPC · VM · Syscall · Interrupt   │
├──────────────────────────────────────────────┤
│          HAL - Hardware Abstraction           │
│  CPU · APIC · IO Ports · Timer · GDT · IDT   │
├──────────────────────────────────────────────┤
│               Hardware                        │
└──────────────────────────────────────────────┘
```

### 2.1 Kernel mode

#### Microkernel core

The kernel provides only **mechanisms**, not policy:

| Area | Role |
|------|------|
| Scheduling | Threads, priorities, time slices (round-robin) |
| Virtual memory | Address spaces, map/unmap, protection |
| IPC | LPC ports, synchronous request/reply, message queues |
| Interrupts/exceptions | IDT dispatch, IRQ handling, fault delivery |
| System calls | `int 0x80` dispatch, stable ABI |
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

User-mode components that talk to the kernel over LPC/IPC:

| Service | Role |
|---------|------|
| Process Server (PID 1) | Process/thread lifecycle |
| Session Manager (SMSS, PID 2) | Sessions, subsystem registration/startup |
| Object Server | Namespace policy (planned split) |
| I/O Server | Devices and filesystem policy (planned split) |
| Security Server | ACL/policy (planned split) |
| Loader | ELF/PE mapping, relocations, imports |

#### Subsystems

Application compatibility surfaces:

| Subsystem | Notes |
|-----------|-------|
| Native | ZirconOS native API |
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

Implemented types include:

| Type | Description |
|------|---------------|
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

NT-style object namespace tree:

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

IPC is foundational in a microkernel.

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
