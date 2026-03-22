#!/usr/bin/env python3
"""
Headless QEMU + framebuffer screendump for ZirconOS desktop smoke test.

Requires: qemu-system-x86_64, a built ISO (make iso), optional netcat (nc) for monitor.

Usage:
  ZIRCON_ISO=build/release/zirconos-1.0.0-x86_64.iso python3 tests/qemu_desktop_screenshot.py

The script boots the ISO with serial logged, waits for the desktop phase in serial output,
then sends `screendump` to the QEMU monitor (if reachable) to produce a PPM file.

Serial checks (always):
  - "Desktop: Rendering" appears (kernel reached GUI path)

Framebuffer (optional):
  - Set QEMU_MONITOR=telnet:127.0.0.1:4444 if you start QEMU with
    -monitor telnet:127.0.0.1:4444,server,nowait -display none
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def main() -> int:
    p = argparse.ArgumentParser(description="QEMU desktop serial + optional screendump check")
    p.add_argument("--iso", default=os.environ.get("ZIRCON_ISO", ""), help="Path to zirconos ISO")
    p.add_argument("--wait-desktop", type=float, default=45.0, help="Seconds to wait for desktop log line")
    p.add_argument("--ppm-out", default="", help="Where to write PPM from screendump")
    p.add_argument(
        "--monitor",
        default=os.environ.get("QEMU_MONITOR", ""),
        help="host:port for QEMU monitor (telnet), e.g. 127.0.0.1:4444",
    )
    args = p.parse_args()

    if not args.iso or not os.path.isfile(args.iso):
        print("ERROR: set --iso or ZIRCON_ISO to a built ISO", file=sys.stderr)
        return 2

    qemu = shutil.which("qemu-system-x86_64")
    if not qemu:
        print("ERROR: qemu-system-x86_64 not in PATH", file=sys.stderr)
        return 2

    log_fd, log_path = tempfile.mkstemp(prefix="zircon-serial-", suffix=".log")
    os.close(log_fd)

    # Headless: no display; serial to file so we can grep.
    cmd = [
        qemu,
        "-m",
        "512M",
        "-cdrom",
        args.iso,
        "-serial",
        f"file:{log_path}",
        "-display",
        "none",
        "-no-reboot",
        "-no-shutdown",
    ]

    mon_host, mon_port = None, None
    if args.monitor:
        hp = args.monitor.rsplit(":", 1)
        if len(hp) == 2:
            mon_host, mon_port = hp[0], int(hp[1])
            cmd += ["-monitor", f"telnet:{mon_host}:{mon_port},server,nowait"]

    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + args.wait_desktop
        pat = re.compile(r"Desktop: Rendering", re.I)
        ok_serial = False
        while time.time() < deadline:
            time.sleep(0.4)
            try:
                with open(log_path, "r", errors="replace") as f:
                    body = f.read()
            except OSError:
                body = ""
            if pat.search(body):
                ok_serial = True
                break
            if proc.poll() is not None:
                break

        if not ok_serial:
            print("FAIL: serial log does not contain 'Desktop: Rendering' within timeout")
            print(f"  log: {log_path}")
            return 1
        print("OK: serial indicates desktop render phase reached")
        print(f"  log: {log_path}")

        if mon_host is not None and mon_port is not None and args.ppm_out:
            time.sleep(1.0)
            try:
                sock = socket.create_connection((mon_host, mon_port), timeout=5.0)
            except OSError as e:
                print(f"WARN: could not connect to monitor {mon_host}:{mon_port}: {e}")
                return 0
            try:
                ppm = os.path.abspath(args.ppm_out)
                cmd_mon = f"screendump {ppm}\n"
                sock.sendall(cmd_mon.encode())
                time.sleep(0.5)
            finally:
                sock.close()
            if os.path.isfile(ppm):
                print(f"OK: screendump wrote {ppm}")
            else:
                print(f"WARN: screendump did not create {ppm}")
        elif args.monitor and not args.ppm_out:
            print("INFO: --monitor set but no --ppm-out; skipping screendump")

        return 0
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
