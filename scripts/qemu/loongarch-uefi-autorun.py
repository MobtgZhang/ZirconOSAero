#!/usr/bin/env python3
"""
在 UEFI 内置 Shell 中自动输入 fs0: 与 \\EFI\\BOOT\\BOOTLOONGARCH64.EFI 以启动 ZBM。

原因：多数发行版自带的 qemu-system-loongarch64 的 virt 机不支持 pflash0/pflash1，
仅用 -bios QEMU_EFI.fd 时无法挂载可写 NVRAM（QEMU_VARS.fd），BdsDxe 常报 Boot0001 Not Found
并退回 Shell。本脚本用 pty 在串口上自动输入路径，无需安装 expect。

用法：由 Makefile 设置环境变量后调用；也可手动：
  ZIRCON_ESP=/path/esp-loongarch64.img LOONGARCH64_EFI_CODE=/path/QEMU_EFI.fd \\
    python3 scripts/qemu/loongarch-uefi-autorun.py
"""
from __future__ import annotations

import errno
import os
import select
import sys
import termios
import time
import tty


def find_repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(here))


def main() -> None:
    root = find_repo_root()
    esp = os.environ.get(
        "ZIRCON_ESP",
        os.path.join(root, "build", "esp-loongarch64.img"),
    )
    code = os.environ.get("LOONGARCH64_EFI_CODE", "")
    if not code or not os.path.isfile(code):
        alt = os.path.join(
            os.path.expanduser("~"), "Firmware", "LoongArchVirtMachine", "QEMU_EFI.fd"
        )
        code = alt if os.path.isfile(alt) else os.path.join(
            root, "firmware", "QEMU_EFI-loongarch64.fd"
        )
    mem = os.environ.get("QEMU_MEM_LOONGARCH64", "1536M")

    if not os.path.isfile(esp):
        print(f"[ZirconOS] ERROR: 缺少 ESP: {esp}（先 make build-esp ARCH=loongarch64）", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(code):
        print(f"[ZirconOS] ERROR: 缺少固件: {code}", file=sys.stderr)
        sys.exit(1)

    qemu = os.environ.get("QEMU_SYSTEM_LOONGARCH64", "qemu-system-loongarch64")
    # 与 Makefile QEMU_LOONGARCH64_BASE + DEVICES 一致；无头 CI 可设 ZIRCON_QEMU_DISPLAY=none
    disp = os.environ.get(
        "ZIRCON_QEMU_DISPLAY", "gtk,zoom-to-fit=on,show-cursor=on"
    ).strip()
    argv = [
        qemu,
        "-M",
        "virt",
        "-cpu",
        "la464",
        "-m",
        mem,
        "-serial",
        "stdio",
        "-no-reboot",
        "-no-shutdown",
        "-display",
        disp,
        "-bios",
        code,
        "-drive",
        f"if=none,id=zircon-esp0,file={esp},format=raw",
        "-device",
        "virtio-blk-pci,drive=zircon-esp0,bootindex=0",
        "-device",
        "virtio-gpu-pci",
        "-boot",
        "order=d",
    ]

    master_fd, slave_fd = os.openpty()
    try:
        pid = os.fork()
    except OSError as e:
        print(f"[ZirconOS] fork failed: {e}", file=sys.stderr)
        sys.exit(1)

    if pid == 0:
        os.close(master_fd)
        os.setsid()
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        os.execvp(argv[0], argv)
        sys.exit(127)

    os.close(slave_fd)

    old = None
    if sys.stdin.isatty():
        try:
            old = termios.tcgetattr(sys.stdin.fileno())
            tty.setcbreak(sys.stdin.fileno())
        except (termios.error, OSError):
            old = None

    buf = bytearray()
    state = "wait_shell"
    fs0_sent_at: float = 0.0

    try:
        while True:
            if state == "wait_fs0" and fs0_sent_at > 0 and (time.monotonic() - fs0_sent_at) > 1.6:
                os.write(master_fd, b"EFI/BOOT/BOOTLOONGARCH64.EFI\r")
                state = "forward"
                buf.clear()

            readers = [master_fd]
            if sys.stdin.isatty():
                readers.append(sys.stdin.fileno())
            r, _, _ = select.select(readers, [], [], 0.3)

            if master_fd in r:
                try:
                    chunk = os.read(master_fd, 8192)
                except OSError as e:
                    if e.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                buf.extend(chunk)
                # 控制缓冲区大小，避免无限增长
                if len(buf) > 256 * 1024:
                    del buf[:-65536]

                # 必须等 Shell> 出现（内置 Shell）；不要用 \\EFI\\BOOT\\...，固件会报 Unsupported，应用正斜杠。
                if state == "wait_shell" and b"Shell>" in buf:
                    os.write(master_fd, b"fs0:\r")
                    state = "wait_fs0"
                    fs0_sent_at = time.monotonic()
                    buf.clear()
                elif state == "wait_fs0" and b"FS0:\\>" in buf:
                    os.write(master_fd, b"EFI/BOOT/BOOTLOONGARCH64.EFI\r")
                    state = "forward"
                    buf.clear()

            if state == "forward" and sys.stdin.isatty() and sys.stdin.fileno() in r:
                try:
                    u = os.read(sys.stdin.fileno(), 4096)
                except OSError:
                    u = b""
                if u:
                    os.write(master_fd, u)
    finally:
        if old is not None:
            try:
                termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
            except (termios.error, OSError):
                pass
        os.close(master_fd)

    _, st = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)


if __name__ == "__main__":
    main()
