// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! GOP / VBE 类固件常按 **16 像素**（或更大）对齐行宽扫描 VRAM，但 UEFI 的 `PixelsPerScanLine` 可能与
//! `HorizontalResolution` 相同（如 1366）。Multiboot2 tag 若携带该紧排字节行距，内核会按错误 stride
//! 绘制 → 对角带状花屏。此处将行距抬到至少 `alignUp(horizontal_resolution, 16) * cpp`（32bpp 主路径）。

pub fn effectivePitchBytes(horizontal_resolution: u32, pixels_per_scan_line: u32, bpp: u8) u32 {
    const cpp: u32 = @as(u32, bpp) / 8;
    if (cpp == 0) return 0;
    var line_px = pixels_per_scan_line;
    if (line_px < horizontal_resolution) line_px = horizontal_resolution;
    if (bpp == 32) {
        const aligned_w = (horizontal_resolution + 15) & ~@as(u32, 15);
        if (line_px < aligned_w) line_px = aligned_w;
    }
    return line_px *| cpp;
}
