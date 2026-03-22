# ZirconOS Aero Cursor Set

Original crystal/glass-themed cursor designs for the ZirconOS Aero desktop theme.

## Design Language

All cursors share a consistent **ZirconOS Crystal Glass** aesthetic:

- **Color palette**: Teal-to-deep-blue gradient (#A8F0F0, #2ABFBF, #1A8A8A, #0D5C5C)
- **Glass effects**: Linear and radial gradients simulating translucent crystal surfaces
- **Glow**: Subtle teal glow via `feGaussianBlur` SVG filter on each cursor
- **Outline**: Dark (#062828) outline for legibility on any background
- **Sparkle accents**: Small white/teal highlights to reinforce the crystal motif
- **Format**: SVG with `viewBox="0 0 32 32"` (32x32 logical pixels)

## Cursor Files

| File | Type | Description |
|------|------|-------------|
| `zircon_arrow.svg` | Default pointer | Crystalline pointed arrow with glass gradient and highlight streak |
| `zircon_link.svg` | Link / hand | Open hand with pointing finger in crystal glass style |
| `zircon_move.svg` | Move | Four-directional arrow cross with glass gradient and rounded ends |
| `zircon_ns.svg` | Vertical resize | Double-headed vertical arrow with glass styling |
| `zircon_ew.svg` | Horizontal resize | Double-headed horizontal arrow with glass styling |
| `zircon_nwse.svg` | Diagonal resize (NW-SE) | Double-headed diagonal arrow from top-left to bottom-right |
| `zircon_nesw.svg` | Diagonal resize (NE-SW) | Double-headed diagonal arrow from top-right to bottom-left |
| `zircon_text.svg` | Text / I-beam | I-beam with serifs and middle crossbar for text selection |
| `zircon_help.svg` | Help | Arrow cursor with crystal question-mark badge |
| `zircon_unavail.svg` | Unavailable / forbidden | Circle with diagonal strike-through (red slash on teal ring) |
| `zircon_busy.svg` | Busy / loading | Circular spinner with glass gradient sectors and center "Z" mark |
| `zircon_working.svg` | Background working | Arrow cursor with small spinner ring overlay |
| `zircon_pen.svg` | Pen / draw | Stylized pen with glass body, ferrule band, and writing-point glow |
| `zircon_up.svg` | Up arrow / alternate select | Upward-pointing arrow with glass gradient |

## Cursor Mapping

Standard cursor names to ZirconOS file mapping for theme integration:

```
default          -> zircon_arrow.svg
pointer          -> zircon_link.svg
move             -> zircon_move.svg
ns-resize        -> zircon_ns.svg
ew-resize        -> zircon_ew.svg
nwse-resize      -> zircon_nwse.svg
nesw-resize      -> zircon_nesw.svg
text             -> zircon_text.svg
help             -> zircon_help.svg
not-allowed      -> zircon_unavail.svg
wait             -> zircon_busy.svg
progress         -> zircon_working.svg
crosshair/pen    -> zircon_pen.svg
up-arrow         -> zircon_up.svg
```

## Technical Notes

- Each SVG uses self-contained `<defs>` with unique gradient/filter IDs to avoid conflicts when multiple cursors are loaded
- Glass effect is achieved through layered `linearGradient` fills with a semi-transparent `feGaussianBlur` glow filter
- Dark outlines ensure visibility on both light and dark backgrounds
- The `zircon_unavail.svg` cursor uses a red gradient slash (#FF6B6B to #991111) to distinguish the forbidden state from the teal base
- The `zircon_busy.svg` spinner uses four sectors with decreasing opacity to suggest rotation

## Copyright

Copyright (C) 2024-2026 ZirconOS Project
Licensed under GNU Lesser General Public License v2.1

These cursor designs are **original creations** for ZirconOS and are NOT derived from,
copied from, or affiliated with any Microsoft Corporation products or any other
third-party cursor sets.
