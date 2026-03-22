#!/usr/bin/env python3
"""
ZirconOS Boot Assembly Verification Tests

Validates the x86_64 boot assembly (start.s) by checking the compiled
kernel for correct page table setup, GDT structure, and long mode transition.

Usage:
    python3 tests/test_boot_asm.py [--kernel PATH]
"""

import argparse
import os
import struct
import sys
import json
from datetime import datetime

RESULTS_DIR = os.path.join(os.path.dirname(__file__), '..', 'build', 'test-results')

# ELF e_machine (common)
EM_X86_64 = 62
EM_LOONGARCH = 258


def get_elf_machine(kernel_path: str) -> int:
    with open(kernel_path, 'rb') as f:
        hdr = f.read(20)
    if len(hdr) < 20:
        return 0
    return struct.unpack_from('<H', hdr, 18)[0]


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
    print("ERROR: No kernel binary found. Run 'make build' first.")
    sys.exit(1)


def get_symbol_table(kernel_path):
    """Parse ELF symbol table to get symbol addresses."""
    with open(kernel_path, 'rb') as f:
        data = f.read()

    if len(data) < 64:
        return {}

    e_shoff = struct.unpack_from('<Q', data, 40)[0]
    e_shnum = struct.unpack_from('<H', data, 60)[0]
    e_shentsize = struct.unpack_from('<H', data, 58)[0]

    symtab_off = 0
    symtab_size = 0
    symtab_entsize = 0
    strtab_off = 0
    strtab_size = 0

    # Find .symtab and .strtab
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + e_shentsize > len(data):
            break

        sh_type = struct.unpack_from('<I', data, off + 4)[0]
        sh_offset = struct.unpack_from('<Q', data, off + 24)[0]
        sh_size = struct.unpack_from('<Q', data, off + 32)[0]
        sh_entsize = struct.unpack_from('<Q', data, off + 56)[0]
        sh_link = struct.unpack_from('<I', data, off + 40)[0]

        if sh_type == 2:  # SHT_SYMTAB
            symtab_off = sh_offset
            symtab_size = sh_size
            symtab_entsize = sh_entsize
            # Get linked strtab
            strtab_hdr_off = e_shoff + sh_link * e_shentsize
            strtab_off = struct.unpack_from('<Q', data, strtab_hdr_off + 24)[0]
            strtab_size = struct.unpack_from('<Q', data, strtab_hdr_off + 32)[0]
            break

    if symtab_off == 0 or symtab_entsize == 0:
        return {}

    symbols = {}
    num_syms = symtab_size // symtab_entsize

    for i in range(num_syms):
        off = symtab_off + i * symtab_entsize
        if off + symtab_entsize > len(data):
            break

        st_name = struct.unpack_from('<I', data, off)[0]
        st_value = struct.unpack_from('<Q', data, off + 8)[0]
        st_size = struct.unpack_from('<Q', data, off + 16)[0]

        if st_name == 0:
            continue
        if strtab_off + st_name >= len(data):
            continue

        name_end = data.find(b'\0', strtab_off + st_name)
        if name_end < 0:
            continue
        name = data[strtab_off + st_name:name_end].decode('ascii', errors='replace')
        symbols[name] = {'value': st_value, 'size': st_size}

    return symbols


def test_key_symbols(symbols, result):
    """Verify essential boot symbols exist."""
    print("\n=== Key Symbol Tests ===")

    required = ['_start', 'kernel_main', 'stack_top', 'stack_bottom']
    for sym in required:
        if sym in symbols:
            result.ok(f"Symbol '{sym}' found at 0x{symbols[sym]['value']:x}")
        else:
            result.fail(f"Symbol '{sym}' not found")

    optional = ['_start64', 'boot_pml4', 'boot_pdpt', 'boot_pd',
                'boot_gdt', 'boot_gdt_desc', 'load_gdt_flush', 'load_tss_reg',
                'multiboot2_header', 'multiboot2_header_end']
    for sym in optional:
        if sym in symbols:
            result.ok(f"Symbol '{sym}' at 0x{symbols[sym]['value']:x}")


def test_stack_layout(symbols, result):
    """Verify kernel stack size and alignment."""
    print("\n=== Stack Layout Tests ===")

    if 'stack_bottom' not in symbols or 'stack_top' not in symbols:
        result.fail("Stack symbols missing — cannot verify stack layout")
        return

    bottom = symbols['stack_bottom']['value']
    top = symbols['stack_top']['value']

    if top > bottom:
        stack_size = top - bottom
        result.ok(f"Stack: 0x{bottom:x} - 0x{top:x} ({stack_size} bytes = {stack_size // 1024}KB)")
    else:
        result.fail("stack_top <= stack_bottom", f"top=0x{top:x}, bottom=0x{bottom:x}")
        return

    if stack_size >= 65536:
        result.ok(f"Stack size >= 64KB ({stack_size // 1024}KB)")
    else:
        result.fail(f"Stack size < 64KB", f"only {stack_size} bytes — may overflow")

    if top % 16 == 0:
        result.ok(f"Stack top 16-byte aligned (0x{top:x})")
    else:
        result.fail(f"Stack top NOT 16-byte aligned", f"0x{top:x} % 16 = {top % 16}")


def test_entry_consistency(symbols, kernel_path, result):
    """Verify ELF entry point matches _start symbol."""
    print("\n=== Entry Consistency Tests ===")

    with open(kernel_path, 'rb') as f:
        data = f.read(64)

    e_entry = struct.unpack_from('<Q', data, 24)[0]

    if '_start' in symbols:
        start_addr = symbols['_start']['value']
        if e_entry == start_addr:
            result.ok(f"ELF entry point matches _start (0x{e_entry:x})")
        else:
            result.fail(
                "ELF entry point != _start",
                f"entry=0x{e_entry:x}, _start=0x{start_addr:x}"
            )

    if '_start' in symbols and 'kernel_main' in symbols:
        start = symbols['_start']['value']
        km = symbols['kernel_main']['value']
        if start != km:
            result.ok(f"_start (0x{start:x}) != kernel_main (0x{km:x}) — correct separation")
        else:
            result.fail("_start == kernel_main — assembly trampoline may be missing")

    if '_start64' in symbols and '_start' in symbols:
        s32 = symbols['_start']['value']
        s64 = symbols['_start64']['value']
        if s64 > s32:
            result.ok(f"_start64 (0x{s64:x}) after _start (0x{s32:x})")
        else:
            result.fail("_start64 not after _start")


def test_gdt_structure(symbols, result):
    """Verify GDT symbols for long mode transition."""
    print("\n=== GDT Structure Tests ===")

    gdt_syms = ['boot_gdt', 'boot_gdt_desc', 'boot_gdt_end']
    found = 0
    for sym in gdt_syms:
        if sym in symbols:
            found += 1

    if found >= 2:
        result.ok(f"GDT symbols present ({found}/{len(gdt_syms)})")
    else:
        result.fail(f"GDT symbols missing ({found}/{len(gdt_syms)})")

    if 'boot_gdt' in symbols and 'boot_gdt_end' in symbols:
        gdt_start = symbols['boot_gdt']['value']
        gdt_end = symbols['boot_gdt_end']['value']
        gdt_size = gdt_end - gdt_start

        # Should have at least: null + code + data = 3 * 8 = 24 bytes
        if gdt_size >= 24:
            result.ok(f"GDT size: {gdt_size} bytes ({gdt_size // 8} entries)")
        else:
            result.fail(f"GDT too small", f"{gdt_size} bytes (need >= 24 for null+code+data)")

    if 'load_gdt_flush' in symbols:
        result.ok("GDT flush function present (load_gdt_flush)")
    else:
        result.fail("GDT flush function missing (load_gdt_flush)")

    if 'load_tss_reg' in symbols:
        result.ok("TSS load function present (load_tss_reg)")


def test_page_table_symbols(symbols, result):
    """Verify page table BSS symbols."""
    print("\n=== Page Table Symbol Tests ===")

    pt_syms = ['boot_pml4', 'boot_pdpt', 'boot_pd']
    for sym in pt_syms:
        if sym in symbols:
            addr = symbols[sym]['value']
            if addr % 4096 == 0:
                result.ok(f"{sym} at 0x{addr:x} (page-aligned)")
            else:
                result.fail(f"{sym} NOT page-aligned", f"0x{addr:x} % 4096 = {addr % 4096}")
        else:
            result.fail(f"Page table symbol '{sym}' not found")


def write_results(results, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    output_file = os.path.join(output_dir, f'boot_asm_test_{timestamp}.json')

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
    parser = argparse.ArgumentParser(description='ZirconOS Boot Assembly Tests')
    parser.add_argument('--kernel', default=None, help='Path to kernel ELF')
    parser.add_argument('--output-dir', default=RESULTS_DIR)
    args = parser.parse_args()

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    kernel_path = find_kernel(project_root, args.kernel)

    print(f"ZirconOS Boot Assembly Test Suite")
    print(f"Kernel: {kernel_path}")
    e_machine = get_elf_machine(kernel_path)
    print(f"ELF e_machine: {e_machine} (62=x86_64, 258=LoongArch)")
    print("=" * 60)

    symbols = get_symbol_table(kernel_path)
    if not symbols:
        print("WARNING: No symbol table found. Some tests will be skipped.")
        print("(This is normal for stripped binaries)")

    results = []

    r = TestResult("key_symbols")
    test_key_symbols(symbols, r)
    results.append(r)

    r = TestResult("stack_layout")
    test_stack_layout(symbols, r)
    results.append(r)

    r = TestResult("entry_consistency")
    test_entry_consistency(symbols, kernel_path, r)
    results.append(r)

    r = TestResult("gdt_structure")
    if e_machine == EM_X86_64:
        test_gdt_structure(symbols, r)
    else:
        r.ok("skipped (x86_64 boot assembly only)")
    results.append(r)

    r = TestResult("page_table_symbols")
    if e_machine == EM_X86_64:
        test_page_table_symbols(symbols, r)
    else:
        r.ok("skipped (x86_64 boot page tables only)")
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
        print(f"\nRESULT: ALL PASSED")
        return 0


if __name__ == '__main__':
    sys.exit(main())
