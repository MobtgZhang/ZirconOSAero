# LPC and User-Mode Service Split (Contract Draft)

## Principles

- **Kernel**: retains only mechanisms (ports, handles, scheduling, page tables, raw IRP dispatch).
- **User-mode services**: **policy** for Object / I/O / Security (namespace rules, device stack policy, DAC decision cache).

## Message Direction (Placeholder IDs)

| Service | Suggested port name prefix | Request types (enum placeholders) | Payload outline |
|---------|---------------------------|--------------------------------|---------------|
| Object Manager | `\RPC Control\Ob` | `ObCreateHandle`, `ObLookup` | object type, path, access mask |
| I/O Manager | `\RPC Control\Io` | `IoRegisterDevice`, `IoComplete` | device name, IRP major/minor, buffer handle |
| Security | `\RPC Control\Se` | `SeAccessCheck` | token handle, SD handle, desired access |

Actual message layouts must be stabilized into versioned structs after `src/lpc/ipc.zig` / `port.zig` are stable. This table is **copyright-safe interface planning only**; does not bind to Windows private RPC layout.

## Evolution Steps

1. Mark existing in-kernel "policy branches" with `// TODO: migrate to user server`.
2. Define `NtStatus` mapping and timeout per request.
3. Update component diagram in [Servers.md](Servers.md).

## References

Microsoft Learn — LPC/ALPC concept-layer descriptions (behavioral level); implementation is original.
