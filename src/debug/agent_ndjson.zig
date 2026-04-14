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

//! `-Dagent_ndjson=true`：经 **串口** 输出单行 `AGENT_LOG:{...}`（NDJSON），供宿主机 `scripts/agent-ingest-serial.sh` 写入 `.cursor/debug-35ce7e.log`。
//! 访客内核无法直接 open 宿主机路径，故必须管道摄取。
//!
//! **hypothesisId 判读（鼠标 / VirtIO）**
//! - H1：VirtIO-Input PCI 枚举与 attach 摘要（无设备 / 槽位数）。
//! - H4：桌面主循环心跳（`virtio_input_pci.isActive`、指针坐标）。
//! - VirtIO 热路径（pollOne）不再输出 NDJSON，避免串口背压与 QEMU 交互假死；调试用 `-Dmouse_debug=true`。
//! - H7：attach 时环 GPA、事件槽偏移、队列深度、设备 status。

const arch = @import("../arch.zig");

const session_id = "35ce7e";

var seq: u64 = 0;

fn copyOut(buf: []u8, pos: *usize, s: []const u8) bool {
    if (pos.* + s.len > buf.len) return false;
    @memcpy(buf[pos.* .. pos.* + s.len], s);
    pos.* += s.len;
    return true;
}

fn copyU64(buf: []u8, pos: *usize, n: u64) bool {
    var tmp: [20]u8 = undefined;
    var i: usize = 0;
    var x = n;
    if (x == 0) {
        tmp[0] = '0';
        i = 1;
    } else {
        while (x > 0) : (x /= 10) {
            tmp[i] = @truncate('0' + (x % 10));
            i += 1;
        }
    }
    if (pos.* + i > buf.len) return false;
    while (i > 0) {
        i -= 1;
        buf[pos.*] = tmp[i];
        pos.* += 1;
    }
    return true;
}

fn copyI64(buf: []u8, pos: *usize, n: i64) bool {
    if (n >= 0) return copyU64(buf, pos, @intCast(n));
    if (!copyOut(buf, pos, "-")) return false;
    const v: u64 = @intCast(-@as(i128, n));
    return copyU64(buf, pos, v);
}

/// 固定 data 键 u0..u3（u64）；i0/i1 为有符号（坐标等）。
pub fn emit(
    hypothesisId: []const u8,
    location: []const u8,
    message: []const u8,
    runId: []const u8,
    du0: u64,
    du1: u64,
    du2: u64,
    du3: u64,
    di0: i64,
    di1: i64,
) void {
    // #region agent log
    if (!@import("build_options").agent_ndjson) return;

    seq +%= 1;
    var buf: [420]u8 = undefined;
    var pos: usize = 0;
    if (!copyOut(&buf, &pos, "AGENT_LOG:{\"sessionId\":\"")) return;
    if (!copyOut(&buf, &pos, session_id)) return;
    if (!copyOut(&buf, &pos, "\",\"hypothesisId\":\"")) return;
    if (!copyOut(&buf, &pos, hypothesisId)) return;
    if (!copyOut(&buf, &pos, "\",\"location\":\"")) return;
    if (!copyOut(&buf, &pos, location)) return;
    if (!copyOut(&buf, &pos, "\",\"message\":\"")) return;
    if (!copyOut(&buf, &pos, message)) return;
    if (!copyOut(&buf, &pos, "\",\"runId\":\"")) return;
    if (!copyOut(&buf, &pos, runId)) return;
    if (!copyOut(&buf, &pos, "\",\"timestamp\":")) return;
    if (!copyU64(&buf, &pos, seq)) return;
    if (!copyOut(&buf, &pos, ",\"data\":{\"u0\":")) return;
    if (!copyU64(&buf, &pos, du0)) return;
    if (!copyOut(&buf, &pos, ",\"u1\":")) return;
    if (!copyU64(&buf, &pos, du1)) return;
    if (!copyOut(&buf, &pos, ",\"u2\":")) return;
    if (!copyU64(&buf, &pos, du2)) return;
    if (!copyOut(&buf, &pos, ",\"u3\":")) return;
    if (!copyU64(&buf, &pos, du3)) return;
    if (!copyOut(&buf, &pos, ",\"i0\":")) return;
    if (!copyI64(&buf, &pos, di0)) return;
    if (!copyOut(&buf, &pos, ",\"i1\":")) return;
    if (!copyI64(&buf, &pos, di1)) return;
    if (!copyOut(&buf, &pos, "}}\n")) return;

    arch.serialWrite(buf[0..pos]);
    // #endregion
}
