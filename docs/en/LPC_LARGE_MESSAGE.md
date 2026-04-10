# LPC Large Messages and `MSG_DATA_SIZE` Boundary (NT 6.1 Alignment Note)

> This kernel process-internal LPC ring (`src/lpc/ipc.zig`) has a single-payload upper bound of **`MSG_DATA_SIZE` (64 bytes)** in the compact `Message.data`. For extended fields in csrss handshake, see [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md).

## Strategy When Exceeding Inline Buffer (Clean-room)

1. **Preferred (roadmap)**: caller maps shared section via **`NtCreateSection` + `NtMapViewOfSection`**; **small messages** carry only **view handle / offset / length** or protocol magic; large data stays in section. Must be accepted in sync with [MM_Section_Roadmap.md](../cn/MM_Section_Roadmap.md).

2. **Section cooperation not yet implemented**: when user-mode `NtRequestWaitReplyPort` / equivalent path detects request exceeding `MSG_DATA_SIZE` copyable payload, should return **`STATUS_BUFFER_TOO_SMALL`** (`0xC0000023`), consistent with MSDN semantics for "buffer too small"; **must not** silently truncate.

3. **QEMU / host tests**: queue semantics with `tests/lpc_two_pid_host.zig` (queue semantics) and contract matrix **B1** behavior as authority; end-to-end test cases added after section view protocol lands.

## References

- [Local Procedure Calls (LPC)](https://learn.microsoft.com/windows-hardware/drivers/kernel/local-procedure-calls-lpc-) — concept layer, no source dependency.
