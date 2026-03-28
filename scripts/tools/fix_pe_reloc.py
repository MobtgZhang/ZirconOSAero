#!/usr/bin/env python3
"""
Minimal PE/COFF fixup for LoongArch64 EFI binaries.

参考 AevOS (https://github.com/MobtgZhang/AevOS)：objcopy 生成非 x86 EFI 时
可能产生错误或缺失的 PE 头字段，导致固件返回 LoadImage Unsupported。
本脚本修正 Optional Header 的 Subsystem 为 IMAGE_SUBSYSTEM_EFI_APPLICATION (10)。

不处理 .reloc / 文本段重定位：LoongArch PE 完整重定位与工具链状态见
https://github.com/loongson-community/discussions/issues/108
及同目录说明 scripts/tools/PE_LOONGARCH_UEFI.md。
"""
import struct
import sys

PE_SUBSYSTEM_EFI_APP = 10
IMAGE_DIRECTORY_ENTRY_BASERELOC = 5


def fix_pe(path: str) -> bool:
    with open(path, "r+b") as f:
        data = bytearray(f.read())

    if len(data) < 0x40:
        return False

    # DOS header e_lfanew
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_off + 4 >= len(data):
        return False

    # PE signature
    if data[pe_off : pe_off + 4] != b"PE\x00\x00":
        return False

    # COFF header: 20 bytes
    coff = pe_off + 4
    opt_off = coff + 20

    # Optional Header: PE32+ Magic 0x20b
    if opt_off + 2 > len(data):
        return False
    magic = struct.unpack_from("<H", data, opt_off)[0]
    if magic != 0x20B:
        return False

    # Subsystem at offset 64 in Optional Header (PE32+)
    # See: IMAGE_OPTIONAL_HEADER64 layout
    sub_off = opt_off + 64
    if sub_off + 2 > len(data):
        return False

    old_subsys = struct.unpack_from("<H", data, sub_off)[0]
    if old_subsys != PE_SUBSYSTEM_EFI_APP:
        struct.pack_into("<H", data, sub_off, PE_SUBSYSTEM_EFI_APP)

    with open(path, "wb") as out:
        out.write(data)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: fix_pe_reloc.py <efi_file>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    try:
        if fix_pe(path):
            return 0
        return 1
    except OSError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
