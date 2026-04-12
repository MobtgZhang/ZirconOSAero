#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Read serial/klog lines from stdin; write NDJSON to .cursor/debug-80cc1c.log.

启动即创建/截断日志文件（写入 ingest_started），避免「从未匹配 DBG80cc1c 则文件不存在」。
标记：行内任意位置出现子串 DBG80cc1c（其后可有可选空格），再跟紧凑字段或 JSON。
环境变量 CURSOR_DEBUG_LOG 可覆盖输出路径（绝对路径或相对 cwd）。

**终端无输出**：`make run … | python3 …` 会把串口 stdout 全送进脚本，终端空白属正常。
请用：`bash scripts/run_loongarch64_with_serial_debug_log.sh`（内部 `tee >(python3 …)`），或自行
`make run-loongarch64 … 2>&1 | tee >(python3 -u scripts/serial_dbg_to_cursor_log.py)`。
"""
import json
import os
import sys
import time

MARKER = "DBG80cc1c"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DEFAULT_OUT = os.path.join(ROOT, ".cursor", "debug-80cc1c.log")
OUT = os.environ.get("CURSOR_DEBUG_LOG", _DEFAULT_OUT)


def parse_compact(rest: str) -> dict:
    # "H2 pf fw u=1"  →  hypothesisId loc msg u
    parts = rest.split()
    u_val = 0
    core = parts
    if parts and parts[-1].startswith("u="):
        u_val = int(parts[-1][2:], 0)  # 支持 0x 前缀（px0）
        core = parts[:-1]
    hid = core[0] if core else "?"
    loc = core[1] if len(core) > 1 else "?"
    msg = core[2] if len(core) > 2 else "?"
    return {
        "sessionId": "80cc1c",
        "hypothesisId": hid,
        "location": loc,
        "message": msg,
        "data": {"u": u_val},
        "runId": "kernel",
    }


def main() -> None:
    parent = os.path.dirname(os.path.abspath(OUT))
    if parent:
        os.makedirs(parent, exist_ok=True)

    matches = 0
    lines_in = 0
    with open(OUT, "w", encoding="utf-8") as out:
        out.write(
            json.dumps(
                {
                    "sessionId": "80cc1c",
                    "message": "ingest_started",
                    "data": {"out": OUT, "ts": int(time.time() * 1000)},
                    "runId": "host",
                },
                ensure_ascii=False,
            )
            + "\n"
        )
        out.flush()

        for line in sys.stdin:
            lines_in += 1
            idx = line.find(MARKER)
            if idx < 0:
                continue
            rest = line[idx + len(MARKER) :].lstrip()
            if not rest:
                continue
            if rest.startswith("{"):
                obj = rest
            else:
                try:
                    obj = json.dumps(parse_compact(rest), ensure_ascii=False)
                except (ValueError, IndexError):
                    obj = json.dumps(
                        {
                            "sessionId": "80cc1c",
                            "message": "parse_error",
                            "data": {"raw": rest[:200]},
                            "runId": "host",
                        },
                        ensure_ascii=False,
                    )
            out.write(obj + "\n")
            out.flush()
            matches += 1

    with open(OUT, "a", encoding="utf-8") as fin:
        fin.write(
            json.dumps(
                {
                    "sessionId": "80cc1c",
                    "message": "ingest_finished",
                    "data": {"lines_in": lines_in, "dbg_matches": matches},
                    "runId": "host",
                },
                ensure_ascii=False,
            )
            + "\n"
        )
        fin.flush()

    if matches == 0:
        print(
            f"[serial_dbg_to_cursor_log] WARN: 0 DBG80cc1c lines → 检查是否已 `make build ARCH=loongarch64`、串口是否进内核、或 CURSOR_DEBUG_LOG={OUT!r}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
