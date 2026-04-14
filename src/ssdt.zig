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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ssdt.zig
// Purpose: System Service Descriptor Table implementation, NT 6.1 compatible syscall interface
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/system-services
//      Public NT 6.1 syscall ABI documentation
//      Windows Research Kernel public header definitions

const std = @import("std");
const klog = @import("./rtl/klog.zig");
const mm = @import("./mm/mm.zig");
const ps = @import("./ps/process.zig");
const io = @import("./io/io.zig");
const vm = @import("./mm/vm.zig");
const vad = @import("./mm/vad.zig");
const ob = @import("./ob/object.zig");

/// NT syscall service function signature
pub const SyscallHandlerFn = *const fn (argc: u64, args: *const [6]u64) io.NTSTATUS;

/// Maximum number of system services (compatible with NT 6.1 limit)
pub const MAX_SYSCALLS: usize = 1024;

/// Maximum number of shadow system services for Win32k
pub const MAX_SHADOW_SYSCALLS: usize = 1024;

/// System Service Descriptor Table entry
pub const SsdtEntry = struct {
    handler: ?SyscallHandlerFn = null,
    argument_count: u8 = 0,
    /// Size of arguments in bytes
    argument_size: u16 = 0,
    name: []const u8 = "",
};

/// System Service Descriptor Table structure
pub const Ssdt = struct {
    entries: [MAX_SYSCALLS]SsdtEntry = [_]SsdtEntry{.{}} ** MAX_SYSCALLS,
    count: usize = 0,
    max: usize = MAX_SYSCALLS,
};

/// Shadow SSDT for Win32k GUI syscalls
pub const ShadowSsdt = struct {
    entries: [MAX_SHADOW_SYSCALLS]SsdtEntry = [_]SsdtEntry{.{}} ** MAX_SHADOW_SYSCALLS,
    count: usize = 0,
    max: usize = MAX_SHADOW_SYSCALLS,
};

/// Global SSDT instance
var main_ssdt: Ssdt = .{};
var shadow_ssdt: ShadowSsdt = .{};
var ssdt_initialized: bool = false;

/// Syscall argument validation flags
pub const ArgValidationFlags = enum(u32) {
    none = 0,
    read_access = 1 << 0,
    write_access = 1 << 1,
    probe_for_write = 1 << 2,
    allow_null = 1 << 3,
};

/// Validate a user pointer for safe access
pub fn probeUserPointer(ptr: u64, size: usize, flags: ArgValidationFlags) bool {
    if (ptr == 0) {
        return (flags & .allow_null) != 0;
    }

    // Check if pointer is in user address space (below 0x800000000000 for x64)
    if (ptr >= 0x800000000000) {
        return false;
    }

    // Validate memory range is valid and accessible
    if (!mm.isValidUserRange(ptr, size)) {
        return false;
    }

    // Check access permissions
    if ((flags & .write_access) != 0 or (flags & .probe_for_write) != 0) {
        if (!mm.isRangeWritable(ptr, size)) {
            return false;
        }
    } else if ((flags & .read_access) != 0) {
        if (!mm.isRangeReadable(ptr, size)) {
            return false;
        }
    }

    return true;
}

/// Copy data from user space to kernel space safely
pub fn copyFromUser(dest: *anyopaque, src: u64, size: usize) io.NTSTATUS {
    if (!probeUserPointer(src, size, .{ .read_access = true })) {
        return io.STATUS_INVALID_PARAMETER;
    }

    const src_ptr: *const [*]u8 = @ptrFromInt(src);
    const dest_ptr: *[*]u8 = @ptrCast(dest);
    @memcpy(dest_ptr[0..size], src_ptr[0..size]);
    return io.STATUS_SUCCESS;
}

/// Copy data from kernel space to user space safely
pub fn copyToUser(dest: u64, src: *const anyopaque, size: usize) io.NTSTATUS {
    if (!probeUserPointer(dest, size, .{ .write_access = true })) {
        return io.STATUS_INVALID_PARAMETER;
    }

    const dest_ptr: *[*]u8 = @ptrFromInt(dest);
    const src_ptr: *const [*]u8 = @ptrCast(src);
    @memcpy(dest_ptr[0..size], src_ptr[0..size]);
    return io.STATUS_SUCCESS;
}

/// Register a system call handler in SSDT
pub fn registerSyscall(syscall_num: u32, handler: SyscallHandlerFn, arg_count: u8, arg_size: u16, name: []const u8) io.NTSTATUS {
    if (syscall_num >= MAX_SYSCALLS) {
        return io.STATUS_INVALID_PARAMETER;
    }

    if (main_ssdt.entries[syscall_num].handler != null) {
        klog.warning("SSDT: Syscall 0x%x already registered, overwriting", .{syscall_num});
    }

    main_ssdt.entries[syscall_num] = .{
        .handler = handler,
        .argument_count = arg_count,
        .argument_size = arg_size,
        .name = name,
    };

    if (syscall_num >= main_ssdt.count) {
        main_ssdt.count = syscall_num + 1;
    }

    klog.debug("SSDT: Registered syscall 0x%x (%s) with %d arguments", .{ syscall_num, name, arg_count });
    return io.STATUS_SUCCESS;
}

/// Register a shadow system call handler for Win32k
pub fn registerShadowSyscall(syscall_num: u32, handler: SyscallHandlerFn, arg_count: u8, arg_size: u16, name: []const u8) io.NTSTATUS {
    if (syscall_num >= MAX_SHADOW_SYSCALLS) {
        return io.STATUS_INVALID_PARAMETER;
    }

    shadow_ssdt.entries[syscall_num] = .{
        .handler = handler,
        .argument_count = arg_count,
        .argument_size = arg_size,
        .name = name,
    };

    if (syscall_num >= shadow_ssdt.count) {
        shadow_ssdt.count = syscall_num + 1;
    }

    klog.debug("SSDT: Registered shadow syscall 0x%x (%s)", .{ syscall_num, name });
    return io.STATUS_SUCCESS;
}

/// Dispatch a system call from architecture specific entry point
pub fn dispatchSyscall(syscall_num: u32, argc: u64, args: *const [6]u64) io.NTSTATUS {
    if (!ssdt_initialized) {
        return io.STATUS_NOT_IMPLEMENTED;
    }

    if (syscall_num >= main_ssdt.max) {
        klog.warning("SSDT: Invalid syscall number 0x%x", .{syscall_num});
        return io.STATUS_INVALID_SYSTEM_SERVICE;
    }

    const entry = &main_ssdt.entries[syscall_num];
    if (entry.handler == null) {
        klog.warning("SSDT: Unimplemented syscall 0x%x", .{syscall_num});
        return io.STATUS_NOT_IMPLEMENTED;
    }

    // Validate argument count
    if (argc < entry.argument_count) {
        klog.warning("SSDT: Syscall 0x%x expects %d arguments, got %d", .{ syscall_num, entry.argument_count, argc });
        return io.STATUS_INVALID_PARAMETER;
    }

    // Call the handler
    return entry.handler.?(argc, args);
}

/// Dispatch a shadow system call (Win32k)
pub fn dispatchShadowSyscall(syscall_num: u32, argc: u64, args: *const [6]u64) io.NTSTATUS {
    if (syscall_num >= shadow_ssdt.max) {
        return io.STATUS_INVALID_SYSTEM_SERVICE;
    }

    const entry = &shadow_ssdt.entries[syscall_num];
    if (entry.handler == null) {
        return io.STATUS_NOT_IMPLEMENTED;
    }

    if (argc < entry.argument_count) {
        return io.STATUS_INVALID_PARAMETER;
    }

    return entry.handler.?(argc, args);
}

/// Architecture specific syscall entry point for x86_64
export fn syscall_entry_x64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.C) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    const status = dispatchSyscall(@intCast(syscall_num), 6, &args);
    return @bitCast(status);
}

/// Architecture specific syscall entry point for ARM64
export fn syscall_entry_arm64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64, arg8: u64) callconv(.C) u64 {
    _ = arg7;
    _ = arg8;
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    const status = dispatchSyscall(@intCast(syscall_num), 6, &args);
    return @bitCast(status);
}

/// Architecture specific syscall entry point for LoongArch64
export fn syscall_entry_loongarch64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.C) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    const status = dispatchSyscall(@intCast(syscall_num), 6, &args);
    return @bitCast(status);
}

/// Architecture specific syscall entry point for RISC-V64
export fn syscall_entry_riscv64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.C) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    const status = dispatchSyscall(@intCast(syscall_num), 6, &args);
    return @bitCast(status);
}

/// Get syscall name by number for debugging
pub fn getSyscallName(syscall_num: u32) []const u8 {
    if (syscall_num >= main_ssdt.max) {
        return "INVALID_SYSCALL";
    }
    const entry = &main_ssdt.entries[syscall_num];
    if (entry.name.len == 0) {
        return "UNNAMED_SYSCALL";
    }
    return entry.name;
}

/// Initialize SSDT subsystem and register core system calls
pub fn init() void {
    main_ssdt = .{};
    shadow_ssdt = .{};
    ssdt_initialized = true;

    // Register base system call stubs (will be filled by respective modules)
    // Ob system calls
    _ = registerSyscall(0x0002, &NtCloseStub, 1, 8, "NtClose");
    _ = registerSyscall(0x0003, &NtQueryObjectStub, 5, 40, "NtQueryObject");

    // Process/Thread system calls
    _ = registerSyscall(0x0030, &NtCreateProcessStub, 10, 80, "NtCreateProcess");
    _ = registerSyscall(0x0031, &NtCreateThreadStub, 9, 72, "NtCreateThread");
    _ = registerSyscall(0x0033, &NtOpenProcessStub, 5, 40, "NtOpenProcess");
    _ = registerSyscall(0x0034, &NtTerminateProcessStub, 2, 16, "NtTerminateProcess");

    // Memory system calls
    _ = registerSyscall(0x0018, &NtAllocateVirtualMemoryStub, 6, 48, "NtAllocateVirtualMemory");
    _ = registerSyscall(0x001A, &NtFreeVirtualMemoryStub, 4, 32, "NtFreeVirtualMemory");
    _ = registerSyscall(0x0050, &NtProtectVirtualMemoryStub, 4, 32, "NtProtectVirtualMemory");
    _ = registerSyscall(0x0028, &NtMapViewOfSectionStub, 10, 80, "NtMapViewOfSection");

    // I/O system calls
    _ = registerSyscall(0x0004, &NtCreateFileStub, 11, 88, "NtCreateFile");
    _ = registerSyscall(0x0007, &NtReadFileStub, 9, 72, "NtReadFile");
    _ = registerSyscall(0x0008, &NtWriteFileStub, 9, 72, "NtWriteFile");
    _ = registerSyscall(0x000E, &NtDeviceIoControlFileStub, 10, 80, "NtDeviceIoControlFile");
    _ = registerSyscall(0x0009, &NtCancelIoFileStub, 2, 16, "NtCancelIoFile");
    _ = registerSyscall(0x0010, &NtCreateIoCompletionPortStub, 4, 32, "NtCreateIoCompletionPort");

    klog.info("SSDT: Initialized with %d registered system calls", .{main_ssdt.count});
}

// System call stub implementations
fn NtCloseStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    const handle = args[0];
    klog.debug("NtClose called with handle 0x%x", .{handle});
    // TODO: Implement proper handle closing
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtQueryObjectStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtCreateProcessStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtCreateThreadStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtOpenProcessStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtTerminateProcessStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

/// Helper function to find free virtual address region
fn findFreeRegion(asp: *vm.AddressSpace, size: u64, zero_bits: u64) ?u64 {
    const page_size = @as(u64, @intCast(vm.paging.page_size));
    const start_addr: u64 = 0x10000; // Start above 64KB
    const end_addr: u64 = 0x7FFFFFFF0000; // End below 128TB (x64 user space limit)

    const aligned_size = (size + page_size - 1) & ~(page_size - 1);
    if (aligned_size == 0) return null;

    // Apply zero bits mask: higher zero_bits bits must be zero
    const mask = if (zero_bits > 0) ((1 << zero_bits) - 1) << (64 - zero_bits) else 0;

    var current = start_addr;
    while (current + aligned_size <= end_addr) : (current += page_size) {
        // Check zero bits constraint
        if (mask != 0 and (current & mask) != 0) {
            current = (current + (1 << (64 - zero_bits)) - 1) & ~((1 << (64 - zero_bits)) - 1);
            continue;
        }

        // Check if region is free
        var free = true;
        var offset: u64 = 0;
        while (offset < aligned_size) : (offset += page_size) {
            const va = current + offset;
            if (asp.vad.findContaining(va) != null or asp.getPhysical(va) != null) {
                free = false;
                break;
            }
        }

        if (free) return current;
    }

    return null;
}

fn NtAllocateVirtualMemoryStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    const process_handle = args[0];
    const base_addr_ptr = args[1];
    const zero_bits = args[2];
    const region_size_ptr = args[3];
    const allocation_type = @as(u32, @truncate(args[4]));
    const protect = @as(u32, @truncate(args[5]));

    // Validate input pointers
    if (!probeUserPointer(base_addr_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;
    if (!probeUserPointer(region_size_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;

    // Read parameters from user space
    var base_addr: u64 = 0;
    var region_size: u64 = 0;
    {
        const src_base: *const u64 = @ptrFromInt(base_addr_ptr);
        base_addr = src_base.*;
        const src_size: *const u64 = @ptrFromInt(region_size_ptr);
        region_size = src_size.*;
    }

    if (region_size == 0) return io.STATUS_INVALID_PARAMETER;

    const page_size = @as(u64, @intCast(vm.paging.page_size));
    region_size = (region_size + page_size - 1) & ~(page_size - 1);

    // Get target process address space
    const process = if (process_handle == 0xFFFFFFFFFFFFFFFF)
        ps.getCurrentProcess()
    else
        ps.findProcessByHandle(process_handle) orelse return io.STATUS_INVALID_HANDLE;
    const asp = process.address_space orelse return io.STATUS_NO_MEMORY;

    // Allocate region
    if (base_addr == 0) {
        base_addr = findFreeRegion(asp, region_size, zero_bits) orelse return io.STATUS_NO_MEMORY;
    } else {
        base_addr &= ~(page_size - 1);
        // Verify region is free
        var offset: u64 = 0;
        while (offset < region_size) : (offset += page_size) {
            const va = base_addr + offset;
            if (asp.vad.findContaining(va) != null or asp.getPhysical(va) != null)
                return io.STATUS_CONFLICTING_ADDRESSES;
        }
    }

    // Handle reservation
    if ((allocation_type & vad.MEM_RESERVE) != 0) {
        const end_excl = base_addr + region_size;
        _ = asp.vad.insert(base_addr, end_excl, .reserved, protect, false);
    }

    // Handle commit
    if ((allocation_type & vad.MEM_COMMIT) != 0) {
        const map_flags = vm.MapFlags{
            .writable = (protect & (vad.PAGE_READWRITE | vad.PAGE_WRITECOPY)) != 0,
            .user = true,
            .executable = (protect & (vad.PAGE_EXECUTE | vad.PAGE_EXECUTE_READ | vad.PAGE_EXECUTE_READWRITE)) != 0,
        };

        var offset: u64 = 0;
        errdefer {
            // Clean up on failure
            var cleanup_offset: u64 = 0;
            while (cleanup_offset < offset) : (cleanup_offset += page_size)
                _ = asp.unmapAndFree(base_addr + cleanup_offset);
            if ((allocation_type & vad.MEM_RESERVE) != 0)
                _ = asp.vad.remove(base_addr, base_addr + region_size);
        }

        while (offset < region_size) : (offset += page_size) {
            const va = base_addr + offset;
            _ = asp.mapPageAlloc(va, map_flags) orelse return io.STATUS_NO_MEMORY;
        }

        vm.recordCommittedVadRange(asp, base_addr, @as(u32, @truncate(region_size / page_size)), protect);
    }

    // Write back results
    {
        const dst_base: *u64 = @ptrFromInt(base_addr_ptr);
        dst_base.* = base_addr;
        const dst_size: *u64 = @ptrFromInt(region_size_ptr);
        dst_size.* = region_size;
    }

    return io.STATUS_SUCCESS;
}

fn NtFreeVirtualMemoryStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    const process_handle = args[0];
    const base_addr_ptr = args[1];
    const region_size_ptr = args[2];
    const free_type = @as(u32, @truncate(args[3]));

    // Validate input pointers
    if (!probeUserPointer(base_addr_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;
    if (!probeUserPointer(region_size_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;

    // Read parameters from user space
    var base_addr: u64 = 0;
    var region_size: u64 = 0;
    {
        const src_base: *const u64 = @ptrFromInt(base_addr_ptr);
        base_addr = src_base.*;
        const src_size: *const u64 = @ptrFromInt(region_size_ptr);
        region_size = src_size.*;
    }

    const page_size = @as(u64, @intCast(vm.paging.page_size));

    // Get target process address space
    const process = if (process_handle == 0xFFFFFFFFFFFFFFFF)
        ps.getCurrentProcess()
    else
        ps.findProcessByHandle(process_handle) orelse return io.STATUS_INVALID_HANDLE;
    const asp = process.address_space orelse return io.STATUS_NO_MEMORY;

    base_addr &= ~(page_size - 1);

    if ((free_type & vad.MEM_RELEASE) != 0) {
        // Release entire region
        if (region_size != 0) return io.STATUS_INVALID_PARAMETER;

        const vad_entry = asp.vad.findContaining(base_addr) orelse return io.STATUS_INVALID_PARAMETER;
        region_size = vad_entry.end_exclusive - vad_entry.start;

        // Unmap all pages
        var offset: u64 = 0;
        while (offset < region_size) : (offset += page_size)
            _ = asp.unmapAndFree(vad_entry.start + offset);

        // Remove from VAD
        _ = asp.vad.remove(vad_entry.start, vad_entry.end_exclusive);
        base_addr = vad_entry.start;
    } else if ((free_type & vad.MEM_DECOMMIT) != 0) {
        // Decommit pages
        if (region_size == 0) return io.STATUS_INVALID_PARAMETER;

        region_size = (region_size + page_size - 1) & ~(page_size - 1);

        // Unmap pages
        var offset: u64 = 0;
        while (offset < region_size) : (offset += page_size)
            _ = asp.unmapAndFree(base_addr + offset);

        // Update VAD to reserved
        const end_excl = base_addr + region_size;
        _ = asp.vad.insert(base_addr, end_excl, .reserved, vad.PAGE_NOACCESS, false);
    } else {
        return io.STATUS_INVALID_PARAMETER;
    }

    // Write back results
    {
        const dst_base: *u64 = @ptrFromInt(base_addr_ptr);
        dst_base.* = base_addr;
        const dst_size: *u64 = @ptrFromInt(region_size_ptr);
        dst_size.* = region_size;
    }

    return io.STATUS_SUCCESS;
}

fn NtProtectVirtualMemoryStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    const process_handle = args[0];
    const base_addr_ptr = args[1];
    const region_size_ptr = args[2];
    const new_protect = @as(u32, @truncate(args[3]));
    const old_protect_ptr = args[4];

    // Validate input pointers
    if (!probeUserPointer(base_addr_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;
    if (!probeUserPointer(region_size_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;
    if (!probeUserPointer(old_protect_ptr, @sizeOf(u32), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;

    // Read parameters from user space
    var base_addr: u64 = 0;
    var region_size: u64 = 0;
    {
        const src_base: *const u64 = @ptrFromInt(base_addr_ptr);
        base_addr = src_base.*;
        const src_size: *const u64 = @ptrFromInt(region_size_ptr);
        region_size = src_size.*;
    }

    if (region_size == 0) return io.STATUS_INVALID_PARAMETER;

    const page_size = @as(u64, @intCast(vm.paging.page_size));
    base_addr &= ~(page_size - 1);
    region_size = (region_size + page_size - 1) & ~(page_size - 1);

    // Get target process address space
    const process = if (process_handle == 0xFFFFFFFFFFFFFFFF)
        ps.getCurrentProcess()
    else
        ps.findProcessByHandle(process_handle) orelse return io.STATUS_INVALID_HANDLE;
    const asp = process.address_space orelse return io.STATUS_NO_MEMORY;

    // Get old protection
    var old_protect: u32 = vad.PAGE_NOACCESS;
    if (asp.vad.findContaining(base_addr)) |e| {
        old_protect = e.protect;
    } else if (asp.getPhysical(base_addr) != null) {
        old_protect = vad.PAGE_READWRITE; // Default if not in VAD
    }

    // Change protection for all pages
    const new_flags = vm.MapFlags{
        .writable = (new_protect & (vad.PAGE_READWRITE | vad.PAGE_WRITECOPY)) != 0,
        .user = true,
        .executable = (new_protect & (vad.PAGE_EXECUTE | vad.PAGE_EXECUTE_READ | vad.PAGE_EXECUTE_READWRITE)) != 0,
    };

    var offset: u64 = 0;
    while (offset < region_size) : (offset += page_size) {
        const va = base_addr + offset;
        if (asp.getPhysical(va) == null) return io.STATUS_INVALID_PARAMETER;
        if (!asp.changeProtection(va, new_flags)) return io.STATUS_INVALID_PARAMETER;
    }

    // Update VAD
    const end_excl = base_addr + region_size;
    _ = asp.vad.insert(base_addr, end_excl, .committed, new_protect, false);

    // Write back results
    {
        const dst_old: *u32 = @ptrFromInt(old_protect_ptr);
        dst_old.* = old_protect;
        const dst_base: *u64 = @ptrFromInt(base_addr_ptr);
        dst_base.* = base_addr;
        const dst_size: *u64 = @ptrFromInt(region_size_ptr);
        dst_size.* = region_size;
    }

    return io.STATUS_SUCCESS;
}

fn NtMapViewOfSectionStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    const section_handle = args[0];
    const process_handle = args[1];
    const base_addr_ptr = args[2];
    const zero_bits = args[3];
    const commit_size = args[4];
    const section_offset_ptr = args[5];
    const view_size_ptr = args[6];
    const inherit_disposition = args[7];
    const allocation_type = @as(u32, @truncate(args[8]));
    const protect = @as(u32, @truncate(args[9]));

    _ = commit_size;
    _ = inherit_disposition;
    _ = allocation_type;

    // Validate required pointers
    if (!probeUserPointer(base_addr_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;
    if (!probeUserPointer(view_size_ptr, @sizeOf(u64), .{ .write_access = true, .allow_null = false }))
        return io.STATUS_INVALID_PARAMETER;

    // Read section offset (optional)
    var section_offset: u64 = 0;
    if (section_offset_ptr != 0) {
        if (!probeUserPointer(section_offset_ptr, @sizeOf(u64), .{ .read_access = true, .allow_null = false }))
            return io.STATUS_INVALID_PARAMETER;
        const src_offset: *const u64 = @ptrFromInt(section_offset_ptr);
        section_offset = src_offset.*;
    }

    // Read parameters from user space
    var base_addr: u64 = 0;
    var view_size: u64 = 0;
    {
        const src_base: *const u64 = @ptrFromInt(base_addr_ptr);
        base_addr = src_base.*;
        const src_size: *const u64 = @ptrFromInt(view_size_ptr);
        view_size = src_size.*;
    }

    const page_size = @as(u64, @intCast(vm.paging.page_size));
    section_offset &= ~(page_size - 1);

    if (view_size == 0) {
        // If view size is 0, map entire section starting from offset
        // For now, return not implemented as we need section object support
        return io.STATUS_NOT_IMPLEMENTED;
    }

    view_size = (view_size + page_size - 1) & ~(page_size - 1);

    // Get target process address space
    const process = if (process_handle == 0xFFFFFFFFFFFFFFFF)
        ps.getCurrentProcess()
    else
        ps.findProcessByHandle(process_handle) orelse return io.STATUS_INVALID_HANDLE;
    const asp = process.address_space orelse return io.STATUS_NO_MEMORY;

    // Get section object from handle
    const section = ob.getObjectByHandle(section_handle, .section) orelse return io.STATUS_INVALID_HANDLE;
    _ = section; // Will be used when section object is implemented

    // Allocate region
    if (base_addr == 0) {
        base_addr = findFreeRegion(asp, view_size, zero_bits) orelse return io.STATUS_NO_MEMORY;
    } else {
        base_addr &= ~(page_size - 1);
        // Verify region is free
        var offset: u64 = 0;
        while (offset < view_size) : (offset += page_size) {
            const va = base_addr + offset;
            if (asp.vad.findContaining(va) != null or asp.getPhysical(va) != null)
                return io.STATUS_CONFLICTING_ADDRESSES;
        }
    }

    // Handle allocation type
    const map_flags = vm.MapFlags{
        .writable = (protect & (vad.PAGE_READWRITE | vad.PAGE_WRITECOPY)) != 0,
        .user = true,
        .executable = (protect & (vad.PAGE_EXECUTE | vad.PAGE_EXECUTE_READ | vad.PAGE_EXECUTE_READWRITE)) != 0,
    };

    var offset: u64 = 0;
    errdefer {
        // Clean up on failure
        var cleanup_offset: u64 = 0;
        while (cleanup_offset < offset) : (cleanup_offset += page_size)
            _ = asp.unmapAndFree(base_addr + cleanup_offset);
    }

    // For now, allocate anonymous pages (will be replaced with section mapping later)
    while (offset < view_size) : (offset += page_size) {
        const va = base_addr + offset;
        _ = asp.mapPageAlloc(va, map_flags) orelse return io.STATUS_NO_MEMORY;
    }

    // Record in VAD
    const end_excl = base_addr + view_size;
    _ = asp.vad.insert(base_addr, end_excl, .committed, protect, true); // Mark as section view

    // Write back results
    {
        const dst_base: *u64 = @ptrFromInt(base_addr_ptr);
        dst_base.* = base_addr;
        const dst_size: *u64 = @ptrFromInt(view_size_ptr);
        dst_size.* = view_size;
    }

    return io.STATUS_SUCCESS;
}

fn NtCreateFileStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtReadFileStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtWriteFileStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtDeviceIoControlFileStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtCancelIoFileStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}

fn NtCreateIoCompletionPortStub(argc: u64, args: *const [6]u64) io.NTSTATUS {
    _ = argc;
    _ = args;
    return io.STATUS_NOT_IMPLEMENTED;
}
