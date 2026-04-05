//! ZirconOSAero registry runtime (NT-style keys; clean-room)
//! Provides a hierarchical key-value store for system and application settings.
//! Modeled after the NT Registry with hives:
//!   HKLM  - HKEY_LOCAL_MACHINE (hardware, drivers, system services)
//!   HKCU  - HKEY_CURRENT_USER  (user preferences)
//!   HKCR  - HKEY_CLASSES_ROOT  (file associations)
//!   HKU   - HKEY_USERS         (all user profiles)
//!   HKCC  - HKEY_CURRENT_CONFIG (current hardware profile)
//!
//! Layout inspired by the NT registry; **no code copied** from ReactOS or Windows (see THIRD_PARTY.md).
//!
//! **持久化**：内存树 + 可选 **ZOSH1** 覆盖（[`hive.zig`](hive.zig) `C:\System32\Config\ZirconUser.zosh`）；**RegF 只读子集**见 [`regf_parse.zig`](regf_parse.zig)；写回与 `registry` 切换见 [`regf_hive_stub.zig`](regf_hive_stub.zig)（`regfHiveBackendReady`，仍为 false 直至变异路径接线）。
//! **K8 / syscall**：`NtOpenKey` 等内核 SSDT 接线见 [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K8；当前以 `ntdll` 内存树路径为主。

const std = @import("std");
const klog = @import("../rtl/klog.zig");
const ob = @import("../ob/object.zig");
const os_version = @import("../config/os_version.zig");
const regf_hive = @import("regf_hive_stub.zig");

/// B2：运行时可切换后端（**写路径** 在 `regfHiveBackendReady()==true` 之前恒为 `memory_tree`）。
pub const RegBackend = enum(u8) {
    memory_tree = 0,
    regf_image = 1,
};

var active_reg_backend: RegBackend = .memory_tree;

pub fn setRegBackendForTest(b: RegBackend) void {
    active_reg_backend = b;
}

pub fn currentRegBackend() RegBackend {
    return active_reg_backend;
}

/// `NtSetValueKey` 等变异 API 使用的有效后端（RegF 持久化未就绪前强制内存树）。
pub fn effectiveMutationBackend() RegBackend {
    if (active_reg_backend == .regf_image and regf_hive.regfHiveBackendReady()) {
        return .regf_image;
    }
    return .memory_tree;
}

pub const ValueType = enum(u8) {
    none = 0,
    sz = 1,
    expand_sz = 2,
    binary = 3,
    dword = 4,
    dword_be = 5,
    multi_sz = 7,
    qword = 11,
};

pub const HiveType = enum(u8) {
    hklm = 0,
    hkcu = 1,
    hkcr = 2,
    hku = 3,
    hkcc = 4,
};

const MAX_KEY_NAME: usize = 48;
const MAX_VALUE_NAME: usize = 48;
const MAX_VALUE_DATA: usize = 64;
const MAX_SUBKEYS: usize = 8;
const MAX_VALUES: usize = 8;
const MAX_KEYS: usize = 64;

const NO_PARENT: u16 = 0xFFFF;

pub const RegValue = struct {
    name: [MAX_VALUE_NAME]u8 = [_]u8{0} ** MAX_VALUE_NAME,
    name_len: u16 = 0,
    value_type: ValueType = .none,
    data: [MAX_VALUE_DATA]u8 = [_]u8{0} ** MAX_VALUE_DATA,
    data_len: u16 = 0,
    dword_value: u32 = 0,

    pub fn getName(self: *const RegValue) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getStringValue(self: *const RegValue) []const u8 {
        if (self.value_type == .sz or self.value_type == .expand_sz) {
            return self.data[0..self.data_len];
        }
        return "";
    }

    pub fn getDwordValue(self: *const RegValue) u32 {
        return self.dword_value;
    }
};

pub const RegKey = struct {
    header: ob.ObjectHeader = .{ .obj_type = .key },
    name: [MAX_KEY_NAME]u8 = [_]u8{0} ** MAX_KEY_NAME,
    name_len: u16 = 0,
    hive: HiveType = .hklm,
    has_parent: bool = false,
    parent_idx: u16 = 0,
    subkey_indices: [MAX_SUBKEYS]u16 = [_]u16{0} ** MAX_SUBKEYS,
    subkey_count: u16 = 0,
    values: [MAX_VALUES]RegValue = [_]RegValue{.{}} ** MAX_VALUES,
    value_count: u16 = 0,
    active: bool = false,

    pub fn getName(self: *const RegKey) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn findValue(self: *const RegKey, name: []const u8) ?*const RegValue {
        var i: u16 = 0;
        while (i < self.value_count) : (i += 1) {
            if (self.values[i].name_len == name.len) {
                var match = true;
                for (self.values[i].name[0..self.values[i].name_len], name) |a, b| {
                    if (a != b) {
                        match = false;
                        break;
                    }
                }
                if (match) return &self.values[i];
            }
        }
        return null;
    }
};

var keys: [MAX_KEYS]RegKey = [_]RegKey{.{}} ** MAX_KEYS;
var key_count: usize = 0;
var initialized: bool = false;

/// `HKCU\Control Panel\Mouse` 键索引（供指针子系统读取 MouseSensitivity 等）；`init()` 后有效。
pub var hkcu_control_panel_mouse_key: ?u16 = null;
/// `HKLM\SOFTWARE\Microsoft\Windows\DWM`（主题色等）；`init()` 后有效。
pub var hklm_dwm_key: ?u16 = null;

fn strCopy(dst: []u8, src: []const u8) u16 {
    const len = @min(dst.len, src.len);
    for (dst[0..len], src[0..len]) |*d, s| d.* = s;
    return @intCast(len);
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn allocKey() ?u16 {
    if (key_count >= MAX_KEYS) return null;
    const idx = key_count;
    key_count += 1;
    keys[idx].active = true;
    return @intCast(idx);
}

pub fn createKey(hive: HiveType, parent_idx: u16, name: []const u8) ?u16 {
    const has_parent = parent_idx != NO_PARENT;
    if (has_parent) {
        if (parent_idx >= key_count or !keys[parent_idx].active) return null;
        const parent = &keys[parent_idx];
        var i: u16 = 0;
        while (i < parent.subkey_count) : (i += 1) {
            const sk = parent.subkey_indices[i];
            if (sk < key_count and keys[sk].active) {
                if (strEq(keys[sk].name[0..keys[sk].name_len], name)) {
                    return sk;
                }
            }
        }
    }

    const idx = allocKey() orelse return null;
    var key = &keys[idx];
    key.name_len = strCopy(&key.name, name);
    key.hive = hive;
    key.has_parent = has_parent;
    key.parent_idx = if (has_parent) parent_idx else 0;

    if (has_parent and parent_idx < key_count) {
        var parent = &keys[parent_idx];
        if (parent.subkey_count < MAX_SUBKEYS) {
            parent.subkey_indices[parent.subkey_count] = idx;
            parent.subkey_count += 1;
        }
    }

    return idx;
}

pub fn setValueSz(key_idx: u16, name: []const u8, data: []const u8) bool {
    if (key_idx >= key_count or !keys[key_idx].active) return false;
    var key = &keys[key_idx];

    var existing: ?u16 = null;
    var i: u16 = 0;
    while (i < key.value_count) : (i += 1) {
        if (strEq(key.values[i].name[0..key.values[i].name_len], name)) {
            existing = i;
            break;
        }
    }

    const vi = existing orelse blk: {
        if (key.value_count >= MAX_VALUES) return false;
        const ni = key.value_count;
        key.value_count += 1;
        break :blk ni;
    };

    var val = &key.values[vi];
    val.name_len = strCopy(&val.name, name);
    val.value_type = .sz;
    val.data_len = strCopy(&val.data, data);
    val.dword_value = 0;
    return true;
}

pub fn setValueDword(key_idx: u16, name: []const u8, data: u32) bool {
    if (key_idx >= key_count or !keys[key_idx].active) return false;
    var key = &keys[key_idx];

    var existing: ?u16 = null;
    var i: u16 = 0;
    while (i < key.value_count) : (i += 1) {
        if (strEq(key.values[i].name[0..key.values[i].name_len], name)) {
            existing = i;
            break;
        }
    }

    const vi = existing orelse blk: {
        if (key.value_count >= MAX_VALUES) return false;
        const ni = key.value_count;
        key.value_count += 1;
        break :blk ni;
    };

    var val = &key.values[vi];
    val.name_len = strCopy(&val.name, name);
    val.value_type = .dword;
    val.dword_value = data;
    val.data[0] = @truncate(data);
    val.data[1] = @truncate(data >> 8);
    val.data[2] = @truncate(data >> 16);
    val.data[3] = @truncate(data >> 24);
    val.data_len = 4;
    return true;
}

pub fn queryValueSz(key_idx: u16, name: []const u8) ?[]const u8 {
    if (key_idx >= key_count or !keys[key_idx].active) return null;
    if (keys[key_idx].findValue(name)) |val| {
        return val.getStringValue();
    }
    return null;
}

pub fn queryValueDword(key_idx: u16, name: []const u8) ?u32 {
    if (key_idx >= key_count or !keys[key_idx].active) return null;
    if (keys[key_idx].findValue(name)) |val| {
        if (val.value_type == .dword) return val.dword_value;
    }
    return null;
}

pub fn openKey(hive: HiveType, path: []const u8) ?u16 {
    _ = hive;
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        if (keys[i].active and strEq(keys[i].name[0..keys[i].name_len], path)) {
            return @intCast(i);
        }
    }
    return null;
}

/// Root key index for a hive (`HKEY_*` style name, no parent).
pub fn getHiveRootIndex(hive: HiveType) ?u16 {
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        if (!keys[i].active) continue;
        if (keys[i].hive != hive) continue;
        if (!keys[i].has_parent) return @intCast(i);
    }
    return null;
}

fn findDirectChild(parent_idx: u16, name: []const u8) ?u16 {
    if (parent_idx >= key_count or !keys[parent_idx].active) return null;
    const parent = &keys[parent_idx];
    var i: u16 = 0;
    while (i < parent.subkey_count) : (i += 1) {
        const sk = parent.subkey_indices[i];
        if (sk < key_count and keys[sk].active) {
            if (strEq(keys[sk].name[0..keys[sk].name_len], name)) return sk;
        }
    }
    return null;
}

/// Walk subkeys from `root_idx` using backslash-separated relative path (no leading '\').
pub fn openKeyPathFromRoot(root_idx: u16, rel_path: []const u8) ?u16 {
    var cur = root_idx;
    var rest = rel_path;
    while (rest.len > 0) {
        if (rest[0] == '\\') {
            rest = rest[1..];
            continue;
        }
        const slash = std.mem.indexOfScalar(u8, rest, '\\');
        const segment = if (slash) |s| rest[0..s] else rest;
        if (segment.len > 0) {
            cur = findDirectChild(cur, segment) orelse return null;
        }
        rest = if (slash) |s| rest[s + 1 ..] else "";
    }
    return cur;
}

const nt_machine_prefix = "\\Registry\\Machine\\";
const nt_user_prefix = "\\Registry\\User\\";

/// Resolve `\Registry\Machine\...` / `\Registry\User\...` style paths (NT Native API).
pub fn openKeyByNtPath(full_path: []const u8) ?u16 {
    if (full_path.len >= nt_machine_prefix.len and
        std.mem.eql(u8, full_path[0..nt_machine_prefix.len], nt_machine_prefix))
    {
        const root = getHiveRootIndex(.hklm) orelse return null;
        return openKeyPathFromRoot(root, full_path[nt_machine_prefix.len..]);
    }
    if (full_path.len >= nt_user_prefix.len and
        std.mem.eql(u8, full_path[0..nt_user_prefix.len], nt_user_prefix))
    {
        const root = getHiveRootIndex(.hkcu) orelse return null;
        return openKeyPathFromRoot(root, full_path[nt_user_prefix.len..]);
    }
    return null;
}

pub fn getKey(idx: u16) ?*const RegKey {
    if (idx >= key_count or !keys[idx].active) return null;
    return &keys[idx];
}

pub fn regKeyFromHeader(h: *ob.ObjectHeader) *RegKey {
    return @fieldParentPtr("header", h);
}

pub fn keyHeaderPtr(idx: u16) ?*ob.ObjectHeader {
    if (idx >= key_count or !keys[idx].active) return null;
    return &keys[idx].header;
}

pub fn getKeyCount() usize {
    return key_count;
}

/// 由键对象头解析线性索引（句柄 → `RegKey` 槽位）。
pub fn keyIndexFromObjectHeader(h: *ob.ObjectHeader) ?u16 {
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        if (keys[i].active and @intFromPtr(&keys[i].header) == @intFromPtr(h)) {
            return @intCast(i);
        }
    }
    return null;
}

pub fn isInitialized() bool {
    return initialized;
}

fn populateDefaults() void {
    const hklm_root = createKey(.hklm, NO_PARENT, "HKEY_LOCAL_MACHINE") orelse return;
    const sys_key = createKey(.hklm, hklm_root, "SYSTEM") orelse return;
    const ccs_key = createKey(.hklm, sys_key, "CurrentControlSet") orelse return;
    const ctrl_key = createKey(.hklm, ccs_key, "Control") orelse return;

    const session_key = createKey(.hklm, ctrl_key, "Session Manager") orelse return;
    _ = setValueSz(session_key, "BootExecute", "autocheck autochk *");
    _ = setValueDword(session_key, "ProtectionMode", 1);

    const env_key = createKey(.hklm, session_key, "Environment") orelse return;
    _ = setValueSz(env_key, "ComSpec", "C:\\WINDOWS\\system32\\cmd.exe");
    _ = setValueSz(env_key, "Path", "C:\\WINDOWS\\system32;C:\\WINDOWS");
    _ = setValueSz(env_key, "TEMP", "C:\\WINDOWS\\TEMP");
    _ = setValueSz(env_key, "windir", "C:\\WINDOWS");
    _ = setValueSz(env_key, "OS", "ZirconOSAero_NT61");

    const svc_key = createKey(.hklm, ccs_key, "Services") orelse return;

    const vga_svc = createKey(.hklm, svc_key, "VgaSave") orelse return;
    _ = setValueDword(vga_svc, "Start", 1);
    _ = setValueDword(vga_svc, "Type", 1);
    _ = setValueSz(vga_svc, "ImagePath", "\\SystemRoot\\system32\\drivers\\vga.sys");

    const mouse_svc = createKey(.hklm, svc_key, "i8042prt") orelse return;
    _ = setValueDword(mouse_svc, "Start", 1);
    _ = setValueDword(mouse_svc, "Type", 1);
    _ = setValueSz(mouse_svc, "ImagePath", "\\SystemRoot\\system32\\drivers\\i8042prt.sys");

    const audio_svc = createKey(.hklm, svc_key, "AudioSrv") orelse return;
    _ = setValueDword(audio_svc, "Start", 2);
    _ = setValueDword(audio_svc, "Type", 0x20);
    _ = setValueSz(audio_svc, "ImagePath", "\\SystemRoot\\system32\\svchost.exe");

    const hw_key = createKey(.hklm, hklm_root, "HARDWARE") orelse return;
    const desc_key = createKey(.hklm, hw_key, "DESCRIPTION") orelse return;
    const sys_desc = createKey(.hklm, desc_key, "System") orelse return;
    _ = setValueSz(sys_desc, "Identifier", "AT/AT COMPATIBLE");
    _ = setValueSz(sys_desc, "SystemBiosVersion", "ZirconOSAero firmware v1.0");

    const cpu_key = createKey(.hklm, sys_desc, "CentralProcessor") orelse return;
    const cpu0 = createKey(.hklm, cpu_key, "0") orelse return;
    _ = setValueSz(cpu0, "ProcessorNameString", "ZirconOSAero Virtual CPU");
    _ = setValueDword(cpu0, "~MHz", 3000);
    _ = setValueSz(cpu0, "VendorIdentifier", "GenuineIntel");

    const sw_key = createKey(.hklm, hklm_root, "SOFTWARE") orelse return;
    // WOW64：`HKLM\SOFTWARE` 下 32 位视图逻辑映射的锚点（见 `wow64/redirect.zig`）。
    _ = createKey(.hklm, sw_key, "Wow6432Node") orelse return;
    const ms_win = createKey(.hklm, sw_key, "Microsoft") orelse return;
    const win_brand = createKey(.hklm, ms_win, "Windows") orelse return;
    const dwm_key = createKey(.hklm, win_brand, "DWM") orelse return;
    hklm_dwm_key = dwm_key;
    _ = setValueDword(dwm_key, "ColorPrevalence", 1);
    // DWORD 为 **COLORREF** 低 24 位语义；`dwm.syncPolicyFromRegistry` 经 color_nt61 转内核 BGR。
    _ = setValueDword(dwm_key, "AccentColor", 0x00D778);
    _ = setValueDword(dwm_key, "ColorizationColor", 0x00D778);
    _ = setValueDword(dwm_key, "ColorizationOpaqueBlend", 0);
    _ = setValueDword(dwm_key, "EnableAeroPeek", 1);
    // ZirconOSAero：`dwm.syncPolicyFromRegistry` 映射；与 Shell 文档化 DWM 键名并列的 DWORD 开关。
    _ = setValueDword(dwm_key, "Composition", 1);
    _ = setValueDword(dwm_key, "ColorizationGlass", 1);

    const mm_key = createKey(.hklm, session_key, "Memory Management") orelse return;
    _ = setValueDword(mm_key, "DisablePagingExecutive", 0);

    const ms_key = createKey(.hklm, sw_key, "ZirconOSAero") orelse return;
    const nt_key = createKey(.hklm, ms_key, "ZirconOSAero NT") orelse return;
    const cv_key = createKey(.hklm, nt_key, "CurrentVersion") orelse return;
    _ = setValueSz(cv_key, "ProductName", "ZirconOSAero (NT 6.1)");
    _ = setValueSz(cv_key, "CurrentVersion", "6.1");
    _ = setValueDword(cv_key, "CurrentBuildNumber", os_version.buildNumber());
    _ = setValueSz(cv_key, "SystemRoot", "C:\\WINDOWS");
    _ = setValueSz(cv_key, "RegisteredOwner", "ZirconOSAero User");

    const hkcu_root = createKey(.hkcu, NO_PARENT, "HKEY_CURRENT_USER") orelse return;

    const cp_key = createKey(.hkcu, hkcu_root, "Control Panel") orelse return;

    const desktop_key = createKey(.hkcu, cp_key, "Desktop") orelse return;
    _ = setValueSz(desktop_key, "Wallpaper", "");
    _ = setValueSz(desktop_key, "WallpaperStyle", "0");
    _ = setValueDword(desktop_key, "ScreenSaveTimeOut", 600);
    _ = setValueDword(desktop_key, "MenuShowDelay", 400);
    _ = setValueDword(desktop_key, "DragFullWindows", 1);

    const colors_key = createKey(.hkcu, cp_key, "Colors") orelse return;
    _ = setValueSz(colors_key, "Background", "0 78 152");
    _ = setValueSz(colors_key, "Window", "255 255 255");
    _ = setValueSz(colors_key, "ButtonFace", "236 233 216");

    const mouse_key = createKey(.hkcu, cp_key, "Mouse") orelse return;
    hkcu_control_panel_mouse_key = mouse_key;
    _ = setValueSz(mouse_key, "MouseSpeed", "1");
    // 与公开文档中「鼠标」面板 DWORD 名对齐；驱动按 queryValueDword 读取（PointerPolicy_NT61）。
    _ = setValueDword(mouse_key, "MouseSensitivity", 10);
    _ = setValueDword(mouse_key, "MouseThreshold1", 6);
    _ = setValueDword(mouse_key, "MouseThreshold2", 10);
    // `mouse.syncFromRegistry`：`queryValueDword`（与面板常见 DWORD 语义一致）。
    _ = setValueDword(mouse_key, "DoubleClickSpeed", 500);
    _ = setValueDword(mouse_key, "DoubleClickWidth", 4);
    _ = setValueDword(mouse_key, "DoubleClickHeight", 4);

    const sound_key = createKey(.hkcu, cp_key, "Sound") orelse return;
    _ = setValueSz(sound_key, "Beep", "yes");

    const hkcr_root = createKey(.hkcr, NO_PARENT, "HKEY_CLASSES_ROOT") orelse return;

    const txt_key = createKey(.hkcr, hkcr_root, ".txt") orelse return;
    _ = setValueSz(txt_key, "", "txtfile");

    const exe_key = createKey(.hkcr, hkcr_root, ".exe") orelse return;
    _ = setValueSz(exe_key, "", "exefile");

    const dll_key = createKey(.hkcr, hkcr_root, ".dll") orelse return;
    _ = setValueSz(dll_key, "", "dllfile");

    const bmp_key = createKey(.hkcr, hkcr_root, ".bmp") orelse return;
    _ = setValueSz(bmp_key, "", "Paint.Picture");

    const hkcc_root = createKey(.hkcc, NO_PARENT, "HKEY_CURRENT_CONFIG") orelse return;
    const disp_key = createKey(.hkcc, hkcc_root, "Display") orelse return;
    const settings_key = createKey(.hkcc, disp_key, "Settings") orelse return;
    _ = setValueSz(settings_key, "Resolution", "1024,768");
    _ = setValueSz(settings_key, "BitsPerPixel", "32");
    _ = setValueDword(settings_key, "DPI", 96);
}

/// ZirconOSAero **bootstrap overlay**（非完整 RegF）：魔数 `ZOSH1` + 小端记录序列。
/// 每条记录：u16 `path_len`、`path`（UTF-8，NT 风格如 `\Registry\User\Control Panel\Mouse`）、u16 `name_len`、`name`、u8 `type`（1=REG_SZ / 4=REG_DWORD）、载荷。
/// RegF 原生 hive 的加载范围见 [`hive.zig`](hive.zig) 注释；此处仅做 **内存树覆盖**。
pub const Zosh1MergeStats = struct {
    applied: u32 = 0,
    skipped: u32 = 0,
    invalid: bool = false,
};

fn readU16Le(data: []const u8, off: *usize) ?u16 {
    if (off.* + 2 > data.len) return null;
    const v = std.mem.readInt(u16, data[off.*..][0..2], .little);
    off.* += 2;
    return v;
}

fn readU32Le(data: []const u8, off: *usize) ?u32 {
    if (off.* + 4 > data.len) return null;
    const v = std.mem.readInt(u32, data[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

/// 将 ZOSH1 字节合并进已 `populateDefaults` 的内存树（路径须可被 `openKeyByNtPath` 解析）。
pub fn mergeFromZosh1Bytes(data: []const u8) Zosh1MergeStats {
    const magic = "ZOSH1";
    if (data.len < 8) return .{ .invalid = true };
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return .{ .invalid = true };
    if (data[5] != 1) return .{ .invalid = true };
    var off: usize = 8;
    const nrec = readU16Le(data, &off) orelse return .{ .invalid = true };
    var stats = Zosh1MergeStats{};
    var r: u32 = 0;
    while (r < nrec) : (r += 1) {
        const plen = readU16Le(data, &off) orelse return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
        if (off + plen > data.len) return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
        const pth = data[off .. off + plen];
        off += plen;
        const nlen = readU16Le(data, &off) orelse return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
        if (off + nlen > data.len) return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
        const vname = data[off .. off + nlen];
        off += nlen;
        if (off >= data.len) return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
        const vtyp = data[off];
        off += 1;
        switch (vtyp) {
            1 => {
                const dlen = readU16Le(data, &off) orelse return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
                if (off + dlen > data.len) return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
                const d = data[off .. off + dlen];
                off += dlen;
                if (openKeyByNtPath(pth)) |kidx| {
                    if (setValueSz(kidx, vname, d)) stats.applied += 1 else stats.skipped += 1;
                } else stats.skipped += 1;
            },
            4 => {
                const dv = readU32Le(data, &off) orelse return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true };
                if (openKeyByNtPath(pth)) |kidx| {
                    if (setValueDword(kidx, vname, dv)) stats.applied += 1 else stats.skipped += 1;
                } else stats.skipped += 1;
            },
            else => return .{ .applied = stats.applied, .skipped = stats.skipped, .invalid = true },
        }
    }
    return stats;
}

/// `NtCreateKey` / `createKeyFromNtPath` 的创建结果（匿名结构体在 Zig 0.15 中不可跨函数复用为同一类型）。
pub const CreateKeyResult = struct {
    idx: u16,
    created: bool,
};

/// 在已存在父键下创建或打开子键（用于 `NtCreateKey` disposition）。
pub fn createOrOpenChildKey(parent_idx: u16, hive: HiveType, name: []const u8) ?CreateKeyResult {
    if (parent_idx >= key_count or !keys[parent_idx].active) return null;
    if (findDirectChild(parent_idx, name)) |ex| {
        return .{ .idx = ex, .created = false };
    }
    const idx = allocKey() orelse return null;
    var key = &keys[idx];
    key.name_len = strCopy(&key.name, name);
    key.hive = hive;
    key.has_parent = true;
    key.parent_idx = parent_idx;
    var parent = &keys[parent_idx];
    if (parent.subkey_count < MAX_SUBKEYS) {
        parent.subkey_indices[parent.subkey_count] = idx;
        parent.subkey_count += 1;
    } else {
        keys[idx] = .{};
        key_count -= 1;
        return null;
    }
    return .{ .idx = idx, .created = true };
}

/// `\Registry\Machine\...` / `\Registry\User\...` 完整路径上创建末段键。
pub fn createKeyFromNtPath(full_path: []const u8) ?CreateKeyResult {
    const last = std.mem.lastIndexOfScalar(u8, full_path, '\\') orelse return null;
    if (last + 1 >= full_path.len) return null;
    const parent_path = full_path[0..last];
    const child_name = full_path[last + 1 ..];
    if (child_name.len == 0 or child_name.len > MAX_KEY_NAME) return null;
    const parent_idx = openKeyByNtPath(parent_path) orelse return null;
    const hive = keys[parent_idx].hive;
    return createOrOpenChildKey(parent_idx, hive, child_name);
}

fn writeU32Le(dst: []u8, v: u32) void {
    std.mem.writeInt(u32, dst[0..4], v, .little);
}

/// `KeyBasicInformation` 子集：LastWriteTime=0、TitleIndex=0、NameLength、窄字符名（与 syscall 路径一致）。
pub fn enumerateSubkeyBasic(key_idx: u16, index: u32, buf: []u8, result_len: *u32) i32 {
    const ntdll = @import("../libs/ntdll.zig");
    if (key_idx >= key_count or !keys[key_idx].active) return ntdll.STATUS_INVALID_HANDLE;
    const k = &keys[key_idx];
    if (index >= k.subkey_count) return ntdll.STATUS_NO_MORE_ENTRIES;
    const sk = k.subkey_indices[@intCast(index)];
    if (sk >= key_count or !keys[sk].active) return ntdll.STATUS_INVALID_PARAMETER;
    const skname = keys[sk].name[0..keys[sk].name_len];
    const need: u32 = 16 + @as(u32, @intCast(skname.len));
    result_len.* = need;
    if (buf.len < need) return ntdll.STATUS_BUFFER_TOO_SMALL;
    @memset(buf[0..16], 0);
    writeU32Le(buf[8..12], 0);
    writeU32Le(buf[12..16], @intCast(skname.len));
    @memcpy(buf[16..][0..skname.len], skname);
    return ntdll.STATUS_SUCCESS;
}

/// `KeyValueFullInformation` 子集：含值名与数据；`DataOffset` 自结构首字节起算。
pub fn enumerateValueFull(key_idx: u16, index: u32, buf: []u8, result_len: *u32) i32 {
    const ntdll = @import("../libs/ntdll.zig");
    if (key_idx >= key_count or !keys[key_idx].active) return ntdll.STATUS_INVALID_HANDLE;
    const k = &keys[key_idx];
    if (index >= k.value_count) return ntdll.STATUS_NO_MORE_ENTRIES;
    const val = &k.values[@intCast(index)];
    const name = val.name[0..val.name_len];
    const name_off: u32 = 20;
    const after_name = name_off + @as(u32, @intCast(name.len));
    const data_off_u32: u32 = (after_name + 3) & ~@as(u32, 3);
    const data_len: u32 = val.data_len;
    const need = data_off_u32 + data_len;
    result_len.* = need;
    if (buf.len < need) return ntdll.STATUS_BUFFER_TOO_SMALL;
    @memset(buf[0..data_off_u32], 0);
    writeU32Le(buf[0..4], 0);
    writeU32Le(buf[4..8], @intFromEnum(val.value_type));
    writeU32Le(buf[8..12], data_off_u32);
    writeU32Le(buf[12..16], data_len);
    writeU32Le(buf[16..20], @intCast(name.len));
    @memcpy(buf[name_off..][0..name.len], name);
    if (data_off_u32 > name_off + name.len) {
        @memset(buf[name_off + name.len .. data_off_u32], 0);
    }
    @memcpy(buf[data_off_u32..][0..data_len], val.data[0..data_len]);
    return ntdll.STATUS_SUCCESS;
}

/// 将 `Mouse` + `DWM` 默认键导出为 ZOSH1（供 `hive.saveBootstrapSnapshot`）；返回写入字节数。
pub fn serializeMouseAndDwmZosh1(out: []u8) usize {
    const mouse_path = "\\Registry\\User\\Control Panel\\Mouse";
    const dwm_path = "\\Registry\\Machine\\SOFTWARE\\Microsoft\\Windows\\DWM";
    if (out.len < 16) return 0;
    const wmagic = "ZOSH1";
    @memcpy(out[0..wmagic.len], wmagic);
    out[5] = 1;
    out[6] = 0;
    out[7] = 0;
    var pos: usize = 10;
    var nrec: u16 = 0;
    const writeRec = struct {
        fn one(
            base: []u8,
            p: *usize,
            nt_path: []const u8,
            v: *const RegValue,
        ) bool {
            const pth = nt_path;
            const nm = v.name[0..v.name_len];
            const need = 2 + pth.len + 2 + nm.len + 1 + switch (v.value_type) {
                .sz, .expand_sz => 2 + v.data_len,
                .dword => 4,
                else => return false,
            };
            if (p.* + need > base.len) return false;
            std.mem.writeInt(u16, base[p.*..][0..2], @intCast(pth.len), .little);
            p.* += 2;
            @memcpy(base[p.*..][0..pth.len], pth);
            p.* += pth.len;
            std.mem.writeInt(u16, base[p.*..][0..2], @intCast(nm.len), .little);
            p.* += 2;
            @memcpy(base[p.*..][0..nm.len], nm);
            p.* += nm.len;
            switch (v.value_type) {
                .sz, .expand_sz => {
                    base[p.*] = 1;
                    p.* += 1;
                    std.mem.writeInt(u16, base[p.*..][0..2], v.data_len, .little);
                    p.* += 2;
                    @memcpy(base[p.*..][0..v.data_len], v.data[0..v.data_len]);
                    p.* += v.data_len;
                },
                .dword => {
                    base[p.*] = 4;
                    p.* += 1;
                    std.mem.writeInt(u32, base[p.*..][0..4], v.dword_value, .little);
                    p.* += 4;
                },
                else => return false,
            }
            return true;
        }
    }.one;
    if (hkcu_control_panel_mouse_key) |mk| {
        if (getKey(mk)) |kp| {
            var i: u16 = 0;
            while (i < kp.value_count) : (i += 1) {
                if (writeRec(out, &pos, mouse_path, &kp.values[i])) nrec += 1;
            }
        }
    }
    if (hklm_dwm_key) |dk| {
        if (getKey(dk)) |kp| {
            var j: u16 = 0;
            while (j < kp.value_count) : (j += 1) {
                if (writeRec(out, &pos, dwm_path, &kp.values[j])) nrec += 1;
            }
        }
    }
    if (pos > out.len) return 0;
    std.mem.writeInt(u16, out[8..10], nrec, .little);
    return pos;
}

pub fn init() void {
    key_count = 0;
    populateDefaults();
    initialized = true;
    klog.info("Registry: initialized (%u keys, 5 hives loaded)", .{key_count});
}
