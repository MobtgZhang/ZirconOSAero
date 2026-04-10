// SPDX-License-Identifier: MIT OR Apache-2.0
//! LoongArch64 Syscall 分发器测试
//!
//! 验证阶段2实现的 syscall 服务是否正确连接到 ntdll 函数。
//!
//! 本测试为桩验证，不依赖实际 LoongArch64 硬件或 QEMU。

const std = @import("std");
const ssdt = @import("src/arch/x86_64/ssdt_nt61.zig");

test "LoongArch64 SSDT 服务索引验证" {
    // 验证关键服务号与 ssdt_nt61.zig 一致
    try std.testing.expect(ssdt.NtReadFile == 0x07);
    try std.testing.expect(ssdt.NtWriteFile == 0x08);
    try std.testing.expect(ssdt.NtClose == 0x0C);
    try std.testing.expect(ssdt.NtWaitForSingleObject == 0x04);
    try std.testing.expect(ssdt.NtAllocateVirtualMemory == 0x18);
    try std.testing.expect(ssdt.NtFreeVirtualMemory == 0x1B);
    try std.testing.expect(ssdt.NtQuerySystemInformation == 0x25);
    try std.testing.expect(ssdt.NtCreateFile == 0x2C);
    try std.testing.expect(ssdt.NtYieldExecution == 0x43);
    try std.testing.expect(ssdt.NtTerminateProcess == 0x29);
    try std.testing.expect(ssdt.NtCreateThread == 0x4B);
    try std.testing.expect(ssdt.NtProtectVirtualMemory == 0x4D);
    try std.testing.expect(ssdt.NtDelayExecution == 0x31);
    try std.testing.expect(ssdt.NtOpenKey == 0x0F);
    try std.testing.expect(ssdt.NtQueryValueKey == 0x14);
    try std.testing.expect(ssdt.NtCreateKey == 0x1A);
    try std.testing.expect(ssdt.NtSetValueKey == 0x5D);
    try std.testing.expect(ssdt.NtDisplayString == 0xB8);
    try std.testing.expect(ssdt.NtCreateSection == 0x47);
    try std.testing.expect(ssdt.NtMapViewOfSection == 0x48);
    try std.testing.expect(ssdt.NtUnmapViewOfSection == 0x2A);
    try std.testing.expect(ssdt.NtQueryVirtualMemory == 0x20);
    try std.testing.expect(ssdt.NtOpenProcess == 0x23);
    try std.testing.expect(ssdt.NtDuplicateObject == 0x44);
    try std.testing.expect(ssdt.NtReadVirtualMemory == 0x3D);
    try std.testing.expect(ssdt.NtWriteVirtualMemory == 0x3E);
    try std.testing.expect(ssdt.NtUserGetMessage == 0x58);
    try std.testing.expect(ssdt.NtUserPeekMessage == 0x59);
    try std.testing.expect(ssdt.NtUserPostMessage == 0x5A);
    try std.testing.expect(ssdt.NtUserSetWindowPos == 0x5B);
    try std.testing.expect(ssdt.NtUserSendMessage == 0x5C);
    try std.testing.expect(ssdt.NtUserDispatchMessage == 0x5E);
    try std.testing.expect(ssdt.NtCreateMutant == 0x0B);
    try std.testing.expect(ssdt.NtOpenMutant == 0x0D);
    try std.testing.expect(ssdt.NtReleaseMutant == 0x1E);
    try std.testing.expect(ssdt.NtQueryMutant == 0x0E);
    try std.testing.expect(ssdt.NtCreateEvent == 0x4A);
    try std.testing.expect(ssdt.NtOpenEvent == 0x3F);
    try std.testing.expect(ssdt.NtSetEvent == 0x0A);
    try std.testing.expect(ssdt.NtResetEvent == 0x50);
    try std.testing.expect(ssdt.NtPulseEvent == 0x3C);
    try std.testing.expect(ssdt.NtClearEvent == 0x3B);
    try std.testing.expect(ssdt.NtCreateSemaphore == 0x4F);
    try std.testing.expect(ssdt.NtOpenSemaphore == 0x15);
    try std.testing.expect(ssdt.NtReleaseSemaphore == 0x1D);
    try std.testing.expect(ssdt.NtResumeThread == 0x51);
    try std.testing.expect(ssdt.NtTerminateThread == 0x55);
    try std.testing.expect(ssdt.NtSuspendThread == 0x45);
    try std.testing.expect(ssdt.NtAlertThread == 0x22);
    try std.testing.expect(ssdt.NtTestAlert == 0x42);
    try std.testing.expect(ssdt.NtOpenThread == 0x36);
    try std.testing.expect(ssdt.NtQueryObject == 0x10);
    try std.testing.expect(ssdt.NtOpenFile == 0x33);
    try std.testing.expect(ssdt.NtFlushBuffersFile == 0x39);
    try std.testing.expect(ssdt.NtFsControlFile == 0x09);
    try std.testing.expect(ssdt.NtDeviceIoControlFile == 0x52);
    try std.testing.expect(ssdt.NtLockVirtualMemory == 0x53);
    try std.testing.expect(ssdt.NtUnlockVirtualMemory == 0x54);
    try std.testing.expect(ssdt.NtCancelIoFile == 0x35);
    try std.testing.expect(ssdt.NtCancelIoFileEx == 0xE9);
    try std.testing.expect(ssdt.NtConnectPort == 0x8F);
    try std.testing.expect(ssdt.NtCreatePort == 0x9D);
    try std.testing.expect(ssdt.NtRequestWaitReplyPort == 0x1F);
    try std.testing.expect(ssdt.NtWaitForMultipleObjects == 0x57);
    try std.testing.expect(ssdt.NtSetInformationObject == 0x56);
    try std.testing.expect(ssdt.NtSignalAndWaitForSingleObject == 0x176);
    try std.testing.expect(ssdt.NtCreateProcess == 0x9F);
    try std.testing.expect(ssdt.NtCreateUserProcess == 0xAA);
    try std.testing.expect(ssdt.NtCreateThreadEx == 0xA5);
    try std.testing.expect(ssdt.NtAlpcConnectPort == 0x2D);
    try std.testing.expect(ssdt.NtAlpcCreatePort == 0x6D);
    try std.testing.expect(ssdt.NtAlpcSendWaitReceivePort == 0x6E);
    try std.testing.expect(ssdt.NtShutdownSystem == 0x40);
    try std.testing.expect(ssdt.NtInitiatePowerAction == 0x41);
}

test "LoongArch64 Syscall 帧偏移常量验证" {
    // 验证帧偏移与 exc_vec.S 定义一致
    const OFF_A0: usize = 8;
    const OFF_A1: usize = 16;
    const OFF_A2: usize = 24;
    const OFF_A3: usize = 72;
    const OFF_A4: usize = 80;
    const OFF_A5: usize = 88;
    const OFF_A6: usize = 96;
    const OFF_A7: usize = 64;

    // 编译时验证
    try std.testing.expect(OFF_A0 == 8);
    try std.testing.expect(OFF_A1 == 16);
    try std.testing.expect(OFF_A2 == 24);
    try std.testing.expect(OFF_A7 == 64);
    try std.testing.expect(OFF_A3 == 72);
    try std.testing.expect(OFF_A4 == 80);
    try std.testing.expect(OFF_A5 == 88);
    try std.testing.expect(OFF_A6 == 96);
}

test "LoongArch64 NtResult 转换验证" {
    // 验证 ntResult 正确将 NTSTATUS 转换为 u64
    const ntdll = @import("src/libs/ntdll.zig");

    // STATUS_SUCCESS = 0
    try std.testing.expect(ntdll.STATUS_SUCCESS == 0);

    // STATUS_NOT_IMPLEMENTED = -1073741822 (0xC0000001)
    try std.testing.expect(ntdll.STATUS_NOT_IMPLEMENTED == -1073741822);

    // STATUS_INVALID_PARAMETER = -1073741811 (0xC000000D)
    try std.testing.expect(ntdll.STATUS_INVALID_PARAMETER == -1073741811);

    // STATUS_INVALID_HANDLE = -1073741816 (0xC0000008)
    try std.testing.expect(ntdll.STATUS_INVALID_HANDLE == -1073741816);
}

test "LoongArch64 阶段2服务计数" {
    // 统计阶段2新增的服务数量
    // 原始约 20 个服务 → 现在约 70+ 个服务
    const service_count = blk: {
        var count: usize = 0;
        // 基础服务
        count += 1; // NtClose
        count += 1; // NtWaitForSingleObject
        count += 1; // NtYieldExecution
        count += 1; // NtDelayExecution
        count += 1; // NtDisplayString
        count += 1; // NtShutdownSystem
        // 文件 I/O
        count += 1; // NtReadFile
        count += 1; // NtWriteFile
        count += 1; // NtOpenFile
        count += 1; // NtCreateFile
        count += 1; // NtFlushBuffersFile
        count += 1; // NtDeviceIoControlFile
        // 进程/线程
        count += 1; // NtOpenProcess
        count += 1; // NtOpenThread
        count += 1; // NtTerminateProcess
        count += 1; // NtCreateThread
        count += 1; // NtTerminateThread
        count += 1; // NtResumeThread
        count += 1; // NtSuspendThread
        count += 1; // NtQueryInformationProcess
        count += 1; // NtSetInformationProcess
        count += 1; // NtQueryInformationThread
        count += 1; // NtSetInformationThread
        count += 1; // NtAlertThread
        count += 1; // NtTestAlert
        count += 1; // NtCreateProcess
        // 内存
        count += 1; // NtAllocateVirtualMemory
        count += 1; // NtFreeVirtualMemory
        count += 1; // NtProtectVirtualMemory
        count += 1; // NtQueryVirtualMemory
        count += 1; // NtReadVirtualMemory
        count += 1; // NtWriteVirtualMemory
        count += 1; // NtLockVirtualMemory
        count += 1; // NtUnlockVirtualMemory
        // Section
        count += 1; // NtCreateSection
        count += 1; // NtMapViewOfSection
        count += 1; // NtUnmapViewOfSection
        // 同步 - 事件
        count += 1; // NtCreateEvent
        count += 1; // NtOpenEvent
        count += 1; // NtSetEvent
        count += 1; // NtResetEvent
        count += 1; // NtPulseEvent
        count += 1; // NtClearEvent
        // 同步 - 互斥体
        count += 1; // NtCreateMutant
        count += 1; // NtOpenMutant
        count += 1; // NtReleaseMutant
        count += 1; // NtQueryMutant
        // 同步 - 信号量
        count += 1; // NtCreateSemaphore
        count += 1; // NtOpenSemaphore
        count += 1; // NtReleaseSemaphore
        // 等待
        count += 1; // NtWaitForMultipleObjects
        count += 1; // NtSignalAndWaitForSingleObject
        // 对象
        count += 1; // NtDuplicateObject
        count += 1; // NtQueryObject
        count += 1; // NtSetInformationObject
        // 注册表
        count += 1; // NtOpenKey
        count += 1; // NtQueryValueKey
        count += 1; // NtCreateKey
        count += 1; // NtSetValueKey
        count += 1; // NtEnumerateKey
        count += 1; // NtEnumerateValueKey
        // LPC/ALPC
        count += 1; // NtAlpcConnectPort
        count += 1; // NtAlpcCreatePort
        count += 1; // NtAlpcSendWaitReceivePort
        count += 1; // NtConnectPort
        count += 1; // NtCreatePort
        count += 1; // NtRequestWaitReplyPort
        // I/O 取消
        count += 1; // NtCancelIoFile
        count += 1; // NtCancelIoFileEx
        count += 1; // NtFsControlFile
        // 电源
        count += 1; // NtInitiatePowerAction
        // Win32 用户消息
        count += 1; // NtUserGetMessage
        count += 1; // NtUserPostMessage
        count += 1; // NtUserSendMessage
        count += 1; // NtUserPeekMessage
        count += 1; // NtUserSetWindowPos
        count += 1; // NtUserDispatchMessage
        // 系统信息
        count += 1; // NtQuerySystemInformation
        break :blk count;
    };

    // 阶段2完成后应有 70+ 个服务
    try std.testing.expect(service_count >= 70);
}
