# NT 6.1-style built-in apps roadmap (clean-room)

This document tracks **implementation status, subsystem dependencies, and reference policy** for apps commonly bundled with Windows 7–style shells. Implementations must be original; do not copy Windows, ReactOS, or Wine source or Microsoft-proprietary assets. AI-generated code requires human copyright review (see repository rules under `.cursor/rules/zig-nt61-copyright-safety-testing.mdc`).

## References (desktop-src)

Offline Microsoft Learn mirror (example path): `ZirconOSFluentRust/references/win32/desktop-src` — same contract as [DesktopManagerSpec.md](../cn/DesktopManagerSpec.md) section 7. Use **only** for public API names and documented behaviour, **not** as source code.

## Application platform (host model)

The current desktop is **kernel framebuffer + Aero renderer** (see [AeroDesktopRuntime.md](../cn/AeroDesktopRuntime.md)). Built-in GUIs use **Phase 1-B: in-shell embedded windows** in [`src/drivers/video/builtin_apps.zig`](../../src/drivers/video/builtin_apps.zig). Future **user-mode processes + `CreateProcess`** can coexist; update the status column here when migrating.

| Piece | Location | Notes |
|-------|----------|--------|
| App IDs & launch | `builtin_apps.zig` | `BuiltinAppId` is the single source of truth |
| Start menu → launch | `startmenu.zig` | Left/right columns + All Programs |
| Paint & hit-test | `display.zig`, `renderer_aero.zig` | Drawn above Task Manager |
| File dialog | `builtin_apps.zig` (`FileDialog`) | VFS open/save; demo path below |
| Clipboard | `builtin_apps.zig` (`Clipboard`) | Primary: `text` or `dib_bgr32` stub (Snipping Tool) |

## Code alignment (keep in sync)

| Item | Source of truth |
|------|-----------------|
| `BuiltinAppId` | `enum(u16)` in `builtin_apps.zig` |
| `ALL_PROGRAMS` | **13** entries: `notepad, wordpad, paint, calculator, minesweeper, solitaire, spider_solitaire, freecell, hearts, osk, charmap, cmd_shell, dotnet_shell_host` |
| Demo path | `demo_notepad_vfs_path` = `C:\NOTEPAD.TXT` |
| Task Manager front | `display.bringTaskManagerToFront()`; hotkey **Ctrl+Shift+Esc** via `handleDesktopHotkeys` → `consumeTaskMgrHotkey` |
| `taskmgr_focus` | `launch(.taskmgr_focus)` logs only; **no** Start Menu row — do not confuse with the hotkey |
| Start search | `feedSearchFromKeyboard`; when non-empty, **ASCII substring** filter (case-insensitive) on left/right columns and All Programs |
| Input inject | `arch.injectSyntheticChar` — x86_64 PS/2 ring; loongarch64 VirtIO evdev bridge |

## Task Manager vs. “Windows Search” wording

- **Task Manager**: Kernel-rendered window (not a `BuiltinAppId` client). Process rows from [`process.getProcessList()`](../../src/ps/process.zig) (up to 8 rows + overflow hint). CPU/Memory columns are placeholders.
- **Windows Search**: **Partial** — search box buffer, placeholder text, and **menu row filtering** only; no indexer/service.

## Gadgets (kernel vs. host)

The in-kernel shell **does not** host Sidebar gadgets. Clock/weather-style extensions live in the **user-mode** tree: [`src/desktop/aero/src/gadgets.zig`](../../src/desktop/aero/src/gadgets.zig).

## Explorer checklist

Track these against [`shell_strings.zig`](../../src/drivers/video/shell_strings.zig) and `renderer_aero` (replaces vague “deepening”):

- [ ] Command bar / Libraries strings match `shell_strings` (en/cn)  
- [ ] Footer status lines match `explorer_w2k_loc` transitions  
- [ ] Left-pane hit targets match painted geometry  
- [ ] Same navigation works under Aero and classic themes  

## Status legend

| Tag | Meaning |
|-----|---------|
| full | Minimal interactive behaviour |
| full(min) | Plain-text or minimal game rules; advanced formats on separate **planned** row |
| partial | Some plumbing (VFS, clipboard stub, output count, etc.) |
| stub | Frame + descriptive text / klog |
| planned | Listed only |
| n/a | Documented out-of-scope |

## Accessories

| App | Status | Dependencies | desktop-src hints |
|-----|--------|--------------|-------------------|
| Paint | full | framebuffer, mouse | `gdi/` |
| WordPad — plain text | full(min) | separate buffer, `FileDialog`, `readInputChar` | `richedit/`, `shell/` (concepts) |
| WordPad — RTF subset | planned | RTF parser subset | public RTF overview (not source) |
| Notepad | full | keyboard, VFS dialog | edit-control concepts |
| Calculator | full | mouse | — |
| Snipping Tool | partial | `copyDrawBufferRectBytes`, `setDibBgr32` | `gdi/`, clipboard concepts |
| Magnifier | partial | mouse, framebuffer ROI, nearest-neighbour blit | `winuser/`, magnification concepts |
| Narrator | partial | focus changes → klog (no TTS) | accessibility docs |
| On-Screen Keyboard | full | `Clipboard` + `injectSyntheticChar` | `inputdev/` |
| Character Map | full | `Clipboard`, UTF-8 | `wingdi/`, string concepts |
| Sync Center | partial | `hdmi.getOutputCount()` / IOCTL parity | `shell/`, sync concepts |
| Connect to a projector | partial | same output-count text | display enumeration docs |

## Media

| App | Status | Notes |
|-----|--------|-------|
| Windows Media Player | stub | No kernel PCM/WAV buffer yet |
| Media Center | planned | Low priority |
| DVD Maker | n/a | Not targeted |
| Sound Recorder | partial | Decorative VU; capture IOCTL TBD |

## Network

| App | Status | Notes |
|-----|--------|-------|
| Internet Explorer 8 | stub | **No Trident**; pluggable renderer policy (e.g. Gecko/WebKit-class) below |
| Windows Live Mail | planned | Not core Win7 preload |
| Fax and Scan | stub | TWAIN/WIA **topic names** in desktop-src: `twain`, `wia_*` (index only) |

**IE policy**: URL/bookmark stubs OK; engine behind an abstract interface — not MSHTML.

## System tools

| App | Status | Notes |
|-----|--------|-------|
| Task Manager | partial | `getProcessList()`; CPU/mem sampling later |
| Control Panel | partial | CPL category list (extend applets) |
| Registry Editor | partial | In-memory demo keys |
| Disk Cleanup | stub | Safety note in stub text — no destructive wipe until quota APIs |
| Defragmenter | stub | Block IOCTL TBD |
| Backup / System Restore | stub | No VSS |
| Event Viewer | partial | Static channel lines |
| Device Manager | partial | PCI / `pcie.zig` copy |
| Computer Management | partial | Rows launch Event Viewer / Device Manager windows |
| Resource / Performance Monitor | stub | Sampling phase 2 |
| Task Scheduler | stub | Job store TBD |
| Command Prompt | stub | Minimal in-kernel CMD line in `cmd.zig` |
| **PowerShell**-style cmdlet host | **Out of scope (this repo)** | **No in-kernel PowerShell**; a .NET **user-mode** host is planned **outside** this tree; this kernel keeps syscall / LPC / Section support only (see Phase F / contract matrix). |

## Games

| App | Status | Notes |
|-----|--------|-------|
| Minesweeper | full | Original logic |
| Solitaire | partial | Minimal 1..13 ordering game |
| Spider Solitaire | partial | 1..10 subset |
| FreeCell | stub | Planned |
| Hearts | stub | Planned |
| Chess / Mahjong / Purble / Internet | planned | After assets/network |

## Shell

| App | Status | Notes |
|-----|--------|-------|
| Explorer | partial | See **Explorer checklist** |
| Gadgets | n/a (kernel) | Host-only `gadgets.zig` |
| Windows Search | partial | Menu filter + box; no indexer |

## Security

| App | Status | Notes |
|-----|--------|-------|
| Defender / Firewall / Update | stub | Copy points to [Learn — Windows security](https://learn.microsoft.com/windows/security/) and WDK/WFP **concepts** only |
| BitLocker | stub | Enterprise disclaimer; cross-ref `src/se/token.zig` |
| UAC | stub | Simulated prompt flow; same Se/token docs |

## Copyright checklist (review-copyright)

Before each merge/release:

1. No Windows/ReactOS/Wine source snippets.  
2. New assets follow [Assets.md](../cn/Assets.md).  
3. Refresh **this file and the Chinese table** status columns and the date below.  

(Ongoing — PR checklist + human review.)

---

**Last updated**: 2026-03-28 — aligned with `builtin_apps.zig`, `startmenu.zig`, `display.zig`.
