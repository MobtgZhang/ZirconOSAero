//! Object Manager (NT style)
//! Manages kernel objects with unified header, handle table, namespace,
//! reference counting, waitable objects, and lifecycle management.
//!
//! `ObjectHeader.ref_count` / `handle_count` 使用原子更新（`@atomicRmw` / `@cmpxchgStrong`），
//! 与公开文档中 `InterlockedIncrement` 语义同阶；SMP/ISR 与句柄路径可安全并发（仍须遵守各子系统锁序）。
//!
//! **句柄关闭 vs `IRP_MJ_CLEANUP`（阶段 A 审计）**：`HandleTable.closeHandle` 递减 `handle_count` 并在 `ref_count` 至零时按类型调用 `cleanup_hooks`（当前 **Section** 已接线）。**文件对象**（`vfs.FileObject`）经 `vfs.close` 在 `FsOps.close` 之前调用可选的 **`FsOps.cleanup`**（等价 **IRP_MJ_CLEANUP** 子集）；各 FS 驱动在 `mount` 时填入。
//!
//! **命名打开与 SE（B3）**：`obOpenObjectByNameAccessProbe` 提供 **Key + File** 路径的 `se/token.zig` 分派；完整句柄创建仍由各 `Nt*` 路径完成。

const std = @import("std");
const builtin = @import("builtin");
const klog = @import("../rtl/klog.zig");
const arch = @import("../arch.zig");

pub const ObjectType = enum(u16) {
    process = 0,
    thread = 1,
    address_space = 2,
    section = 3,
    token = 4,
    event = 5,
    mutex = 6,
    semaphore = 7,
    port = 8,
    file = 9,
    device = 10,
    driver = 11,
    directory = 12,
    symbolic_link = 13,
    timer_obj = 14,
    key = 15,
};

pub const OBJ_FLAG_PERMANENT: u32 = 0x01;
pub const OBJ_FLAG_KERNEL_ONLY: u32 = 0x02;
pub const OBJ_FLAG_INHERIT: u32 = 0x04;
pub const OBJ_FLAG_CASE_INSENSITIVE: u32 = 0x08;
/// 内核事件：`SynchronizationEvent`（Learn）语义 — `NtSetEvent` 唤醒一名等待者后清除 `signal_state`。
pub const OBJ_FLAG_EVENT_AUTO_RESET: u32 = 0x00010000;

/// 可等待对象上的 FIFO 等待链节点（与 `ke/wait.zig`、`scheduler` 协同）。
pub const WaitEntry = struct {
    next: ?*WaitEntry = null,
    prev: ?*WaitEntry = null,
    thread_index: usize = 0,
    hdr: *ObjectHeader = undefined,
    /// `WaitAny` 下标；单对象等待恒为 0。
    wait_slot: u32 = 0,
};

pub const ObjectHeader = struct {
    obj_type: ObjectType = .process,
    ref_count: u32 = 0,
    handle_count: u32 = 0,
    flags: u32 = 0,
    name_ptr: u64 = 0,
    name_len: u16 = 0,
    security_desc: u64 = 0,
    signal_state: bool = false,
    wait_count: u32 = 0,
    /// 通用时间戳字段；**同步对象**：`.semaphore` 时打包 `current_count|max_count`（各 32 bit，见 `ke/wait.zig`），其它类型勿依赖此布局。
    creation_time: u64 = 0,
    wait_list_head: ?*WaitEntry = null,
    wait_list_tail: ?*WaitEntry = null,

    pub fn addRef(self: *ObjectHeader) void {
        _ = @atomicRmw(u32, &self.ref_count, .Add, 1, .seq_cst);
    }

    /// 引用减一；返回 **减后** 是否为 0（与旧 `release` 布尔语义一致）。
    pub fn release(self: *ObjectHeader) bool {
        var cur = @atomicLoad(u32, &self.ref_count, .seq_cst);
        while (true) {
            if (cur == 0) {
                if (builtin.mode == .Debug) {
                    std.debug.panic("ObjectHeader.release: ref_count underflow", .{});
                }
                return false;
            }
            const next = cur - 1;
            if (@cmpxchgStrong(u32, &self.ref_count, cur, next, .seq_cst, .seq_cst)) |actual| {
                cur = actual;
                continue;
            }
            return next == 0;
        }
    }

    pub fn refCount(self: *const ObjectHeader) u32 {
        return @atomicLoad(u32, &self.ref_count, .seq_cst);
    }

    pub fn handleCount(self: *const ObjectHeader) u32 {
        return @atomicLoad(u32, &self.handle_count, .seq_cst);
    }

    pub fn isAlive(self: *const ObjectHeader) bool {
        return self.refCount() > 0;
    }

    pub fn isSignaled(self: *const ObjectHeader) bool {
        return self.signal_state;
    }

    pub fn signal(self: *ObjectHeader) void {
        self.signal_state = true;
    }

    pub fn unsignal(self: *ObjectHeader) void {
        self.signal_state = false;
    }
};

/// 将 `entry` 挂到 `hdr` 等待队列尾（FIFO）。调用方须持有 `scheduler` IRQ 自旋锁。
pub fn waitListAppend(hdr: *ObjectHeader, entry: *WaitEntry) void {
    entry.hdr = hdr;
    entry.next = null;
    entry.prev = hdr.wait_list_tail;
    if (hdr.wait_list_tail) |t| {
        t.next = entry;
    } else {
        hdr.wait_list_head = entry;
    }
    hdr.wait_list_tail = entry;
}

/// 从所属对象等待队列摘除 `entry`；未入队则为 no-op。
pub fn waitListRemove(entry: *WaitEntry) void {
    const hdr = entry.hdr;
    const linked = (hdr.wait_list_head == entry) or (hdr.wait_list_tail == entry) or
        (entry.prev != null) or (entry.next != null);
    if (!linked) return;

    if (entry.prev) |p| {
        p.next = entry.next;
    } else {
        hdr.wait_list_head = entry.next;
    }
    if (entry.next) |n| {
        n.prev = entry.prev;
    } else {
        hdr.wait_list_tail = entry.prev;
    }
    entry.next = null;
    entry.prev = null;
}

pub const Handle = u32;
pub const INVALID_HANDLE: Handle = 0xFFFFFFFF;

pub const ACCESS_MASK = u32;
pub const GENERIC_READ: ACCESS_MASK = 0x80000000;
pub const GENERIC_WRITE: ACCESS_MASK = 0x40000000;
pub const GENERIC_EXECUTE: ACCESS_MASK = 0x20000000;
pub const GENERIC_ALL: ACCESS_MASK = 0x10000000;
pub const DELETE: ACCESS_MASK = 0x00010000;
pub const READ_CONTROL: ACCESS_MASK = 0x00020000;
pub const SYNCHRONIZE: ACCESS_MASK = 0x00100000;

pub const HANDLE_FLAG_INHERIT: u32 = 0x01;
pub const HANDLE_FLAG_PROTECT: u32 = 0x02;

pub const HandleEntry = struct {
    object_ptr: u64 = 0,
    granted_access: ACCESS_MASK = 0,
    flags: u32 = 0,
    obj_type: ObjectType = .process,

    pub fn isValid(self: *const HandleEntry) bool {
        return self.object_ptr != 0;
    }
};

const MAX_HANDLES: usize = 256;

pub const HandleTable = struct {
    entries: [MAX_HANDLES]HandleEntry = [_]HandleEntry{.{}} ** MAX_HANDLES,
    count: usize = 0,
    owner_pid: u32 = 0,

    pub fn init(pid: u32) HandleTable {
        return .{
            .entries = [_]HandleEntry{.{}} ** MAX_HANDLES,
            .count = 0,
            .owner_pid = pid,
        };
    }

    pub fn allocHandle(self: *HandleTable, object_ptr: u64, access: ACCESS_MASK, obj_type: ObjectType) ?Handle {
        if (object_ptr == 0) return null;
        // One reference per handle; balanced in closeHandle via release().
        referenceObject(object_ptr);
        const hdr = @as(*ObjectHeader, @ptrFromInt(object_ptr));
        _ = @atomicRmw(u32, &hdr.handle_count, .Add, 1, .seq_cst);

        for (self.entries[0..], 0..) |*entry, i| {
            if (entry.object_ptr == 0) {
                entry.object_ptr = object_ptr;
                entry.granted_access = access;
                entry.obj_type = obj_type;
                self.count += 1;
                return @intCast(i);
            }
        }
        // Roll back on table full
        decHandleCount(hdr);
        _ = dereferenceObject(object_ptr);
        return null;
    }

    pub fn closeHandle(self: *HandleTable, handle: Handle) bool {
        if (handle >= MAX_HANDLES) return false;
        const entry = &self.entries[handle];
        if (entry.object_ptr == 0) return false;

        const object_ptr = entry.object_ptr;
        const obj_type = entry.obj_type;
        const hdr = @as(*ObjectHeader, @ptrFromInt(object_ptr));
        decHandleCount(hdr);
        const freed = hdr.release();

        entry.* = .{};
        if (self.count > 0) self.count -= 1;
        if (freed and obj_type == .section) {
            @import("cleanup_hooks.zig").invokeSectionLastReference(object_ptr);
        }
        return true;
    }

    /// 进程终止时关闭表中仍有效的句柄（与 `closeHandle` 语义一致）。
    pub fn closeAllOpenHandles(self: *HandleTable) void {
        var i: Handle = 0;
        while (i < MAX_HANDLES) : (i += 1) {
            if (self.entries[i].object_ptr != 0) {
                _ = self.closeHandle(i);
            }
        }
    }

    pub fn lookupHandle(self: *const HandleTable, handle: Handle) ?*const HandleEntry {
        if (handle >= MAX_HANDLES) return null;
        const entry = &self.entries[handle];
        if (entry.object_ptr == 0) return null;
        return entry;
    }

    pub fn lookupMut(self: *HandleTable, handle: Handle) ?*HandleEntry {
        if (handle >= MAX_HANDLES) return null;
        const entry = &self.entries[handle];
        if (entry.object_ptr == 0) return null;
        return entry;
    }

    pub fn checkAccess(self: *const HandleTable, handle: Handle, required: ACCESS_MASK) bool {
        const entry = self.lookupHandle(handle) orelse return false;
        return (entry.granted_access & required) == required;
    }

    pub fn duplicateHandle(self: *HandleTable, source: Handle, new_access: ACCESS_MASK) ?Handle {
        const entry = self.lookupHandle(source) orelse return null;
        const access = if (new_access != 0) new_access else entry.granted_access;
        return self.allocHandle(entry.object_ptr, access, entry.obj_type);
    }
};

fn decHandleCount(hdr: *ObjectHeader) void {
    var cur = @atomicLoad(u32, &hdr.handle_count, .seq_cst);
    while (true) {
        if (cur == 0) {
            if (builtin.mode == .Debug) {
                std.debug.panic("HandleTable: handle_count underflow on close/rollback", .{});
            }
            return;
        }
        const next = cur - 1;
        if (@cmpxchgStrong(u32, &hdr.handle_count, cur, next, .seq_cst, .seq_cst)) |actual| {
            cur = actual;
            continue;
        }
        return;
    }
}

// ── Object Type Registry ──

const MAX_TYPES: usize = 16;

pub const TypeInfo = struct {
    name: []const u8 = "",
    obj_type: ObjectType = .process,
    total_objects: u32 = 0,
};

var type_registry: [MAX_TYPES]TypeInfo = [_]TypeInfo{.{}} ** MAX_TYPES;
var type_count: usize = 0;
var ob_initialized: bool = false;

pub fn init() void {
    registerType(.process, "Process");
    registerType(.thread, "Thread");
    registerType(.address_space, "AddressSpace");
    registerType(.section, "Section");
    registerType(.token, "Token");
    registerType(.event, "Event");
    registerType(.mutex, "Mutex");
    registerType(.semaphore, "Semaphore");
    registerType(.port, "Port");
    registerType(.file, "File");
    registerType(.device, "Device");
    registerType(.driver, "Driver");
    registerType(.directory, "Directory");
    registerType(.symbolic_link, "SymbolicLink");
    registerType(.timer_obj, "Timer");
    registerType(.key, "Key");

    ob_initialized = true;
    klog.info("Object Manager: %u types registered", .{type_count});
}

fn registerType(obj_type: ObjectType, name: []const u8) void {
    if (type_count >= MAX_TYPES) return;
    type_registry[type_count] = .{
        .name = name,
        .obj_type = obj_type,
        .total_objects = 0,
    };
    type_count += 1;
}

pub fn getTypeInfo(obj_type: ObjectType) ?*TypeInfo {
    for (type_registry[0..type_count]) |*ti| {
        if (ti.obj_type == obj_type) return ti;
    }
    return null;
}

pub fn createObject(obj_type: ObjectType, ptr: u64) void {
    if (getTypeInfo(obj_type)) |ti| {
        // 统计计数；饱和加避免 Debug 下 u32 溢出触发 integer overflow panic。
        ti.total_objects = ti.total_objects +| 1;
    }
    const hdr = @as(*ObjectHeader, @ptrFromInt(ptr));
    hdr.obj_type = obj_type;
    @atomicStore(u32, &hdr.ref_count, 1, .seq_cst);
    @atomicStore(u32, &hdr.handle_count, 0, .seq_cst);
}

pub fn referenceObject(ptr: u64) void {
    const hdr = @as(*ObjectHeader, @ptrFromInt(ptr));
    hdr.addRef();
}

pub fn dereferenceObject(ptr: u64) bool {
    const hdr = @as(*ObjectHeader, @ptrFromInt(ptr));
    return hdr.release();
}

// ── Object Namespace ──

const MAX_NAMESPACE_ENTRIES: usize = 64;

pub const NamespaceEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    obj_type: ObjectType = .directory,
    object_ptr: u64 = 0,
    parent_idx: u32 = 0,
    /// `obj_type == .symbolic_link` 时有效：目标路径（UTF-8 字节，非以 NUL 结尾的 C 串）。
    link_target: [64]u8 = [_]u8{0} ** 64,
    link_target_len: usize = 0,
};

var namespace: [MAX_NAMESPACE_ENTRIES]NamespaceEntry = [_]NamespaceEntry{.{}} ** MAX_NAMESPACE_ENTRIES;
var namespace_count: usize = 0;

pub fn initNamespace() void {
    createNamespaceDir("\\", 0);
    createNamespaceDir("\\ObjectTypes", 0);
    createNamespaceDir("\\Devices", 0);
    createNamespaceDir("\\Sessions", 0);
    createNamespaceDir("\\BaseNamedObjects", 0);
    createNamespaceDir("\\KnownDlls", 0);

    klog.info("Object Namespace: %u entries initialized", .{namespace_count});
}

fn createNamespaceDir(name: []const u8, parent: u32) void {
    if (namespace_count >= MAX_NAMESPACE_ENTRIES) return;
    var entry = &namespace[namespace_count];
    entry.* = .{};
    const copy_len = @min(name.len, entry.name.len);
    @memcpy(entry.name[0..copy_len], name[0..copy_len]);
    entry.name_len = copy_len;
    entry.obj_type = .directory;
    entry.parent_idx = parent;
    namespace_count += 1;
}

pub fn lookupNamespace(name: []const u8) ?*NamespaceEntry {
    for (namespace[0..namespace_count]) |*entry| {
        if (entry.name_len != name.len) continue;
        var match = true;
        for (entry.name[0..entry.name_len], name) |a, b| {
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return entry;
    }
    return null;
}

pub fn insertNamespace(name: []const u8, obj_type: ObjectType, object_ptr: u64, parent: u32) bool {
    if (namespace_count >= MAX_NAMESPACE_ENTRIES) return false;
    var entry = &namespace[namespace_count];
    entry.* = .{};
    const copy_len = @min(name.len, entry.name.len);
    @memcpy(entry.name[0..copy_len], name[0..copy_len]);
    entry.name_len = copy_len;
    entry.obj_type = obj_type;
    entry.object_ptr = object_ptr;
    entry.parent_idx = parent;
    namespace_count += 1;
    return true;
}

/// 在对象命名空间中登记 **单层** 符号链接（K6.1 子集）；`target` 为规范化后的内部路径片段。
pub fn insertSymbolicLink(name: []const u8, target: []const u8, parent: u32) bool {
    if (namespace_count >= MAX_NAMESPACE_ENTRIES) return false;
    if (name.len == 0 or target.len == 0) return false;
    if (name.len > 64 or target.len > 64) return false;
    var entry = &namespace[namespace_count];
    entry.* = .{};
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    entry.obj_type = .symbolic_link;
    entry.parent_idx = parent;
    @memcpy(entry.link_target[0..target.len], target);
    entry.link_target_len = target.len;
    namespace_count += 1;
    return true;
}

pub fn removeNamespace(name: []const u8) bool {
    for (namespace[0..namespace_count]) |*entry| {
        if (entry.name_len != name.len) continue;
        var match = true;
        for (entry.name[0..entry.name_len], name) |a, b| {
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) {
            entry.* = .{};
            return true;
        }
    }
    return false;
}

pub fn getNamespaceCount() usize {
    return namespace_count;
}

// ── Waitable Object Support ──

pub const WAIT_OBJECT_0: u32 = 0;
pub const WAIT_TIMEOUT: u32 = 258;
pub const WAIT_FAILED: u32 = 0xFFFFFFFF;
pub const INFINITE: u32 = 0xFFFFFFFF;

pub fn waitForSingleObject(object_ptr: u64, _: u32) u32 {
    if (object_ptr == 0) return WAIT_FAILED;
    const hdr = @as(*ObjectHeader, @ptrFromInt(object_ptr));
    if (hdr.signal_state) {
        hdr.wait_count += 1;
        return WAIT_OBJECT_0;
    }
    var spins: u32 = 0;
    while (spins < 100000) : (spins += 1) {
        if (hdr.signal_state) {
            hdr.wait_count += 1;
            return WAIT_OBJECT_0;
        }
        arch.spinCpuRelax();
    }
    return WAIT_TIMEOUT;
}

pub fn signalObject(object_ptr: u64) void {
    if (object_ptr == 0) return;
    const hdr = @as(*ObjectHeader, @ptrFromInt(object_ptr));
    hdr.signal_state = true;
}

pub fn resetObject(object_ptr: u64) void {
    if (object_ptr == 0) return;
    const hdr = @as(*ObjectHeader, @ptrFromInt(object_ptr));
    hdr.signal_state = false;
}

pub fn isObjectSignaled(object_ptr: u64) bool {
    if (object_ptr == 0) return false;
    const hdr = @as(*const ObjectHeader, @ptrFromInt(object_ptr));
    return hdr.signal_state;
}

/// 剥离 NT 风格对象路径常见前缀（`\??\`、`\\?\`、`\DosDevices\`），供注册表/VFS 解析复用。
/// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/object-path-syntax （概念层；clean-room 实现）。
pub fn normalizeNtObjectPath(path: []const u8) []const u8 {
    var p = path;
    if (std.mem.startsWith(u8, p, "\\??\\")) {
        p = p[4..];
    } else if (std.mem.startsWith(u8, p, "\\\\?\\")) {
        p = p[4..];
    }
    const dos = "\\DosDevices\\";
    if (std.mem.startsWith(u8, p, dos)) {
        p = p[dos.len..];
    }
    return p;
}

/// 剥前缀后沿已登记符号链接解析，**最多 8 跳**（与常见 `MAX_SYMLINKS` 级策略同阶；防环靠跳数上限）。
pub fn normalizeNtObjectPathResolveSymlinks(path: []const u8) []const u8 {
    var current = normalizeNtObjectPath(path);
    var hop: u32 = 0;
    const max_symlink_hops = 8;
    while (hop < max_symlink_hops) : (hop += 1) {
        const e = lookupNamespace(current) orelse break;
        if (e.obj_type != .symbolic_link or e.link_target_len == 0) break;
        current = normalizeNtObjectPath(e.link_target[0..e.link_target_len]);
    }
    return current;
}

/// B3：按 NT 路径前缀做 **SE 门闸**（不分配句柄）。`tok` 须为 `se/token.zig` 中 `Token`。
pub fn obOpenObjectByNameAccessProbe(path: []const u8, desired: ACCESS_MASK, tok: *const anyopaque) bool {
    const se = @import("../se/token.zig");
    const t: *const se.Token = @alignCast(@ptrCast(tok));
    return se.openNamedObjectAccessCheck(path, desired, t);
}
