#!/usr/bin/env python3
"""Select QEMU's active pointer for ZirconOS.

VNC and SPICE route host motion through the new input-handler API and reach
VirtIO devices.  QEMU 10.x GTK has not been verified to do so, so PS/2 is used
only as a compatibility fallback when no VirtIO pointer is available.
"""

import json
import socket
import sys
import time


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: qemu_select_virtio_pointer.py <qmp-socket>", file=sys.stderr)
        return 2

    qmp_path = sys.argv[1]
    deadline = time.monotonic() + 10.0
    sock = None
    while sock is None:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(qmp_path)
        except (FileNotFoundError, ConnectionRefusedError):
            sock.close()
            sock = None
            if time.monotonic() >= deadline:
                print("qemu-pointer: QMP socket did not become ready", file=sys.stderr)
                return 1
            time.sleep(0.05)

    try:
        reader = sock.makefile("r")
        writer = sock.makefile("w")
        greeting = reader.readline()
        if not greeting:
            raise RuntimeError("QMP closed before greeting")

        def send(command):
            writer.write(json.dumps(command) + "\n")
            writer.flush()
            response = reader.readline()
            if not response:
                raise RuntimeError("QMP closed before response")
            return json.loads(response)

        send({"execute": "qmp_capabilities"})
        mice = send({"execute": "query-mice"}).get("return", [])
        # QEMU 10 VNC reliably drives HID/PS/2 relative mice; VirtIO queues can
        # stall after short-lived VNC clients.  Prefer USB HID as the fallback.
        usb = [m for m in mice if "USB" in m.get("name", "") and "Mouse" in m.get("name", "")]
        preferred = next((m for m in usb), None)
        if preferred is None:
            virtio = [m for m in mice if "Virtio" in m.get("name", "")]
            preferred = next((m for m in virtio if "Tablet" in m.get("name", "")), None)
            if preferred is None:
                preferred = next((m for m in virtio if "Mouse" in m.get("name", "")), None)
        if preferred is None:
            preferred = next((m for m in virtio), None)
        if preferred is None:
            preferred = next((m for m in mice if m.get("name") == "QEMU PS/2 Mouse"), None)
        if preferred is None:
            print("qemu-pointer: no pointer attached", file=sys.stderr)
            return 1

        response = send(
            {
                "execute": "human-monitor-command",
                "arguments": {"command-line": f"mouse_set {preferred['index']}"},
            }
        )
        if "error" in response:
            print(f"qemu-pointer: {response}", file=sys.stderr)
            return 1
        print(
            f"qemu-pointer: selected {preferred['name']} "
            f"(index {preferred['index']}, absolute={preferred.get('absolute', False)})"
        )
        return 0
    finally:
        sock.close()


if __name__ == "__main__":
    raise SystemExit(main())
