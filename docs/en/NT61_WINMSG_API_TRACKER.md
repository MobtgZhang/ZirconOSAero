# NT 6.1 Window Message / user32 Contract Trace Table (ZirconOSAero)

> This table links **Microsoft Learn** window functions and messages to repository paths and tests. Implementation must be clean-room. Each batch of capabilities merged must update [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) and run `bash scripts/verify-compliance.sh` (see [NT61_PR_GATES.md](NT61_PR_GATES.md)).

| Category | Name | Reference (Learn) | Code Path | Test / Verification |
|---------|------|-------------------|-----------|---------------------|
| API | `CreateWindowEx` | Window functions | `src/subsystems/win32/user32.zig` | Contract: fail `NULL` + `SetLastError` |
| API | `DestroyWindow` | same | same | `ERROR_INVALID_HANDLE` |
| API | `SetWindowPos` / `MoveWindow` | same | same | coordinates with `dwm_compositor` dirty region |
| API | `GetMessage` / `PeekMessage` | Message pump | same | thread filtering + `PM_*`; malformed min/max → `ERROR_INVALID_PARAMETER`; **msg_pm_semantics_host** |
| Kernel | `NtUserDispatchMessage` (folded SSDT `0x5E`) | Message pump | `syscall.zig` + `user32.zig` `ntUserDispatchMessageSyscall` | same path as `DispatchMessageA` (no WndProc table → `DefWindowProcA`); **win32k_api_semantics_host** |
| API | `BeginPaint` / `EndPaint` | WM_PAINT | same | `PAINTSTRUCT` |
| Message | `WM_DWMCOMPOSITIONCHANGED` etc. | DWM messages | `user32.zig` `broadcastDwm*` | matrix §4 |
| Message | `WM_NCHITTEST` / `WM_NCLBUTTONDOWN` | NC area | `user32.zig` `DefWindowProcA` | [PointerPolicy_NT61.md](../cn/PointerPolicy_NT61.md) |
| Message | `WM_DWMSENDICONICTHUMBNAIL` | DWM | `user32.broadcastDwmIconicThumbnailRequested` + `dwm_compositor` thumbnail buffer | matrix §4 |
| Kernel | HWND / Z-order authoritative source | win32k concepts | `user32` + `win32k/mod.zig` | `zig build test` → win32k_host |
| LPC | `register_window` / `post_message` | Subsystem | `subsystem.zig` + `port.setCsrRequestHandler` | MVT / manual test |

## Maintenance

When adding rows, synchronize **§ status** and [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md) (if a corresponding row exists).
