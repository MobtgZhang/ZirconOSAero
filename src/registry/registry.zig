//! ZirconOS Registry (NT-style)
//! Provides a hierarchical key-value store for system and application settings.
//! Modeled after the NT Registry with hives:
//!   HKLM  - HKEY_LOCAL_MACHINE (hardware, drivers, system services)
//!   HKCU  - HKEY_CURRENT_USER  (user preferences)
//!   HKCR  - HKEY_CLASSES_ROOT  (file associations)
//!   HKU   - HKEY_USERS         (all user profiles)
//!   HKCC  - HKEY_CURRENT_CONFIG (current hardware profile)
//!
//! Reference: ReactOS ntoskrnl/config/

const klog = @import("../rtl/klog.zig");

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

pub fn getKey(idx: u16) ?*const RegKey {
    if (idx >= key_count or !keys[idx].active) return null;
    return &keys[idx];
}

pub fn getKeyCount() usize {
    return key_count;
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
    _ = setValueSz(env_key, "OS", "ZirconOS_NT");

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
    _ = setValueSz(sys_desc, "SystemBiosVersion", "ZirconOS BIOS v1.0");

    const cpu_key = createKey(.hklm, sys_desc, "CentralProcessor") orelse return;
    const cpu0 = createKey(.hklm, cpu_key, "0") orelse return;
    _ = setValueSz(cpu0, "ProcessorNameString", "ZirconOS Virtual CPU");
    _ = setValueDword(cpu0, "~MHz", 3000);
    _ = setValueSz(cpu0, "VendorIdentifier", "GenuineIntel");

    const sw_key = createKey(.hklm, hklm_root, "SOFTWARE") orelse return;
    const ms_key = createKey(.hklm, sw_key, "ZirconOS") orelse return;
    const nt_key = createKey(.hklm, ms_key, "ZirconOS NT") orelse return;
    const cv_key = createKey(.hklm, nt_key, "CurrentVersion") orelse return;
    _ = setValueSz(cv_key, "ProductName", "ZirconOS v1.0");
    _ = setValueSz(cv_key, "CurrentVersion", "5.1");
    _ = setValueDword(cv_key, "CurrentBuildNumber", 2600);
    _ = setValueSz(cv_key, "SystemRoot", "C:\\WINDOWS");
    _ = setValueSz(cv_key, "RegisteredOwner", "ZirconOS User");

    const hkcu_root = createKey(.hkcu, NO_PARENT, "HKEY_CURRENT_USER") orelse return;

    const cp_key = createKey(.hkcu, hkcu_root, "Control Panel") orelse return;

    const desktop_key = createKey(.hkcu, cp_key, "Desktop") orelse return;
    _ = setValueSz(desktop_key, "Wallpaper", "");
    _ = setValueSz(desktop_key, "WallpaperStyle", "0");
    _ = setValueDword(desktop_key, "ScreenSaveTimeOut", 600);

    const colors_key = createKey(.hkcu, cp_key, "Colors") orelse return;
    _ = setValueSz(colors_key, "Background", "0 78 152");
    _ = setValueSz(colors_key, "Window", "255 255 255");
    _ = setValueSz(colors_key, "ButtonFace", "236 233 216");

    const mouse_key = createKey(.hkcu, cp_key, "Mouse") orelse return;
    _ = setValueSz(mouse_key, "MouseSpeed", "1");
    _ = setValueSz(mouse_key, "DoubleClickSpeed", "500");

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

pub fn init() void {
    key_count = 0;
    populateDefaults();
    initialized = true;
    klog.info("Registry: initialized (%u keys, 5 hives loaded)", .{key_count});
}
