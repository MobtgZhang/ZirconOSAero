//! Object Manager (NT style)
//! Manages kernel objects with unified header, handle table, namespace,
//! reference counting, waitable objects, and lifecycle management.

const klog = @import("../rtl/klog.zig");

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
    creation_time: u64 = 0,

    pub fn addRef(self: *ObjectHeader) void {
        self.ref_count += 1;
    }

    pub fn release(self: *ObjectHeader) bool {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
        return self.ref_count == 0;
    }

    pub fn isAlive(self: *const ObjectHeader) bool {
        return self.ref_count > 0;
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
        for (self.entries[0..], 0..) |*entry, i| {
            if (entry.object_ptr == 0) {
                entry.object_ptr = object_ptr;
                entry.granted_access = access;
                entry.obj_type = obj_type;
                self.count += 1;
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn closeHandle(self: *HandleTable, handle: Handle) bool {
        if (handle >= MAX_HANDLES) return false;
        const entry = &self.entries[handle];
        if (entry.object_ptr == 0) return false;

        const hdr = @as(*ObjectHeader, @ptrFromInt(entry.object_ptr));
        if (hdr.handle_count > 0) hdr.handle_count -= 1;
        _ = hdr.release();

        entry.* = .{};
        if (self.count > 0) self.count -= 1;
        return true;
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
        ti.total_objects += 1;
    }
    const hdr = @as(*ObjectHeader, @ptrFromInt(ptr));
    hdr.obj_type = obj_type;
    hdr.ref_count = 1;
    hdr.handle_count = 0;
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
        asm volatile ("pause");
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
