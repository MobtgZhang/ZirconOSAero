# ZirconOS system services

System services run in user mode and talk to the microkernel over LPC/IPC. They implement policy and higher-level management.

## 1. Service architecture

```
┌──────────────────────────────────────────────────┐
│                  Applications                     │
├──────────────────────────────────────────────────┤
│ Subsystems (Win32 / POSIX / WOW64 / Native)      │
├──────────────────────────────────────────────────┤
│          System Services (this document)          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ PsServer │  │  SMSS    │  │ ObServer │  ...   │
│  │  PID 1   │  │  PID 2   │  │          │        │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘        │
│        │              │              │             │
│        └──────────────┼──────────────┘             │
│                       │ LPC/IPC                    │
├───────────────────────┼──────────────────────────┤
│                  Microkernel                       │
└──────────────────────────────────────────────────┘
```

## 2. Implemented services

### 2.1 Process Server (PID 1)

- **Source**: `src/servers/server.zig`
- **LPC port**: `\LPC\PsServer`
- **Role**: Full lifecycle for processes and threads

| Operation | Description |
|-----------|-------------|
| Create process | PID, address space, handle table, token |
| Create thread | TID, kernel stack, user stack |
| Terminate process | Tear down handles and memory |
| Query | Process/thread lists and state |
| Suspend/resume | Pause and resume threads |

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

Ports registered after boot:

| Port | Owner | Use |
|------|-------|-----|
| `\LPC\PsServer` | Process Server | Process/thread RPCs |
| `\LPC\ObServer` | Object Manager | Object/namespace ops |
| `\LPC\IoServer` | I/O Manager | Device and I/O |
| `\LPC\SmssServer` | Session Manager | Session/subsystem |
| `\LPC\NativeSubsys` | Native subsystem | Native API |
| `\LPC\Win32Subsys` | Win32 subsystem | Win32 API |

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

```
Phase 5 start
  1. Create LPC ports (\LPC\PsServer, \LPC\ObServer, \LPC\IoServer)
  2. Start Process Server (PID 1)
  3. Start Session Manager / SMSS (PID 2)
  4. SMSS drives subsystem startup
Phase 5 end
```
