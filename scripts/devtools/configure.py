#!/usr/bin/env python3
"""Interactive helper for the Makefile-owned ZirconOSAero configuration.

The Makefile is the source of truth.  This command prints a shell fragment
instead of writing the removed ``build.conf`` file; use ``eval`` or copy the
printed assignments into a ``make`` invocation.
"""

import os
import sys
import re

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def effective_setting(setting, values):
    _ = values
    return setting


SETTINGS = [
    {
        "key": "ARCH",
        "prompt": "Target architecture",
        "options": ["x86_64", "aarch64", "loongarch64", "riscv64", "mips64el"],
        "default": "x86_64",
    },
    {
        "key": "BOOT_METHOD",
        "prompt": "Boot method",
        "options": ["uefi", "mbr"],
        "default": "uefi",
    },
    {
        "key": "BOOTLOADER",
        "prompt": "Bootloader (ZBM only in this tree)",
        "options": ["zbm"],
        "default": "zbm",
    },
    {
        "key": "DESKTOP",
        "prompt": "Desktop theme",
        "options": ["aero", "none"],
        "default": "aero",
    },
    {
        "key": "OPTIMIZE",
        "prompt": "Build optimization",
        "options": ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"],
        "default": "Debug",
    },
    {
        "key": "RESOLUTION",
        "prompt": "Display resolution",
        "options": ["1024x768x32", "1280x800x32", "1280x1024x32", "1920x1080x32"],
        "default": "1024x768x32",
    },
    {
        "key": "QEMU_MEM",
        "prompt": "QEMU memory",
        "options": ["256M", "512M", "1G", "2G"],
        "default": "512M",
    },
]


def read_current_conf():
    """Read defaults from the Makefile's literal ``?=`` assignments."""
    values = {}
    makefile = os.path.join(PROJECT_ROOT, "Makefile")
    if os.path.exists(makefile):
        with open(makefile) as f:
            for line in f:
                m = re.match(r"^(\w+)\s*\?=\s*(.+)$", line.strip())
                if m:
                    values[m.group(1)] = m.group(2).strip()
    return values


def prompt_choice(setting, current_val):
    """Prompt user for a single setting."""
    key = setting["key"]
    options = setting["options"]
    default = current_val if current_val in options else setting["default"]

    print(f"\n  {setting['prompt']} ({key}):")
    for i, opt in enumerate(options):
        marker = " *" if opt == default else ""
        print(f"    {i + 1}) {opt}{marker}")

    while True:
        raw = input(f"  Choose [1-{len(options)}] (default: {default}): ").strip()
        if not raw:
            return default
        try:
            idx = int(raw) - 1
            if 0 <= idx < len(options):
                return options[idx]
        except ValueError:
            if raw in options:
                return raw
        print(f"  Invalid choice. Enter 1-{len(options)} or press Enter for default.")


def print_make_assignments(values):
    """Print assignments that can be passed directly to ``make``."""
    if values.get("ARCH") == "loongarch64":
        values = dict(values)
        values["BOOTLOADER"] = "zbm"
    return " ".join(f"{setting['key']}={values.get(setting['key'], setting['default'])}" for setting in SETTINGS)


def main():
    print("╔══════════════════════════════════════════╗")
    print("║   ZirconOS Build Configuration Wizard    ║")
    print("╚══════════════════════════════════════════╝")

    current = read_current_conf()

    if current:
        print("\n  Current configuration:")
        for s in SETTINGS:
            k = s["key"]
            v = current.get(k, s["default"])
            print(f"    {k:15s} = {v}")

    values = dict(current)
    for setting in SETTINGS:
        eff = effective_setting(setting, values)
        cur = current.get(setting["key"], eff["default"])
        values[setting["key"]] = prompt_choice(eff, cur)

    print("\n  New configuration:")
    for s in SETTINGS:
        k = s["key"]
        print(f"    {k:15s} = {values[k]}")

    confirm = input("\n  Print these Makefile assignments? [Y/n]: ").strip().lower()
    if confirm in ("", "y", "yes"):
        print("\n  Make assignments:")
        print(f"  make {print_make_assignments(values)}")
    else:
        print("  Cancelled.")


if __name__ == "__main__":
    main()
