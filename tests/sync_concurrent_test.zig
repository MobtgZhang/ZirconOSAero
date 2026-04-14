// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! 同步原语并发测试
//! 测试目标：1024线程并发访问无死锁、无竞争条件

const std = @import("std");
const builtin = @import("builtin");
const ke = @import("../src/ke/sync.zig");
const scheduler = @import("../src/ke/scheduler.zig");
const klog = @import("../src/rtl/klog.zig");
const ps = @import("../src/ps/process.zig");

const TEST_THREADS = 1024;
const TEST_ITERATIONS = 1000;

var test_mutex: ke.Mutex = undefined;
var test_sem: ke.Semaphore = undefined;
var test_critical_section: ke.RTL_CRITICAL_SECTION = undefined;
var test_counter: u64 = 0;
var completed_threads: u32 = 0;
var test_failed: bool = false;

fn mutexTestThread(_: usize) void {
    const tid = @as(u32, @intCast(scheduler.getCurrentThreadId()));
    var i: usize = 0;
    while (i < TEST_ITERATIONS) : (i += 1) {
        // 获取互斥锁
        while (!test_mutex.acquire(tid)) {
            scheduler.yield();
        }
        defer {
            _ = test_mutex.release(tid);
        }

        // 临界区操作
        test_counter += 1;
    }

    _ = @atomicRmw(u32, &completed_threads, .Add, 1, .seq_cst);
}

fn semaphoreTestThread(_: usize) void {
    var i: usize = 0;
    while (i < TEST_ITERATIONS) : (i += 1) {
        // 获取信号量
        while (!test_sem.acquire()) {
            scheduler.yield();
        }
        defer {
            _ = test_sem.release();
        }

        // 临界区操作
        test_counter += 1;
    }

    _ = @atomicRmw(u32, &completed_threads, .Add, 1, .seq_cst);
}

fn criticalSectionTestThread(_: usize) void {
    var i: usize = 0;
    while (i < TEST_ITERATIONS) : (i += 1) {
        // 进入临界区
        test_critical_section.enter();
        defer {
            _ = test_critical_section.leave();
        }

        // 临界区操作
        test_counter += 1;
    }

    _ = @atomicRmw(u32, &completed_threads, .Add, 1, .seq_cst);
}

fn runTest(comptime thread_fn: fn (usize) void, test_name: []const u8, expected_total: u64) bool {
    klog.info("Sync Test: Starting {} with {} threads, {} iterations per thread", .{ test_name, TEST_THREADS, TEST_ITERATIONS });

    // 重置状态
    test_counter = 0;
    completed_threads = 0;
    test_failed = false;

    // 创建测试线程
    var threads: [TEST_THREADS]u32 = undefined;
    var created: usize = 0;
    for (&threads) |*tid| {
        tid.* = scheduler.createKernelThread(thread_fn, created) orelse {
            klog.err("Sync Test: Failed to create thread {}", .{created});
            test_failed = true;
            break;
        };
        created += 1;
    }

    if (test_failed) {
        // 清理已创建的线程
        var i: usize = 0;
        while (i < created) : (i += 1) {
            scheduler.terminateThread(threads[i]);
        }
        return false;
    }

    // 等待所有线程完成
    klog.info("Sync Test: All {} threads created, waiting for completion...", .{TEST_THREADS});
    while (@atomicLoad(u32, &completed_threads, .seq_cst) < TEST_THREADS) {
        scheduler.yield();
    }

    // 验证结果
    if (test_counter != expected_total) {
        klog.err("Sync Test: {} failed! Expected counter={}, actual={}", .{ test_name, expected_total, test_counter });
        return false;
    }

    klog.info("Sync Test: {} passed! Counter={} matches expected", .{ test_name, test_counter });
    return true;
}

pub fn runSyncConcurrentTests() bool {
    klog.info("Sync Test: Starting synchronization primitives concurrent test suite", .{});
    klog.info("Sync Test: Target: {} threads, no deadlock, no race conditions", .{TEST_THREADS});

    var all_passed = true;

    // 测试互斥锁
    test_mutex = ke.Mutex.init();
    if (!runTest(mutexTestThread, "Mutex test", TEST_THREADS * TEST_ITERATIONS)) {
        all_passed = false;
    }

    // 测试信号量 (初始计数=1，相当于互斥锁)
    test_sem = ke.Semaphore.init(1, 1);
    if (!runTest(semaphoreTestThread, "Semaphore test", TEST_THREADS * TEST_ITERATIONS)) {
        all_passed = false;
    }

    // 测试临界区
    test_critical_section = ke.RTL_CRITICAL_SECTION.init(4000);
    if (!runTest(criticalSectionTestThread, "Critical Section test", TEST_THREADS * TEST_ITERATIONS)) {
        all_passed = false;
    }

    if (all_passed) {
        klog.info("Sync Test: All tests passed! Synchronization primitives are thread-safe", .{});
    } else {
        klog.err("Sync Test: Some tests failed!", .{});
    }

    return all_passed;
}
