#!/usr/bin/env python3
"""
ZirconOS Test Runner — runs all verification tests.

Test categories:
  1. Kernel ELF tests      (require built kernel)
  2. Build config tests    (no kernel needed)
  3. Boot combination tests (no kernel needed)

Usage:
    python3 tests/run_all.py [--kernel PATH] [--output-dir DIR] [--project-root DIR]
    python3 tests/run_all.py --suite config        # config tests only
    python3 tests/run_all.py --suite boot           # boot combo tests only
    python3 tests/run_all.py --suite kernel         # kernel tests only
    python3 tests/run_all.py --suite all            # everything (default)

Test results are written to build/test-results/ as JSON files.
Exit code is 0 if all tests pass, 1 otherwise.
"""

import argparse
import importlib.util
import os
import sys
import json
from datetime import datetime

TEST_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(TEST_DIR)
DEFAULT_OUTPUT_DIR = os.path.join(PROJECT_ROOT, 'build', 'test-results')

KERNEL_TEST_MODULES = [
    'test_multiboot',
    'test_boot_asm',
    'test_linker',
]

CONFIG_TEST_MODULES = [
    'test_build_config',
]

BOOT_TEST_MODULES = [
    'test_boot_combinations',
]


def find_kernel(explicit_path=None):
    if explicit_path:
        return explicit_path
    candidates = [
        os.path.join(PROJECT_ROOT, 'build', 'tmp', 'kernel-prefix', 'bin', 'kernel'),
        os.path.join(PROJECT_ROOT, 'build', 'tmp', 'kernel.elf'),
        os.path.join(PROJECT_ROOT, 'zig-out', 'bin', 'kernel'),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def run_test_module(module_name, argv_override, output_dir):
    """Run a single test module and return its exit code."""
    module_path = os.path.join(TEST_DIR, f'{module_name}.py')
    if not os.path.exists(module_path):
        print(f"  WARNING: {module_path} not found, skipping")
        return 0

    spec = importlib.util.spec_from_file_location(module_name, module_path)
    mod = importlib.util.module_from_spec(spec)

    old_argv = sys.argv
    sys.argv = argv_override

    try:
        spec.loader.exec_module(mod)
        ret = mod.main()
    except SystemExit as e:
        ret = e.code if e.code is not None else 0
    except Exception as e:
        print(f"  ERROR running {module_name}: {e}")
        ret = 2
    finally:
        sys.argv = old_argv

    return ret


def main():
    parser = argparse.ArgumentParser(description='ZirconOS Test Runner')
    parser.add_argument('--kernel', default=None, help='Path to kernel ELF')
    parser.add_argument('--output-dir', default=DEFAULT_OUTPUT_DIR)
    parser.add_argument('--project-root', default=PROJECT_ROOT)
    parser.add_argument('--suite', default='all',
                        choices=['all', 'kernel', 'config', 'boot'],
                        help='Which test suite(s) to run')
    args = parser.parse_args()

    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)

    print("=" * 70)
    print("  ZirconOS Test Suite")
    print(f"  Project: {args.project_root}")
    print(f"  Output:  {output_dir}")
    print(f"  Suite:   {args.suite}")
    print("=" * 70)

    total_ret = 0
    module_results = []

    # ── Config tests (no kernel needed) ──
    if args.suite in ('all', 'config'):
        for module_name in CONFIG_TEST_MODULES:
            print(f"\n{'─' * 70}")
            print(f"  Running: {module_name}")
            print(f"{'─' * 70}")

            argv = [
                os.path.join(TEST_DIR, f'{module_name}.py'),
                '--project-root', args.project_root,
                '--output-dir', output_dir,
            ]
            ret = run_test_module(module_name, argv, output_dir)
            module_results.append({
                'module': module_name,
                'category': 'config',
                'exit_code': ret,
                'status': 'PASSED' if ret == 0 else 'FAILED',
            })
            if ret != 0:
                total_ret = 1

    # ── Boot combination tests (no kernel needed) ──
    if args.suite in ('all', 'boot'):
        for module_name in BOOT_TEST_MODULES:
            print(f"\n{'─' * 70}")
            print(f"  Running: {module_name}")
            print(f"{'─' * 70}")

            argv = [
                os.path.join(TEST_DIR, f'{module_name}.py'),
                '--project-root', args.project_root,
                '--output-dir', output_dir,
            ]
            ret = run_test_module(module_name, argv, output_dir)
            module_results.append({
                'module': module_name,
                'category': 'boot',
                'exit_code': ret,
                'status': 'PASSED' if ret == 0 else 'FAILED',
            })
            if ret != 0:
                total_ret = 1

    # ── Kernel tests (require built kernel) ──
    if args.suite in ('all', 'kernel'):
        kernel_path = find_kernel(args.kernel)
        if kernel_path is None:
            print("\nWARNING: No kernel binary found. Skipping kernel tests.")
            print("  Run 'make build' first to enable kernel verification tests.")
            for module_name in KERNEL_TEST_MODULES:
                module_results.append({
                    'module': module_name,
                    'category': 'kernel',
                    'exit_code': -1,
                    'status': 'SKIPPED',
                })
        else:
            print(f"\n  Kernel: {kernel_path}")
            print(f"  Size:   {os.path.getsize(kernel_path)} bytes")

            for module_name in KERNEL_TEST_MODULES:
                print(f"\n{'─' * 70}")
                print(f"  Running: {module_name}")
                print(f"{'─' * 70}")

                argv = [
                    os.path.join(TEST_DIR, f'{module_name}.py'),
                    '--kernel', kernel_path,
                    '--output-dir', output_dir,
                ]
                ret = run_test_module(module_name, argv, output_dir)
                module_results.append({
                    'module': module_name,
                    'category': 'kernel',
                    'exit_code': ret,
                    'status': 'PASSED' if ret == 0 else 'FAILED',
                })
                if ret != 0:
                    total_ret = 1

    # ── Summary ──
    summary = {
        'timestamp': datetime.now().isoformat(),
        'project_root': args.project_root,
        'suite': args.suite,
        'modules': module_results,
        'overall_status': 'PASSED' if total_ret == 0 else 'FAILED',
    }

    summary_file = os.path.join(output_dir, 'summary.json')
    with open(summary_file, 'w') as f:
        json.dump(summary, f, indent=2)

    print(f"\n{'=' * 70}")
    print("  OVERALL RESULTS")
    print(f"{'=' * 70}")

    for cat in ['config', 'boot', 'kernel']:
        cat_mods = [m for m in module_results if m.get('category') == cat]
        if cat_mods:
            print(f"\n  [{cat.upper()}]")
            for mr in cat_mods:
                icon = {"PASSED": "PASS", "FAILED": "FAIL", "SKIPPED": "SKIP"}.get(mr['status'], '????')
                print(f"    [{icon}] {mr['module']}")

    passed = sum(1 for m in module_results if m['status'] == 'PASSED')
    failed = sum(1 for m in module_results if m['status'] == 'FAILED')
    skipped = sum(1 for m in module_results if m['status'] == 'SKIPPED')

    overall = "ALL PASSED" if total_ret == 0 else "SOME TESTS FAILED"
    print(f"\n  {overall} ({passed} passed, {failed} failed, {skipped} skipped)")
    print(f"  Summary: {summary_file}")
    print(f"{'=' * 70}")

    return total_ret


if __name__ == '__main__':
    sys.exit(main())
