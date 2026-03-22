#!/usr/bin/env python3
"""
ZirconOS Multiboot2 Header & Kernel ELF Verification Tests

Validates that the kernel ELF binary meets Multiboot2 spec requirements
and has a correct structure for GRUB/UEFI boot.

Usage:
    python3 tests/test_multiboot.py [--kernel PATH]

The default kernel path is build/tmp/kernel-prefix/bin/kernel.
Test artifacts are written to build/test-results/.
"""

import argparse
import os
import struct
import sys
import json
from datetime import datetime

MULTIBOOT2_HEADER_MAGIC = 0xE85250D6
MULTIBOOT2_BOOT_MAGIC = 0x36D76289
MULTIBOOT2_ARCH_I386 = 0
MULTIBOOT2_MAX_HEADER_OFFSET = 32768  # 32KB

ELF_MAGIC = b'\x7fELF'
ELF_CLASS_64 = 2
ELF_DATA_LSB = 1
EM_X86_64 = 62

RESULTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'build', 'test-results')


class TestResult:
    def __init__(self, name):
        self.name = name
        self.passed = 0
        self.failed = 0
        self.errors = []

    def ok(self, msg):
        self.passed += 1
        print(f"  [PASS] {msg}")

    def fail(self, msg, detail=""):
        self.failed += 1
        err = f"{msg}: {detail}" if detail else msg
        self.errors.append(err)
        print(f"  [FAIL] {err}")

    def summary(self):
        total = self.passed + self.failed
        status = "PASSED" if self.failed == 0 else "FAILED"
        return {
            "suite": self.name,
            "total": total,
            "passed": self.passed,
            "failed": self.failed,
            "status": status,
            "errors": self.errors,
        }


def read_kernel(path):
    if not os.path.exists(path):
        print(f"ERROR: Kernel not found at {path}")
        print("Run 'make build' first.")
        sys.exit(1)
    with open(path, 'rb') as f:
        return f.read()


def test_elf_header(data, result):
    """Validate ELF64 header structure."""
    print("\n=== ELF Header Tests ===")

    if len(data) < 64:
        result.fail("ELF file too small", f"{len(data)} bytes < 64 bytes minimum")
        return None

    magic = data[0:4]
    if magic == ELF_MAGIC:
        result.ok(f"ELF magic valid ({magic.hex()})")
    else:
        result.fail("ELF magic invalid", f"got {magic.hex()}, expected 7f454c46")
        return None

    ei_class = data[4]
    if ei_class == ELF_CLASS_64:
        result.ok("ELF class: 64-bit")
    else:
        result.fail("ELF class not 64-bit", f"got {ei_class}, expected {ELF_CLASS_64}")

    ei_data = data[5]
    if ei_data == ELF_DATA_LSB:
        result.ok("ELF data encoding: little-endian")
    else:
        result.fail("ELF data encoding not little-endian", f"got {ei_data}")

    e_type = struct.unpack_from('<H', data, 16)[0]
    if e_type == 2:
        result.ok("ELF type: ET_EXEC (executable)")
    else:
        result.fail("ELF type not ET_EXEC", f"got {e_type}, expected 2")

    e_machine = struct.unpack_from('<H', data, 18)[0]
    if e_machine == EM_X86_64:
        result.ok(f"ELF machine: x86_64 ({e_machine})")
    else:
        result.fail("ELF machine not x86_64", f"got {e_machine}, expected {EM_X86_64}")

    e_entry = struct.unpack_from('<Q', data, 24)[0]
    if e_entry > 0:
        result.ok(f"Entry point: 0x{e_entry:x}")
    else:
        result.fail("Entry point is zero")

    e_phoff = struct.unpack_from('<Q', data, 32)[0]
    e_phnum = struct.unpack_from('<H', data, 56)[0]
    e_phentsize = struct.unpack_from('<H', data, 54)[0]

    return {
        'e_entry': e_entry,
        'e_phoff': e_phoff,
        'e_phnum': e_phnum,
        'e_phentsize': e_phentsize,
    }


def test_program_headers(data, elf_info, result):
    """Validate ELF program headers and segment layout."""
    print("\n=== Program Header Tests ===")

    if elf_info is None:
        result.fail("Skipped: ELF header invalid")
        return []

    phoff = elf_info['e_phoff']
    phnum = elf_info['e_phnum']
    phentsize = elf_info['e_phentsize']

    if phnum == 0:
        result.fail("No program headers found")
        return []

    if phentsize < 56:
        result.fail("Program header entry size too small", f"{phentsize} < 56")
        return []

    result.ok(f"Program headers: {phnum} entries at offset 0x{phoff:x}")

    segments = []
    has_load = False
    for i in range(phnum):
        off = phoff + i * phentsize
        if off + 56 > len(data):
            result.fail(f"Program header {i} extends past file end")
            break

        p_type = struct.unpack_from('<I', data, off)[0]
        p_flags = struct.unpack_from('<I', data, off + 4)[0]
        p_offset = struct.unpack_from('<Q', data, off + 8)[0]
        p_vaddr = struct.unpack_from('<Q', data, off + 16)[0]
        p_paddr = struct.unpack_from('<Q', data, off + 24)[0]
        p_filesz = struct.unpack_from('<Q', data, off + 32)[0]
        p_memsz = struct.unpack_from('<Q', data, off + 40)[0]

        seg = {
            'type': p_type,
            'flags': p_flags,
            'offset': p_offset,
            'vaddr': p_vaddr,
            'paddr': p_paddr,
            'filesz': p_filesz,
            'memsz': p_memsz,
        }
        segments.append(seg)

        if p_type == 1:  # PT_LOAD
            has_load = True

    if has_load:
        result.ok("At least one PT_LOAD segment found")
    else:
        result.fail("No PT_LOAD segments found")

    load_segs = [s for s in segments if s['type'] == 1]
    for i, seg in enumerate(load_segs):
        if seg['filesz'] <= seg['memsz']:
            result.ok(f"LOAD[{i}]: filesz(0x{seg['filesz']:x}) <= memsz(0x{seg['memsz']:x})")
        else:
            result.fail(f"LOAD[{i}]: filesz > memsz",
                        f"filesz=0x{seg['filesz']:x}, memsz=0x{seg['memsz']:x}")

    return segments


def test_multiboot2_header(data, result):
    """Validate Multiboot2 header is present and correctly formed."""
    print("\n=== Multiboot2 Header Tests ===")

    magic_bytes = struct.pack('<I', MULTIBOOT2_HEADER_MAGIC)
    pos = -1
    scan_range = min(len(data), MULTIBOOT2_MAX_HEADER_OFFSET + 48)
    for offset in range(0, scan_range, 8):
        if data[offset:offset + 4] == magic_bytes:
            pos = offset
            break

    if pos < 0:
        search_all = data.find(magic_bytes)
        if search_all >= 0:
            result.fail(
                "Multiboot2 header found but PAST 32KB limit",
                f"at file offset 0x{search_all:x} ({search_all} bytes). "
                f"Must be within first {MULTIBOOT2_MAX_HEADER_OFFSET} bytes. "
                "This is likely caused by debug sections pushing LOAD segments "
                "to high file offsets. Fix: strip debug info from the bootable kernel."
            )
        else:
            result.fail("Multiboot2 header magic (0xE85250D6) not found in file")
        return pos

    result.ok(f"Multiboot2 header found at file offset 0x{pos:x} ({pos} bytes)")

    if pos < MULTIBOOT2_MAX_HEADER_OFFSET:
        result.ok(f"Header within first 32KB (at {pos} bytes < {MULTIBOOT2_MAX_HEADER_OFFSET})")
    else:
        result.fail(
            f"Header at {pos} bytes, exceeds 32KB limit",
            "GRUB cannot find the multiboot2 header"
        )

    if pos % 8 == 0:
        result.ok(f"Header 8-byte aligned (offset {pos} % 8 == 0)")
    else:
        result.fail(f"Header NOT 8-byte aligned", f"offset {pos} % 8 == {pos % 8}")

    if pos + 16 > len(data):
        result.fail("Header too close to file end for base fields")
        return pos

    magic, arch, length, checksum = struct.unpack_from('<IIII', data, pos)

    if magic == MULTIBOOT2_HEADER_MAGIC:
        result.ok(f"Magic: 0x{magic:08x}")
    else:
        result.fail(f"Magic mismatch", f"got 0x{magic:08x}")

    if arch == MULTIBOOT2_ARCH_I386:
        result.ok(f"Architecture: i386 (0) — required for x86_64 multiboot2")
    else:
        result.fail(f"Architecture invalid", f"got {arch}, expected 0 (i386)")

    if length >= 16:
        result.ok(f"Header length: {length} bytes")
    else:
        result.fail(f"Header length too small", f"{length} < 16")

    expected_checksum = (-(MULTIBOOT2_HEADER_MAGIC + arch + length)) & 0xFFFFFFFF
    if checksum == expected_checksum:
        result.ok(f"Checksum valid: 0x{checksum:08x}")
    else:
        result.fail(
            f"Checksum invalid",
            f"got 0x{checksum:08x}, expected 0x{expected_checksum:08x}"
        )

    verify_sum = (magic + arch + length + checksum) & 0xFFFFFFFF
    if verify_sum == 0:
        result.ok(f"Checksum verification: sum of fields = 0 (mod 2^32)")
    else:
        result.fail(f"Checksum verification failed", f"sum = 0x{verify_sum:08x}")

    # Parse tags
    offset = pos + 16
    end = pos + length
    tag_count = 0
    has_end_tag = False
    has_fb_tag = False

    while offset + 8 <= end and offset < len(data) - 7:
        tag_type, tag_flags = struct.unpack_from('<HH', data, offset)
        tag_size = struct.unpack_from('<I', data, offset + 4)[0]

        if tag_type == 0:
            has_end_tag = True
            break

        tag_count += 1

        if tag_type == 5:
            has_fb_tag = True
            if tag_size >= 20:
                width = struct.unpack_from('<I', data, offset + 8)[0]
                height = struct.unpack_from('<I', data, offset + 12)[0]
                depth = struct.unpack_from('<I', data, offset + 16)[0]
                result.ok(f"Framebuffer tag: {width}x{height}x{depth}")
            else:
                result.fail("Framebuffer tag too small", f"size={tag_size}")

        offset += (tag_size + 7) & ~7

    if has_end_tag:
        result.ok("End tag present")
    else:
        result.fail("End tag missing from multiboot2 header")

    if has_fb_tag:
        result.ok("Framebuffer request tag present")
    else:
        result.fail("No framebuffer request tag — desktop themes won't work")

    return pos


def test_entry_point(data, elf_info, segments, result):
    """Validate that the entry point is within a loaded segment."""
    print("\n=== Entry Point Tests ===")

    if elf_info is None:
        result.fail("Skipped: ELF header invalid")
        return

    entry = elf_info['e_entry']
    load_segs = [s for s in segments if s['type'] == 1]

    found = False
    for i, seg in enumerate(load_segs):
        seg_start = seg['vaddr']
        seg_end = seg['vaddr'] + seg['memsz']
        if seg_start <= entry < seg_end:
            flags_str = ""
            if seg['flags'] & 1:
                flags_str += "X"
            if seg['flags'] & 2:
                flags_str += "W"
            if seg['flags'] & 4:
                flags_str += "R"
            result.ok(f"Entry 0x{entry:x} is in LOAD[{i}] (0x{seg_start:x}-0x{seg_end:x}, {flags_str})")
            found = True

            if seg['flags'] & 1:
                result.ok("Entry point segment is executable")
            else:
                result.fail("Entry point segment is NOT executable")
            break

    if not found:
        result.fail(
            "Entry point not in any LOAD segment",
            f"entry=0x{entry:x}"
        )


def test_section_layout(data, result):
    """Validate critical section presence and ordering."""
    print("\n=== Section Layout Tests ===")

    if len(data) < 64:
        result.fail("File too small")
        return

    e_shoff = struct.unpack_from('<Q', data, 40)[0]
    e_shnum = struct.unpack_from('<H', data, 60)[0]
    e_shentsize = struct.unpack_from('<H', data, 58)[0]
    e_shstrndx = struct.unpack_from('<H', data, 62)[0]

    if e_shnum == 0 or e_shoff == 0:
        result.ok("No section headers (stripped binary) — OK for booting")
        return

    if e_shstrndx >= e_shnum:
        result.fail("Invalid section string table index")
        return

    strtab_off = e_shoff + e_shstrndx * e_shentsize
    if strtab_off + e_shentsize > len(data):
        result.fail("Section string table header out of bounds")
        return

    str_offset = struct.unpack_from('<Q', data, strtab_off + 24)[0]
    str_size = struct.unpack_from('<Q', data, strtab_off + 32)[0]

    if str_offset + str_size > len(data):
        result.fail("Section string table data out of bounds")
        return

    strtab = data[str_offset:str_offset + str_size]

    required_sections = {'.multiboot2', '.text'}
    expected_sections = {'.rodata', '.data', '.bss', '.uefi_vector'}
    found_sections = {}

    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + e_shentsize > len(data):
            break
        sh_name_idx = struct.unpack_from('<I', data, off)[0]
        sh_addr = struct.unpack_from('<Q', data, off + 16)[0]
        sh_offset = struct.unpack_from('<Q', data, off + 24)[0]
        sh_size = struct.unpack_from('<Q', data, off + 32)[0]

        name_end = strtab.find(b'\0', sh_name_idx)
        if name_end < 0:
            name_end = len(strtab)
        name = strtab[sh_name_idx:name_end].decode('ascii', errors='replace')

        if name:
            found_sections[name] = {
                'addr': sh_addr,
                'offset': sh_offset,
                'size': sh_size,
            }

    for sec in required_sections:
        if sec in found_sections:
            s = found_sections[sec]
            result.ok(f"Required section '{sec}' present (addr=0x{s['addr']:x}, size=0x{s['size']:x})")
        else:
            result.fail(f"Required section '{sec}' missing")

    for sec in expected_sections:
        if sec in found_sections:
            s = found_sections[sec]
            result.ok(f"Expected section '{sec}' present (addr=0x{s['addr']:x})")

    if '.multiboot2' in found_sections:
        mb_size = found_sections['.multiboot2']['size']
        if 16 <= mb_size <= 1024:
            result.ok(f"Multiboot2 section size reasonable ({mb_size} bytes)")
        else:
            result.fail(f"Multiboot2 section size suspicious", f"{mb_size} bytes")


def test_kernel_size(data, result):
    """Check kernel file size is reasonable."""
    print("\n=== File Size Tests ===")

    size = len(data)
    size_mb = size / (1024 * 1024)

    if size < 1024:
        result.fail("Kernel too small", f"{size} bytes")
    elif size > 100 * 1024 * 1024:
        result.fail("Kernel suspiciously large", f"{size_mb:.1f} MB")
    else:
        result.ok(f"Kernel size: {size_mb:.1f} MB ({size} bytes)")

    if size < 10 * 1024 * 1024:
        result.ok("Size < 10MB (good for bootable image)")
    else:
        result.fail(
            f"Kernel > 10MB ({size_mb:.1f}MB) — consider stripping debug info",
            "Debug sections inflate the file and can push the multiboot2 header "
            "past the 32KB scan limit"
        )


def test_multiboot2_boot_magic(result):
    """Verify the Multiboot2 boot magic constant used in kernel code."""
    print("\n=== Boot Magic Constant Test ===")

    expected = 0x36D76289
    result.ok(f"Expected boot magic: 0x{expected:08x}")

    magic_str = f"0x{MULTIBOOT2_BOOT_MAGIC:08x}"
    if MULTIBOOT2_BOOT_MAGIC == expected:
        result.ok(f"Boot magic constant matches spec ({magic_str})")
    else:
        result.fail(f"Boot magic mismatch", f"got {magic_str}")


def write_results(results, output_dir):
    """Write test results to JSON file."""
    os.makedirs(output_dir, exist_ok=True)

    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = os.path.join(output_dir, f'multiboot_test_{timestamp}.json')

    report = {
        'timestamp': datetime.now().isoformat(),
        'suites': [r.summary() for r in results],
        'total_passed': sum(r.passed for r in results),
        'total_failed': sum(r.failed for r in results),
    }

    with open(output_file, 'w') as f:
        json.dump(report, f, indent=2)

    print(f"\nResults written to: {output_file}")
    return output_file


def main():
    parser = argparse.ArgumentParser(description='ZirconOS Multiboot2 Kernel Tests')
    parser.add_argument('--kernel', default=None,
                        help='Path to kernel ELF (default: auto-detect)')
    parser.add_argument('--output-dir', default=RESULTS_DIR,
                        help='Directory for test result files')
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if args.kernel:
        kernel_path = args.kernel
    else:
        candidates = [
            os.path.join(project_root, 'build', 'tmp', 'kernel-prefix', 'bin', 'kernel'),
            os.path.join(project_root, 'zig-out', 'bin', 'kernel'),
        ]
        kernel_path = None
        for c in candidates:
            if os.path.exists(c):
                kernel_path = c
                break
        if kernel_path is None:
            print("ERROR: No kernel binary found. Run 'make build' first.")
            print(f"Searched: {candidates}")
            sys.exit(1)

    print(f"ZirconOS Multiboot2 Kernel Test Suite")
    print(f"Kernel: {kernel_path}")
    print(f"Size: {os.path.getsize(kernel_path)} bytes")
    print("=" * 60)

    data = read_kernel(kernel_path)

    results = []

    r = TestResult("elf_header")
    elf_info = test_elf_header(data, r)
    results.append(r)

    r = TestResult("program_headers")
    segments = test_program_headers(data, elf_info, r)
    results.append(r)

    r = TestResult("multiboot2_header")
    test_multiboot2_header(data, r)
    results.append(r)

    r = TestResult("entry_point")
    test_entry_point(data, elf_info, segments, r)
    results.append(r)

    r = TestResult("section_layout")
    test_section_layout(data, r)
    results.append(r)

    r = TestResult("kernel_size")
    test_kernel_size(data, r)
    results.append(r)

    r = TestResult("boot_magic")
    test_multiboot2_boot_magic(r)
    results.append(r)

    write_results(results, args.output_dir)

    print("\n" + "=" * 60)
    total_passed = sum(r.passed for r in results)
    total_failed = sum(r.failed for r in results)
    print(f"TOTAL: {total_passed} passed, {total_failed} failed")

    if total_failed > 0:
        print("\nFAILURES:")
        for r in results:
            for err in r.errors:
                print(f"  - [{r.name}] {err}")
        print(f"\nRESULT: FAILED")
        return 1
    else:
        print(f"\nRESULT: ALL PASSED")
        return 0


if __name__ == '__main__':
    sys.exit(main())
