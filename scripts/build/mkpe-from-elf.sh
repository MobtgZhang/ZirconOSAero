#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <input.elf> <output.exe> <entry-address> [image-base]" >&2
    exit 1
fi

ELF="$1"
OUTPUT="$2"
ENTRY="$3"
IMAGE_BASE="${4:-0x04000000}"

command -v objcopy >/dev/null 2>&1 || {
    echo "objcopy is required to build PE images" >&2
    exit 1
}

objcopy --strip-all --remove-section=.comment --set-start "$ENTRY" -O pei-x86-64 --image-base="$IMAGE_BASE" "$ELF" "$OUTPUT"

# GNU objcopy leaves SizeOfImage zero for ELF-derived PE images.  Winload uses
# this value for the handoff image table, so compute the section-backed span.
python3 - "$OUTPUT" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "r+b") as handle:
    data = bytearray(handle.read())
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    coff_offset = pe_offset + 4
    _, section_count, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, coff_offset)
    optional_offset = coff_offset + 20
    section_offset = optional_offset + optional_size
    _, section_count, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, coff_offset)
    image_size = 0
    first_section_va = None
    for index in range(section_count):
        base = section_offset + index * 40
        virtual_size = struct.unpack_from("<I", data, base + 8)[0]
        virtual_address = struct.unpack_from("<I", data, base + 12)[0]
        if first_section_va is None:
            first_section_va = virtual_address
        image_size = max(image_size, virtual_address + virtual_size)
    image_size = ((image_size + 0xFFF) & ~0xFFF)

    headers_size = ((section_offset + section_count * 40) + 0x1FF) & ~0x1FF
    if first_section_va and headers_size > first_section_va:
        headers_size = first_section_va
    if headers_size:
        struct.pack_into("<I", data, optional_offset + 60, headers_size)
    struct.pack_into("<I", data, optional_offset + 56, image_size)
    handle.seek(0)
    handle.write(data)
PY
