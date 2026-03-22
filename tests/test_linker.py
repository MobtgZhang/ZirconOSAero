#!/usr/bin/env python3
"""
ZirconOS Linker Script & ELF Layout Verification Tests

Validates that the linker produces a correct ELF layout for booting,
including segment ordering, alignment, and address space configuration.

Usage:
    python3 tests/test_linker.py [--kernel PATH]
"""

import argparse
import os
import struct
import sys
import json
from datetime import datetime

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
        return {
            "suite": self.name,
            "total": self.passed + self.failed,
            "passed": self.passed,
            "failed": self.failed,
            "status": "PASSED" if self.failed == 0 else "FAILED",
            "errors": self.errors,
        }


def find_kernel(project_root, explicit_path=None):
    if explicit_path:
        return explicit_path
    candidates = [
        os.path.join(project_root, 'build', 'tmp', 'kernel-prefix', 'bin', 'kernel'),
        os.path.join(project_root, 'zig-out', 'bin', 'kernel'),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    print("ERROR: No kernel binary found.")
    sys.exit(1)


def parse_elf_segments(data):
    """Parse ELF program headers."""
    e_phoff = struct.unpack_from('<Q', data, 32)[0]
    e_phnum = struct.unpack_from('<H', data, 56)[0]
    e_phentsize = struct.unpack_from('<H', data, 54)[0]

    segments = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 56 > len(data):
            break
        seg = {
            'type': struct.unpack_from('<I', data, off)[0],
            'flags': struct.unpack_from('<I', data, off + 4)[0],
            'offset': struct.unpack_from('<Q', data, off + 8)[0],
            'vaddr': struct.unpack_from('<Q', data, off + 16)[0],
            'paddr': struct.unpack_from('<Q', data, off + 24)[0],
            'filesz': struct.unpack_from('<Q', data, off + 32)[0],
            'memsz': struct.unpack_from('<Q', data, off + 40)[0],
            'align': struct.unpack_from('<Q', data, off + 48)[0],
        }
        segments.append(seg)
    return segments


def test_segment_alignment(segments, result):
    """Verify LOAD segments are page-aligned."""
    print("\n=== Segment Alignment Tests ===")

    load_segs = [s for s in segments if s['type'] == 1]

    for i, seg in enumerate(load_segs):
        if seg['vaddr'] % 0x1000 == 0:
            result.ok(f"LOAD[{i}] vaddr 0x{seg['vaddr']:x} page-aligned")
        else:
            result.fail(f"LOAD[{i}] vaddr NOT page-aligned",
                        f"0x{seg['vaddr']:x} % 0x1000 = 0x{seg['vaddr'] % 0x1000:x}")

        if seg['offset'] % 0x1000 == 0:
            result.ok(f"LOAD[{i}] file offset 0x{seg['offset']:x} page-aligned")
        else:
            result.fail(f"LOAD[{i}] file offset NOT page-aligned",
                        f"0x{seg['offset']:x}")


def test_segment_permissions(segments, result):
    """Verify expected permission flags on segments."""
    print("\n=== Segment Permission Tests ===")

    load_segs = [s for s in segments if s['type'] == 1]
    has_r = False
    has_rx = False
    has_rw = False

    for seg in load_segs:
        flags = seg['flags']
        r = bool(flags & 4)
        w = bool(flags & 2)
        x = bool(flags & 1)
        perm = ('R' if r else '') + ('W' if w else '') + ('X' if x else '')

        if r and not w and not x:
            has_r = True
        elif r and x and not w:
            has_rx = True
        elif r and w and not x:
            has_rw = True

    if has_r:
        result.ok("Read-only segment present (for rodata, multiboot2)")
    else:
        result.fail("No read-only segment found")

    if has_rx:
        result.ok("Read+Execute segment present (for .text)")
    else:
        result.fail("No read+execute segment found")

    if has_rw:
        result.ok("Read+Write segment present (for .data, .bss)")
    else:
        result.fail("No read+write segment found")


def test_segment_no_overlap(segments, result):
    """Verify LOAD segments don't overlap in virtual address space."""
    print("\n=== Segment Overlap Tests ===")

    load_segs = sorted([s for s in segments if s['type'] == 1], key=lambda s: s['vaddr'])

    for i in range(len(load_segs) - 1):
        cur = load_segs[i]
        nxt = load_segs[i + 1]
        cur_end = cur['vaddr'] + cur['memsz']

        if cur_end <= nxt['vaddr']:
            result.ok(f"LOAD[{i}] ends at 0x{cur_end:x}, LOAD[{i + 1}] starts at 0x{nxt['vaddr']:x} — no overlap")
        else:
            result.fail(
                f"LOAD segments overlap",
                f"[{i}] ends at 0x{cur_end:x}, [{i + 1}] starts at 0x{nxt['vaddr']:x}"
            )


def test_bss_memsz(segments, result):
    """Verify BSS segment has memsz > filesz (zero-initialized data)."""
    print("\n=== BSS/Data Segment Tests ===")

    load_segs = [s for s in segments if s['type'] == 1]
    found_bss_like = False

    for i, seg in enumerate(load_segs):
        if seg['memsz'] > seg['filesz']:
            found_bss_like = True
            bss_size = seg['memsz'] - seg['filesz']
            result.ok(f"LOAD[{i}] has {bss_size} bytes BSS (memsz=0x{seg['memsz']:x} > filesz=0x{seg['filesz']:x})")

    if found_bss_like:
        result.ok("BSS section present (zero-initialized data for page tables, stack, etc.)")
    else:
        result.fail("No segment with memsz > filesz — BSS may be missing")


def test_multiboot_in_early_segment(data, segments, result):
    """Verify multiboot2 section is in a segment with low file offset."""
    print("\n=== Multiboot2 Placement Tests ===")

    magic = struct.pack('<I', 0xE85250D6)
    pos = data.find(magic, 0, min(len(data), 0x100000))

    if pos < 0:
        result.fail("Multiboot2 header not found in first 1MB")
        return

    load_segs = [s for s in segments if s['type'] == 1]

    for i, seg in enumerate(load_segs):
        if seg['offset'] <= pos < seg['offset'] + seg['filesz']:
            result.ok(f"Multiboot2 header (offset 0x{pos:x}) is in LOAD[{i}] (offset 0x{seg['offset']:x})")

            if seg['offset'] < 0x8000:
                result.ok(f"Containing segment starts within 32KB (offset 0x{seg['offset']:x})")
            else:
                result.fail(
                    f"Containing segment starts past 32KB",
                    f"offset 0x{seg['offset']:x}. Strip debug info to fix."
                )
            return

    result.fail(f"Multiboot2 header (offset 0x{pos:x}) not in any LOAD segment")


def test_kernel_address_range(segments, result):
    """Verify kernel loads to a reasonable physical address range."""
    print("\n=== Address Range Tests ===")

    load_segs = [s for s in segments if s['type'] == 1]
    if not load_segs:
        result.fail("No LOAD segments")
        return

    min_paddr = min(s['paddr'] for s in load_segs)
    max_paddr = max(s['paddr'] + s['memsz'] for s in load_segs)
    total_size = max_paddr - min_paddr

    result.ok(f"Kernel address range: 0x{min_paddr:x} - 0x{max_paddr:x}")
    result.ok(f"Total address span: {total_size / (1024 * 1024):.1f} MB")

    if min_paddr >= 0x100000:
        result.ok(f"Kernel base >= 1MB (0x{min_paddr:x}) — above real mode memory")
    else:
        result.fail(f"Kernel base < 1MB (0x{min_paddr:x}) — may conflict with BIOS/real mode")

    if max_paddr < 0x40000000:
        result.ok(f"Kernel end < 1GB — fits in typical memory layout")
    else:
        result.fail(f"Kernel end >= 1GB", f"0x{max_paddr:x}")


def write_results(results, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = os.path.join(output_dir, f'linker_test_{timestamp}.json')

    report = {
        'timestamp': datetime.now().isoformat(),
        'suites': [r.summary() for r in results],
        'total_passed': sum(r.passed for r in results),
        'total_failed': sum(r.failed for r in results),
    }

    with open(output_file, 'w') as f:
        json.dump(report, f, indent=2)

    print(f"\nResults written to: {output_file}")


def main():
    parser = argparse.ArgumentParser(description='ZirconOS Linker Layout Tests')
    parser.add_argument('--kernel', default=None)
    parser.add_argument('--output-dir', default=RESULTS_DIR)
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    kernel_path = find_kernel(project_root, args.kernel)

    print(f"ZirconOS Linker Layout Test Suite")
    print(f"Kernel: {kernel_path}")
    print("=" * 60)

    with open(kernel_path, 'rb') as f:
        data = f.read()

    segments = parse_elf_segments(data)

    results = []

    r = TestResult("segment_alignment")
    test_segment_alignment(segments, r)
    results.append(r)

    r = TestResult("segment_permissions")
    test_segment_permissions(segments, r)
    results.append(r)

    r = TestResult("segment_overlap")
    test_segment_no_overlap(segments, r)
    results.append(r)

    r = TestResult("bss_memsz")
    test_bss_memsz(segments, r)
    results.append(r)

    r = TestResult("multiboot_placement")
    test_multiboot_in_early_segment(data, segments, r)
    results.append(r)

    r = TestResult("address_range")
    test_kernel_address_range(segments, r)
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
        return 1
    else:
        print("\nRESULT: ALL PASSED")
        return 0


if __name__ == '__main__':
    sys.exit(main())
