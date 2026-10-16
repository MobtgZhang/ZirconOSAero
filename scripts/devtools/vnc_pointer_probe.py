#!/usr/bin/env python3
"""Send a persistent absolute pointer event stream to QEMU's VNC server."""

import socket
import struct
import sys
import time


def read_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise RuntimeError("VNC server closed the connection")
        chunks.extend(chunk)
    return bytes(chunks)


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: vnc_pointer_probe.py <host:display> <width>x<height>", file=sys.stderr)
        return 2

    host, display = sys.argv[1].split(":", 1)
    port = 5900 + int(display)
    width, height = (int(value) for value in sys.argv[2].split("x"))

    sock = socket.create_connection((host, port))
    sock.settimeout(2.0)
    greeting = read_exact(sock, 12)
    if greeting != b"RFB 003.008\n":
        raise RuntimeError(f"unexpected RFB greeting: {greeting!r}")
    sock.sendall(b"RFB 003.008\n")
    security_types = read_exact(sock, 1)
    count = security_types[0]
    types = read_exact(sock, count)
    if b"\x01" not in types:
        raise RuntimeError(f"VNC None security unavailable: {types!r}")
    sock.sendall(b"\x01")
    result = struct.unpack(">I", read_exact(sock, 4))[0]
    if result != 0:
        raise RuntimeError(f"VNC security failure: {result}")
    sock.sendall(b"\x01")

    server_init = read_exact(sock, 24)
    name_length = struct.unpack(">I", server_init[20:24])[0]
    read_exact(sock, name_length)

    # Keep the server-provided pixel format and request the raw encoding.
    # QEMU VNC switches the pointer to absolute mode once the standard
    # desktop-size/last-rect pseudo-encodings are negotiated.  Raw is kept so
    # the framebuffer update remains readable by this probe.
    encodings = [0, -223, -224, -258]
    sock.sendall(struct.pack(">BxH", 2, len(encodings)))
    for encoding in encodings:
        sock.sendall(struct.pack(">i", encoding))

    points = [(0.02, 0.02), (0.15, 0.08), (0.28, 0.16), (0.41, 0.24),
              (0.54, 0.32), (0.67, 0.40), (0.80, 0.48), (0.92, 0.56)]
    for x_ratio, y_ratio in points:
        x = int(x_ratio * (width - 1))
        y = int(y_ratio * (height - 1))
        sock.sendall(struct.pack(">BBHHB", 4, 0, x, y, 0))
        print(f"sent pointer ({x},{y})")
        time.sleep(0.1)

    sock.sendall(struct.pack(">BBHHHH", 5, 0, 0, 0, width, height))
    while True:
        update_type = read_exact(sock, 1)
        if update_type == b"\x00":
            break
        if update_type == b"\x01":
            read_exact(sock, 4)
            continue
        if update_type == b"\x02":
            read_exact(sock, 1)
            continue
        if update_type == b"\x03":
            read_exact(sock, 7)
            continue
        raise RuntimeError(f"unexpected VNC message: {update_type!r}")
    rect_count = struct.unpack(">H", read_exact(sock, 2))[0]
    for _ in range(rect_count):
        rect_header = read_exact(sock, 12)
        _, _, rect_w, rect_h, _ = struct.unpack(">HHHHI", rect_header)
        read_exact(sock, rect_w * rect_h * 4)

    time.sleep(0.5)
    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
