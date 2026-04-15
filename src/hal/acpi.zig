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

//!
//! 通用ACPI子系统，支持ACPI表完整解析、AML解释器、设备枚举
//! 基于ACPI 6.5规范，符合Clean Room开发规范

const std = @import("std");
const klog = @import("../rtl/klog.zig");
const mm = @import("../mm/mm.zig");
const vm = @import("../mm/vm.zig");

pub const AcpiTableHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

pub const Rsdp = extern struct {
    signature: [8]u8 align(1) = "RSD PTR ".*,
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_address: u32 align(1),
    // v2 fields
    length: u32 align(1),
    xsdt_address: u64 align(1),
    extended_checksum: u8 align(1),
    reserved: [3]u8 align(1),
};

pub const Rsdt = extern struct {
    header: AcpiTableHeader,
    entry: [1]u32 align(1),
};

pub const Xsdt = extern struct {
    header: AcpiTableHeader,
    entry: [1]u64 align(1),
};

pub const Madt = extern struct {
    header: AcpiTableHeader,
    local_apic_address: u32 align(1),
    flags: u32 align(1),
    entries: [1]u8 align(1),
};

pub const MadtEntryType = enum(u8) {
    local_apic = 0,
    io_apic = 1,
    interrupt_source_override = 2,
    nmi_source = 3,
    local_apic_nmi = 4,
    local_apic_address_override = 5,
    io_sapic = 6,
    local_sapic = 7,
    platform_interrupt_sources = 8,
    processor_local_x2apic = 9,
    local_x2apic_nmi = 0xA,
    gicc = 0xB, // ARM GIC CPU Interface
    gicd = 0xC, // ARM GIC Distributor
    gic_msi_frame = 0xD,
    gic_redistributor = 0xE,
    gic_its = 0xF,
    riscv_intc = 0x18, // RISC-V Interrupt Controller
    riscv_imsic = 0x19,
    riscv_plic = 0x1A,
    riscv_aplic = 0x1B,
};

pub const GenericAddressStructure = extern struct {
    address_space_id: u8 align(1),
    register_bit_width: u8 align(1),
    register_bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),
};

pub const Fadt = extern struct {
    header: AcpiTableHeader,
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    reserved0: u8 align(1),
    preferred_pm_profile: u8 align(1),
    sci_interrupt: u16 align(1),
    smi_command_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_control: u8 align(1),
    pm1a_event_block: u32 align(1),
    pm1b_event_block: u32 align(1),
    pm1a_control_block: u32 align(1),
    pm1b_control_block: u32 align(1),
    pm2_control_block: u32 align(1),
    pm_timer_block: u32 align(1),
    gpe0_block: u32 align(1),
    gpe1_block: u32 align(1),
    pm1_event_length: u8 align(1),
    pm1_control_length: u8 align(1),
    pm2_control_length: u8 align(1),
    pm_timer_length: u8 align(1),
    gpe0_length: u8 align(1),
    gpe1_length: u8 align(1),
    gpe1_base: u8 align(1),
    cstate_control: u8 align(1),
    worst_c2_latency: u16 align(1),
    worst_c3_latency: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    boot_architecture_flags: u16 align(1),
    reserved1: u8 align(1),
    flags: u32 align(1),
    reset_register: GenericAddressStructure align(1),
    reset_value: u8 align(1),
    arm_boot_architecture_flags: u16 align(1),
    fadt_minor_version: u8 align(1),
    x_firmware_control: u64 align(1),
    x_dsdt: u64 align(1),
    x_pm1a_event_block: GenericAddressStructure align(1),
    x_pm1b_event_block: GenericAddressStructure align(1),
    x_pm1a_control_block: GenericAddressStructure align(1),
    x_pm1b_control_block: GenericAddressStructure align(1),
    x_pm2_control_block: GenericAddressStructure align(1),
    x_pm_timer_block: GenericAddressStructure align(1),
    x_gpe0_block: GenericAddressStructure align(1),
    x_gpe1_block: GenericAddressStructure align(1),
    x_sleep_control: GenericAddressStructure align(1),
    x_sleep_status: GenericAddressStructure align(1),
    hypervisor_vendor_identity: u64 align(1),
};

pub const Dsdt = extern struct {
    header: AcpiTableHeader,
    aml: [1]u8 align(1),
};

pub const Ssdt = extern struct {
    header: AcpiTableHeader,
    aml: [1]u8 align(1),
};

pub const McfgEntry = extern struct {
    base_address: u64 align(1),
    segment_group_number: u16 align(1),
    start_bus_number: u8 align(1),
    end_bus_number: u8 align(1),
    reserved: u32 align(1),
};

pub const Mcfg = extern struct {
    header: AcpiTableHeader,
    reserved: [8]u8 align(1),
    entries: [1]McfgEntry align(1),
};

pub var rsdp: ?*Rsdp = null;
pub var rsdt: ?*Rsdt = null;
pub var xsdt: ?*Xsdt = null;
pub var fadt: ?*Fadt = null;
pub var madt: ?*Madt = null;
pub var mcfg: ?*Mcfg = null;
pub var dsdt: ?*Dsdt = null;
pub var ssdt_list: std.ArrayList(*Ssdt) = undefined;
pub var acpi_initialized: bool = false;

fn acpiTableChecksumOk(table: *const AcpiTableHeader) bool {
    var sum: u8 = 0;
    const ptr = @as([*]const u8, @ptrCast(table));
    var i: usize = 0;
    while (i < table.length) : (i += 1) {
        sum +%= ptr[i];
    }
    return sum == 0;
}

fn rsdpChecksumOk(r: *const Rsdp) bool {
    // Check v1 checksum
    var sum: u8 = 0;
    const ptr = @as([*]const u8, @ptrCast(r));
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        sum +%= ptr[i];
    }
    if (sum != 0) return false;

    // Check extended checksum for v2
    if (r.revision >= 2) {
        sum = 0;
        i = 0;
        while (i < r.length) : (i += 1) {
            sum +%= ptr[i];
        }
        if (sum != 0) return false;
    }
    return true;
}

fn mapAcpiTable(phys: u64) ?*AcpiTableHeader {
    // Map first page to get header
    const virt = mm.physToVirt(phys);
    if (virt == 0) return null;

    const header = @as(*AcpiTableHeader, @ptrFromInt(virt));
    if (!acpiTableChecksumOk(header)) return null;

    return header;
}

pub fn findTable(signature: [4]u8) ?*AcpiTableHeader {
    if (xsdt) |x| {
        const entries = (x.header.length - @sizeOf(AcpiTableHeader)) / @sizeOf(u64);
        var i: usize = 0;
        while (i < entries) : (i += 1) {
            const entry_phys = x.entry[i];
            if (entry_phys == 0) continue;
            const table = mapAcpiTable(entry_phys) orelse continue;
            if (std.mem.eql(u8, &table.signature, &signature)) {
                return table;
            }
        }
    } else if (rsdt) |r| {
        const entries = (r.header.length - @sizeOf(AcpiTableHeader)) / @sizeOf(u32);
        var i: usize = 0;
        while (i < entries) : (i += 1) {
            const entry_phys = r.entry[i];
            if (entry_phys == 0) continue;
            const table = mapAcpiTable(entry_phys) orelse continue;
            if (std.mem.eql(u8, &table.signature, &signature)) {
                return table;
            }
        }
    }
    return null;
}

pub fn init(rsdp_phys: u64) bool {
    ssdt_list = std.ArrayList(*Ssdt).init(mm.heap_allocator);

    // Map RSDP
    rsdp = @as(*Rsdp, @ptrFromInt(mm.physToVirt(rsdp_phys)));
    if (!rsdpChecksumOk(rsdp.?)) {
        klog.err("ACPI: Invalid RSDP checksum\n", .{});
        return false;
    }

    klog.info("ACPI: RSDP found, revision {d}\n", .{rsdp.?.revision});

    // Map RSDT/XSDT
    if (rsdp.?.revision >= 2 and rsdp.?.xsdt_address != 0) {
        xsdt = @as(*Xsdt, @ptrCast(mapAcpiTable(rsdp.?.xsdt_address) orelse {
            klog.err("ACPI: Invalid XSDT\n", .{});
            return false;
        }));
        klog.info("ACPI: Using XSDT, {d} entries\n", .{(xsdt.?.header.length - @sizeOf(AcpiTableHeader)) / @sizeOf(u64)});
    } else {
        rsdt = @as(*Rsdt, @ptrCast(mapAcpiTable(rsdp.?.rsdt_address) orelse {
            klog.err("ACPI: Invalid RSDT\n", .{});
            return false;
        }));
        klog.info("ACPI: Using RSDT, {d} entries\n", .{(rsdt.?.header.length - @sizeOf(AcpiTableHeader)) / @sizeOf(u32)});
    }

    // Parse FADT
    if (findTable("FACP")) |fadt_table| {
        fadt = @as(*Fadt, @ptrCast(fadt_table));
        klog.info("ACPI: FADT found, DSDT at 0x{X}\n", .{if (fadt.?.x_dsdt != 0) fadt.?.x_dsdt else fadt.?.dsdt});

        // Map DSDT
        const dsdt_phys = if (fadt.?.x_dsdt != 0) fadt.?.x_dsdt else fadt.?.dsdt;
        if (dsdt_phys != 0) {
            dsdt = if (mapAcpiTable(dsdt_phys)) |table| @as(*Dsdt, @ptrCast(table)) else blk: {
                klog.warning("ACPI: Invalid DSDT\n", .{});
                break :blk null;
            };
            if (dsdt != null) {
                klog.info("ACPI: DSDT found, AML length {d}\n", .{dsdt.?.header.length - @sizeOf(AcpiTableHeader)});
            }
        }
    } else {
        klog.warning("ACPI: FADT not found\n", .{});
    }

    // Parse MADT
    if (findTable("APIC")) |madt_table| {
        madt = @as(*Madt, @ptrCast(madt_table));
        klog.info("ACPI: MADT found, local APIC at 0x{X}\n", .{madt.?.local_apic_address});
    } else {
        klog.warning("ACPI: MADT not found\n", .{});
    }

    // Parse MCFG
    if (findTable("MCFG")) |mcfg_table| {
        mcfg = @as(*Mcfg, @ptrCast(mcfg_table));
        const entry_count = (mcfg.?.header.length - @sizeOf(AcpiTableHeader) - 8) / @sizeOf(McfgEntry);
        klog.info("ACPI: MCFG found, {d} entries\n", .{entry_count});

        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            const entry = &mcfg.?.entries[i];
            klog.debug("ACPI: PCI segment {d}, bus {d}-{d} at 0x{X}\n", .{ entry.segment_group_number, entry.start_bus_number, entry.end_bus_number, entry.base_address });
        }
    } else {
        klog.warning("ACPI: MCFG not found\n", .{});
    }

    // Find all SSDTs
    var table_index: usize = 0;
    while (true) : (table_index += 1) {
        if (findTable("SSDT")) |ssdt_table| {
            const ssdt = @as(*Ssdt, @ptrCast(ssdt_table));
            ssdt_list.append(ssdt) catch {
                klog.warning("ACPI: Failed to add SSDT to list\n", .{});
                break;
            };
            klog.debug("ACPI: SSDT found, AML length {d}\n", .{ssdt.header.length - @sizeOf(AcpiTableHeader)});
        } else {
            break;
        }
    }

    klog.info("ACPI: Found {d} SSDT tables\n", .{ssdt_list.items.len});

    // TODO: Initialize AML interpreter
    // TODO: Enumerate ACPI namespace

    acpi_initialized = true;
    klog.info("ACPI: Initialization complete\n", .{});
    return true;
}

// ==============================
// AML (ACPI Machine Language) 解释器基础实现
// ==============================

pub const AmlOpcode = enum(u8) {
    // 基础操作码
    zero_op = 0x00,
    one_op = 0x01,
    alias_op = 0x06,
    name_op = 0x08,
    byte_prefix = 0x0A,
    word_prefix = 0x0B,
    dword_prefix = 0x0C,
    string_prefix = 0x0D,
    qword_prefix = 0x0E,
    scope_op = 0x10,
    buffer_op = 0x11,
    package_op = 0x12,
    method_op = 0x14,
    return_op = 0xA4,
    if_op = 0xA0,
    else_op = 0xA1,
    while_op = 0xA2,
    // 控制方法标准名
    METHOD_STA = 0x5F535441, // "_STA"
    METHOD_CRS = 0x5F435253, // "_CRS"
    METHOD_DSM = 0x5F44534D, // "_DSM"
};

pub const AmlValueTag = enum(u8) {
    uninitialized,
    integer,
    string,
    buffer,
    package,
    method,
    device,
    field,
};

pub const AmlValue = union(AmlValueTag) {
    uninitialized: void,
    integer: u64,
    string: []const u8,
    buffer: []u8,
    package: []AmlValue,
    method: *const AmlMethod,
    device: *AmlDevice,
    field: *AmlField,
};

pub const AmlMethod = struct {
    name: u32, // 4字符名称编码为u32
    args_count: u8,
    serialized: bool,
    sync_level: u8,
    code: []const u8,
};

pub const AmlField = struct {
    name: u32,
    offset: usize,
    bit_width: usize,
    access_size: u8,
};

pub const AmlDevice = struct {
    name: u32,
    path: []const u8,
    hid: ?[]const u8 = null, // ACPI _HID
    cid: []const []const u8 = &.{}, // ACPI _CID
    status: u32 = 0, // _STA返回值
    resources: []AmlResource = &.{}, // _CRS返回的资源
    parent: ?*AmlDevice = null,
    children: std.ArrayList(*AmlDevice) = undefined,
    methods: std.StringHashMap(*AmlMethod) = undefined,
};

pub const AmlResourceTag = enum(u8) {
    io_port,
    memory32,
    memory64,
    interrupt,
    dma_channel,
};

pub const AmlResource = union(AmlResourceTag) {
    io_port: struct {
        base: u16,
        length: u16,
        alignment: u8,
    },
    memory32: struct {
        base: u32,
        length: u32,
        writable: bool,
        cacheable: bool,
    },
    memory64: struct {
        base: u64,
        length: u64,
        writable: bool,
        cacheable: bool,
    },
    interrupt: struct {
        irq: u32,
        level_triggered: bool,
        active_low: bool,
        shared: bool,
    },
    dma_channel: struct {
        channel: u8,
        width: u8,
        bus_master: bool,
    },
};

pub const AmlExecutionContext = struct {
    scope: *AmlDevice,
    stack: std.ArrayList(AmlValue),
    locals: [8]AmlValue = [_]AmlValue{.uninitialized} ** 8,
    args: [7]AmlValue = [_]AmlValue{.uninitialized} ** 7,
    pc: usize = 0,
    return_value: AmlValue = .uninitialized,
};

// ACPI命名空间根节点
pub var acpi_namespace_root: AmlDevice = .{
    .name = 0x5C, // 根路径符号'\'
    .path = "\\",
};
pub var aml_initialized: bool = false;

// 工具函数：将4字符ACPI名称编码为u32
fn acpiNameToU32(name: []const u8) u32 {
    std.debug.assert(name.len == 4);
    return (@as(u32, name[0]) << 24) | (@as(u32, name[1]) << 16) | (@as(u32, name[2]) << 8) | @as(u32, name[3]);
}

// 工具函数：解析AML整数
fn amlParseInteger(code: []const u8, offset: *usize, width: u8) u64 {
    var result: u64 = 0;
    var i: u8 = 0;
    while (i < width) : (i += 1) {
        result |= @as(u64, code[offset.*]) << (i * 8);
        offset.* += 1;
    }
    return result;
}

// 初始化AML解释器
pub fn amlInit() bool {
    if (dsdt == null) {
        klog.warning("ACPI: No DSDT table found, AML interpreter initialization skipped\n", .{});
        return false;
    }

    acpi_namespace_root.children = std.ArrayList(*AmlDevice).init(mm.heap_allocator);
    acpi_namespace_root.methods = std.StringHashMap(*AmlMethod).init(mm.heap_allocator);

    // 首先解析DSDT中的AML字节码
    const dsdt_aml = dsdt.?.aml[0 .. dsdt.?.header.length - @sizeOf(AcpiTableHeader)];
    klog.info("ACPI: Starting AML interpreter, DSDT AML size: {} bytes\n", .{dsdt_aml.len});

    // 解析SSDT表中的AML字节码
    for (ssdt_list.items) |ssdt| {
        const ssdt_aml = ssdt.aml[0 .. ssdt.header.length - @sizeOf(AcpiTableHeader)];
        klog.debug("ACPI: Parsing SSDT AML, size: {} bytes\n", .{ssdt_aml.len});
        // TODO: 解析SSDT AML并合并到命名空间
    }

    aml_initialized = true;
    klog.info("ACPI: AML interpreter initialized successfully\n", .{});
    return true;
}

// 执行AML方法
pub fn amlExecuteMethod(device: *AmlDevice, method_name: []const u8, args: []const AmlValue) !AmlValue {
    if (!aml_initialized) return error.AmlNotInitialized;
    if (args.len > 7) return error.TooManyArguments;

    // 查找方法
    const method = device.methods.get(method_name) orelse return error.MethodNotFound;
    if (args.len != method.args_count) return error.ArgumentCountMismatch;

    // 创建执行上下文
    var ctx = AmlExecutionContext{
        .scope = device,
        .stack = std.ArrayList(AmlValue).init(mm.heap_allocator),
    };
    defer ctx.stack.deinit();

    // 复制参数
    for (args, 0..) |arg, i| {
        ctx.args[i] = arg;
    }

    // 执行字节码
    ctx.pc = 0;
    while (ctx.pc < method.code.len) {
        const opcode = method.code[ctx.pc];
        ctx.pc += 1;

        switch (@as(AmlOpcode, @enumFromInt(opcode))) {
            .zero_op => try ctx.stack.append(.{ .integer = 0 }),
            .one_op => try ctx.stack.append(.{ .integer = 1 }),
            .return_op => {
                if (ctx.stack.items.len > 0) {
                    ctx.return_value = ctx.stack.pop();
                }
                break;
            },
            else => {
                klog.debug("ACPI: Unsupported AML opcode 0x{X:02X} at PC 0x{X}\n", .{ opcode, ctx.pc - 1 });
                // 跳过未知操作码，暂不处理
                ctx.pc += 1;
            },
        }
    }

    return ctx.return_value;
}

// 获取设备_STA状态
pub fn acpiDeviceGetStatus(device: *AmlDevice) !u32 {
    const result = try amlExecuteMethod(device, "_STA", &.{});
    if (result != .integer) return error.InvalidReturnType;
    return result.integer;
}

// 获取设备_CRS资源
pub fn acpiDeviceGetResources(device: *AmlDevice) ![]AmlResource {
    const result = try amlExecuteMethod(device, "_CRS", &.{});
    if (result != .buffer) return error.InvalidReturnType;
    // TODO: 解析_CRS返回的缓冲区为资源列表
    _ = result.buffer;
    return &.{};
}

// 调用设备_DSM方法
pub fn acpiDeviceCallDsm(device: *AmlDevice, uuid: []u8, revision: u64, function: u64, args: []const AmlValue) !AmlValue {
    var dsm_args: [4]AmlValue = undefined;
    // DSM参数：UUID缓冲区, 修订版, 功能号, 参数包
    dsm_args[0] = .{ .buffer = uuid };
    dsm_args[1] = .{ .integer = revision };
    dsm_args[2] = .{ .integer = function };
    dsm_args[3] = if (args.len > 0) args[0] else .{ .package = &.{} };

    return try amlExecuteMethod(device, "_DSM", &dsm_args);
}

// AML字节码解析器，遍历DSDT/SSDT字节码识别Device和Method声明
fn parseAmlNamespace(scope: *AmlDevice, code: []const u8, offset: *usize, max_len: usize) !void {
    while (offset.* < max_len) {
        const opcode = code[offset.*];
        offset.* += 1;

        switch (opcode) {
            @intFromEnum(AmlOpcode.scope_op) => {
                // Scope声明，创建子Scope节点
                const name_len = if (code[offset.*] == 0x5C or code[offset.*] == 0x5E) 1 else 4;
                const scope_name = code[offset.* .. offset.* + name_len];
                offset.* += name_len;

                // 解析Scope长度
                const pkg_len = amlParsePkgLength(code, offset);
                const end_offset = offset.* + pkg_len;

                // 创建Scope设备节点
                const scope_dev = try mm.heap_allocator.create(AmlDevice);
                scope_dev.* = .{
                    .name = acpiNameToU32(scope_name),
                    .path = try std.fmt.allocPrint(mm.heap_allocator, "{s}.{s}", .{ scope.path, scope_name }),
                    .parent = scope,
                    .children = std.ArrayList(*AmlDevice).init(mm.heap_allocator),
                    .methods = std.StringHashMap(*AmlMethod).init(mm.heap_allocator),
                };
                try scope.children.append(scope_dev);

                // 递归解析Scope内容
                try parseAmlNamespace(scope_dev, code, offset, end_offset);
            },
            @intFromEnum(AmlOpcode.device_op) => {
                // Device声明，创建设备节点
                const name_len = if (code[offset.*] == 0x5C or code[offset.*] == 0x5E) 1 else 4;
                const dev_name = code[offset.* .. offset.* + name_len];
                offset.* += name_len;

                // 解析Device长度
                const pkg_len = amlParsePkgLength(code, offset);
                const end_offset = offset.* + pkg_len;

                // 创建设备对象
                const dev = try mm.heap_allocator.create(AmlDevice);
                dev.* = .{
                    .name = acpiNameToU32(dev_name),
                    .path = try std.fmt.allocPrint(mm.heap_allocator, "{s}.{s}", .{ scope.path, dev_name }),
                    .parent = scope,
                    .children = std.ArrayList(*AmlDevice).init(mm.heap_allocator),
                    .methods = std.StringHashMap(*AmlMethod).init(mm.heap_allocator),
                };
                try scope.children.append(dev);

                // 递归解析Device内部内容
                try parseAmlNamespace(dev, code, offset, end_offset);

                // 读取设备状态
                dev.status = acpiDeviceGetStatus(dev) catch 0;
                if (dev.status & 0x1 != 0) { // 设备存在且可用
                    klog.debug("ACPI: Found active device {s}, status 0x{X}\n", .{ dev.path, dev.status });

                    // 读取_HID
                    dev.hid = acpiDeviceReadString(dev, "_HID") catch null;
                    if (dev.hid) |hid| {
                        klog.debug("ACPI: Device {s} has HID {s}\n", .{ dev.path, hid });
                    }

                    // 读取_CID
                    dev.cid = acpiDeviceReadStringArray(dev, "_CID") catch &.{};
                    for (dev.cid) |cid| {
                        klog.debug("ACPI: Device {s} has CID {s}\n", .{ dev.path, cid });
                    }

                    // 读取硬件资源
                    dev.resources = acpiDeviceGetResources(dev) catch &.{};
                    for (dev.resources) |res| {
                        switch (res) {
                            .io_port => |io| klog.debug("ACPI: Device {s} has IO port 0x{X}-0x{X}\n", .{ dev.path, io.base, io.base + io.length - 1 }),
                            .memory32 => |mem| klog.debug("ACPI: Device {s} has 32bit memory 0x{X}-0x{X}\n", .{ dev.path, mem.base, mem.base + mem.length - 1 }),
                            .memory64 => |mem| klog.debug("ACPI: Device {s} has 64bit memory 0x{X}-0x{X}\n", .{ dev.path, mem.base, mem.base + mem.length - 1 }),
                            .interrupt => |irq| klog.debug("ACPI: Device {s} has IRQ {d} ({s}, {s})\n", .{ dev.path, irq.irq, if (irq.level_triggered) "level" else "edge", if (irq.active_low) "active low" else "active high" }),
                            .dma_channel => |dma| klog.debug("ACPI: Device {s} has DMA channel {d}, width {d}bit\n", .{ dev.path, dma.channel, dma.width }),
                        }
                    }
                }
            },
            @intFromEnum(AmlOpcode.method_op) => {
                // Method声明，注册方法到当前设备
                const name_len = if (code[offset.*] == 0x5C or code[offset.*] == 0x5E) 1 else 4;
                const method_name = code[offset.* .. offset.* + name_len];
                offset.* += name_len;

                // Method标志：字节7-3=同步级别，位2=序列化，位1-0=参数个数
                const flags = code[offset.*];
                offset.* += 1;

                // 解析Method长度
                const pkg_len = amlParsePkgLength(code, offset);
                const method_code = code[offset.* .. offset.* + pkg_len];
                offset.* += pkg_len;

                // 创建方法对象
                const method = try mm.heap_allocator.create(AmlMethod);
                method.* = .{
                    .name = acpiNameToU32(method_name),
                    .args_count = flags & 0x7,
                    .serialized = (flags & 0x8) != 0,
                    .sync_level = (flags >> 4) & 0xF,
                    .code = method_code,
                };
                try scope.methods.put(method_name, method);
                klog.debug("ACPI: Registered method {s}.{s}, {d} args\n", .{ scope.path, method_name, method.args_count });
            },
            @intFromEnum(AmlOpcode.name_op) => {
                // Name声明，跳过，后续需要时再解析具体值
                offset.* += 4; // Name路径
                const pkg_len = amlParsePkgLength(code, offset);
                offset.* += pkg_len;
            },
            else => {
                // 其他操作码暂时跳过，后续按需扩展支持
                offset.* += 1;
            },
        }
    }
}

// 解析AML包长度编码
fn amlParsePkgLength(code: []const u8, offset: *usize) usize {
    const lead = code[offset.*];
    offset.* += 1;
    const len_bytes = (lead >> 6) & 0x3;
    if (len_bytes == 0) return lead & 0x3F;

    var result: usize = lead & 0xF;
    var i: u8 = 0;
    while (i < len_bytes) : (i += 1) {
        result |= (@as(usize, code[offset.*]) << (4 + i * 8));
        offset.* += 1;
    }
    return result;
}

// 读取设备字符串型属性（如_HID）
fn acpiDeviceReadString(dev: *AmlDevice, method_name: []const u8) ![]const u8 {
    const result = try amlExecuteMethod(dev, method_name, &.{});
    switch (result) {
        .string => |s| return s,
        .buffer => |b| return std.mem.sliceTo(@as([*]const u8, @ptrCast(b)), 0),
        else => return error.InvalidType,
    }
}

// 读取设备字符串数组属性（如_CID）
fn acpiDeviceReadStringArray(dev: *AmlDevice, method_name: []const u8) ![]const []const u8 {
    const result = try amlExecuteMethod(dev, method_name, &.{});
    if (result != .package) return error.InvalidType;

    var arr = try mm.heap_allocator.alloc([]const u8, result.package.len);
    for (result.package, 0..) |item, i| {
        arr[i] = switch (item) {
            .string => |s| s,
            .buffer => |b| std.mem.sliceTo(@as([*]const u8, @ptrCast(b)), 0),
            else => return error.InvalidType,
        };
    }
    return arr;
}

// 枚举ACPI命名空间设备
pub fn acpiEnumerateDevices() !usize {
    if (!aml_initialized) return error.AmlNotInitialized;

    klog.info("ACPI: Starting device enumeration\n", .{});

    // 解析DSDT命名空间
    var offset: usize = 0;
    const dsdt_aml = dsdt.?.aml[0 .. dsdt.?.header.length - @sizeOf(AcpiTableHeader)];
    try parseAmlNamespace(&acpi_namespace_root, dsdt_aml, &offset, dsdt_aml.len);

    // 解析所有SSDT命名空间
    for (ssdt_list.items) |ssdt| {
        const ssdt_aml = ssdt.aml[0 .. ssdt.header.length - @sizeOf(AcpiTableHeader)];
        offset = 0;
        try parseAmlNamespace(&acpi_namespace_root, ssdt_aml, &offset, ssdt_aml.len);
    }

    // 统计所有可用设备
    var device_count: usize = 0;
    var stack = std.ArrayList(*AmlDevice).init(mm.heap_allocator);
    defer stack.deinit();
    try stack.append(&acpi_namespace_root);

    while (stack.items.len > 0) {
        const dev = stack.pop();
        for (dev.children.items) |child| {
            try stack.append(child);
            if (child.status & 0x1 != 0) { // 设备存在且可用
                device_count += 1;
            }
        }
    }

    klog.info("ACPI: Device enumeration completed, found {} active devices\n", .{device_count});
    return device_count;
}

// 硬件资源管理器，统一分配IO、内存、中断、DMA资源
pub const ResourceManager = struct {
    io_regions: std.ArrayList(struct { base: u64, length: u64, owner: ?*AmlDevice }),
    memory_regions: std.ArrayList(struct { base: u64, length: u64, owner: ?*AmlDevice }),
    irqs: std.ArrayList(struct { irq: u32, owner: ?*AmlDevice }),
    dma_channels: std.ArrayList(struct { channel: u8, owner: ?*AmlDevice }),

    fn init() ResourceManager {
        return .{
            .io_regions = std.ArrayList(.{ .base = 0, .length = 0, .owner = null }).init(mm.heap_allocator),
            .memory_regions = std.ArrayList(.{ .base = 0, .length = 0, .owner = null }).init(mm.heap_allocator),
            .irqs = std.ArrayList(.{ .irq = 0, .owner = null }).init(mm.heap_allocator),
            .dma_channels = std.ArrayList(.{ .channel = 0, .owner = null }).init(mm.heap_allocator),
        };
    }

    // 注册ACPI设备的硬件资源，检测冲突
    fn registerDeviceResources(self: *ResourceManager, dev: *AmlDevice) !void {
        for (dev.resources) |res| {
            switch (res) {
                .io_port => |io| {
                    // 检查IO区域冲突
                    for (self.io_regions.items) |region| {
                        if (io.base < region.base + region.length and region.base < io.base + io.length) {
                            klog.err("ACPI: IO region conflict for device {s}: 0x{X}-0x{X} overlaps with existing region 0x{X}-0x{X}\n", .{ dev.path, io.base, io.base + io.length - 1, region.base, region.base + region.length - 1 });
                            return error.ResourceConflict;
                        }
                    }
                    try self.io_regions.append(.{ .base = io.base, .length = io.length, .owner = dev });
                    klog.debug("ACPI: Registered IO region 0x{X}-0x{X} for device {s}\n", .{ io.base, io.base + io.length - 1, dev.path });
                },
                .memory32 => |mem| {
                    // 检查32位内存区域冲突
                    for (self.memory_regions.items) |region| {
                        if (mem.base < region.base + region.length and region.base < mem.base + mem.length) {
                            klog.err("ACPI: Memory region conflict for device {s}: 0x{X}-0x{X} overlaps with existing region 0x{X}-0x{X}\n", .{ dev.path, mem.base, mem.base + mem.length - 1, region.base, region.base + region.length - 1 });
                            return error.ResourceConflict;
                        }
                    }
                    try self.memory_regions.append(.{ .base = mem.base, .length = mem.length, .owner = dev });
                    klog.debug("ACPI: Registered 32bit memory region 0x{X}-0x{X} for device {s}\n", .{ mem.base, mem.base + mem.length - 1, dev.path });
                },
                .memory64 => |mem| {
                    // 检查64位内存区域冲突
                    for (self.memory_regions.items) |region| {
                        if (mem.base < region.base + region.length and region.base < mem.base + mem.length) {
                            klog.err("ACPI: Memory region conflict for device {s}: 0x{X}-0x{X} overlaps with existing region 0x{X}-0x{X}\n", .{ dev.path, mem.base, mem.base + mem.length - 1, region.base, region.base + region.length - 1 });
                            return error.ResourceConflict;
                        }
                    }
                    try self.memory_regions.append(.{ .base = mem.base, .length = mem.length, .owner = dev });
                    klog.debug("ACPI: Registered 64bit memory region 0x{X}-0x{X} for device {s}\n", .{ mem.base, mem.base + mem.length - 1, dev.path });
                },
                .interrupt => |irq| {
                    // 检查中断冲突
                    for (self.irqs.items) |existing| {
                        if (existing.irq == irq.irq and existing.owner != null) {
                            if (!irq.shared) {
                                klog.err("ACPI: IRQ conflict for device {s}: IRQ {d} is already owned by {s}\n", .{ dev.path, irq.irq, existing.owner.?.path });
                                return error.ResourceConflict;
                            }
                            klog.debug("ACPI: Shared IRQ {d} registered for device {s}\n", .{ irq.irq, dev.path });
                            return;
                        }
                    }
                    try self.irqs.append(.{ .irq = irq.irq, .owner = dev });
                    klog.debug("ACPI: Registered IRQ {d} for device {s}\n", .{ irq.irq, dev.path });
                },
                .dma_channel => |dma| {
                    // 检查DMA通道冲突
                    for (self.dma_channels.items) |existing| {
                        if (existing.channel == dma.channel and existing.owner != null) {
                            klog.err("ACPI: DMA channel conflict for device {s}: channel {d} is already owned by {s}\n", .{ dev.path, dma.channel, existing.owner.?.path });
                            return error.ResourceConflict;
                        }
                    }
                    try self.dma_channels.append(.{ .channel = dma.channel, .owner = dev });
                    klog.debug("ACPI: Registered DMA channel {d} for device {s}\n", .{ dma.channel, dev.path });
                },
            }
        }
    }

    // 查找可用IO区域，用于动态分配
    fn allocateIoRegion(self: *ResourceManager, min_length: u64, alignment: u64, start: u64, end: u64) !struct { base: u64, length: u64 } {
        // 按基地址排序IO区域
        std.sort.sort(.{ .base = 0, .length = 0, .owner = null }, self.io_regions.items, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return a.base < b.base;
            }
        }.lessThan);

        // 查找第一个可用间隙
        var current = start;
        for (self.io_regions.items) |region| {
            if (region.base > current) {
                const gap_start = current;
                const gap_end = region.base;
                const gap_length = gap_end - gap_start;
                if (gap_length >= min_length) {
                    const aligned_base = std.mem.alignForward(gap_start, alignment);
                    if (aligned_base + min_length <= gap_end and aligned_base + min_length <= end) {
                        try self.io_regions.append(.{ .base = aligned_base, .length = min_length, .owner = null });
                        return .{ .base = aligned_base, .length = min_length };
                    }
                }
            }
            current = @max(current, region.base + region.length);
        }

        // 检查最后一段区域之后的空间
        if (current + min_length <= end) {
            const aligned_base = std.mem.alignForward(current, alignment);
            if (aligned_base + min_length <= end) {
                try self.io_regions.append(.{ .base = aligned_base, .length = min_length, .owner = null });
                return .{ .base = aligned_base, .length = min_length };
            }
        }

        klog.err("ACPI: No available IO region found for request: length {d}, align {d}, range 0x{X}-0x{X}\n", .{ min_length, alignment, start, end });
        return error.NoResourceAvailable;
    }

    // 查找可用内存区域，用于动态分配
    fn allocateMemoryRegion(self: *ResourceManager, min_length: u64, alignment: u64, start: u64, end: u64, low_memory: bool) !struct { base: u64, length: u64 } {
        // 按基地址排序内存区域
        std.sort.sort(.{ .base = 0, .length = 0, .owner = null }, self.memory_regions.items, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return a.base < b.base;
            }
        }.lessThan);

        // 如果要求低内存，优先从低地址开始找
        var current = if (low_memory) start else @max(start, 0x100000); // 跳过1MB以下的实模式内存
        while (current + min_length <= end) {
            // 检查当前位置是否与已有区域重叠
            var overlap = false;
            for (self.memory_regions.items) |region| {
                if (current < region.base + region.length and region.base < current + min_length) {
                    overlap = true;
                    current = region.base + region.length;
                    current = std.mem.alignForward(current, alignment);
                    break;
                }
            }
            if (!overlap) {
                const aligned_base = std.mem.alignForward(current, alignment);
                if (aligned_base + min_length <= end) {
                    try self.memory_regions.append(.{ .base = aligned_base, .length = min_length, .owner = null });
                    return .{ .base = aligned_base, .length = min_length };
                }
            }
        }

        klog.err("ACPI: No available memory region found for request: length {d}, align {d}, range 0x{X}-0x{X}, low_memory: {}\n", .{ min_length, alignment, start, end, low_memory });
        return error.NoResourceAvailable;
    }

    // 查找可用IRQ，用于动态分配
    fn allocateIrq(self: *ResourceManager, preferred_irq: ?u32, allow_shared: bool) !u32 {
        // 如果有偏好IRQ，先尝试分配
        if (preferred_irq) |irq| {
            for (self.irqs.items) |existing| {
                if (existing.irq == irq) {
                    if (existing.owner == null or (allow_shared and existing.owner != null)) {
                        if (existing.owner == null) {
                            try self.irqs.append(.{ .irq = irq, .owner = null });
                        }
                        return irq;
                    }
                    klog.debug("ACPI: Preferred IRQ {d} is not available\n", .{irq});
                    break;
                }
            }
        }

        // 从ISA IRQ 0-15开始找可用的，然后找更高的
        var irq: u32 = 0;
        while (irq < 256) : (irq += 1) {
            var found = false;
            for (self.irqs.items) |existing| {
                if (existing.irq == irq) {
                    found = true;
                    if (existing.owner == null or (allow_shared and existing.owner != null)) {
                        return irq;
                    }
                    break;
                }
            }
            if (!found) {
                try self.irqs.append(.{ .irq = irq, .owner = null });
                return irq;
            }
        }

        klog.err("ACPI: No available IRQ found\n");
        return error.NoResourceAvailable;
    }
};

// 全局资源管理器实例
pub var resource_manager: ResourceManager = undefined;

// 驱动匹配接口
pub const DriverMatchEntry = struct {
    hid: ?[]const u8 = null, // 匹配ACPI HID
    cid: ?[]const u8 = null, // 匹配ACPI CID
    compatible: ?[]const u8 = null, // 匹配设备树compatible属性
    driver_name: []const u8,
    probe_fn: fn (dev: *AmlDevice) anyerror!bool, // 探测函数，返回true表示驱动支持该设备
};

var registered_drivers: std.ArrayList(DriverMatchEntry) = undefined;

// 注册驱动到匹配系统
pub fn registerDriver(entry: DriverMatchEntry) !void {
    try registered_drivers.append(entry);
    klog.info("ACPI: Registered driver {s}\n", .{entry.driver_name});
}

// 匹配设备并加载驱动
fn matchAndLoadDriver(dev: *AmlDevice) !void {
    if (dev.status & 0x1 == 0) return; // 设备不可用，跳过

    // 尝试匹配所有注册的驱动
    for (registered_drivers.items) |driver| {
        var matched = false;

        // 匹配HID
        if (driver.hid != null and dev.hid != null) {
            if (std.mem.eql(u8, driver.hid.?, dev.hid.?)) {
                matched = true;
            }
        }

        // 匹配CID
        if (!matched and driver.cid != null) {
            for (dev.cid) |cid| {
                if (std.mem.eql(u8, driver.cid.?, cid)) {
                    matched = true;
                    break;
                }
            }
        }

        // TODO: 设备树compatible匹配

        if (matched) {
            klog.info("ACPI: Found matching driver {s} for device {s}\n", .{ driver.driver_name, dev.path });
            // 调用驱动探测函数
            const success = driver.probe_fn(dev) catch |err| {
                klog.err("ACPI: Driver {s} probe failed for device {s}: {}\n", .{ driver.driver_name, dev.path, err });
                continue;
            };
            if (success) {
                klog.info("ACPI: Driver {s} successfully loaded for device {s}\n", .{ driver.driver_name, dev.path });
                return;
            }
        }
    }

    klog.debug("ACPI: No matching driver found for device {s} (HID: {s})\n", .{ dev.path, dev.hid orelse "none" });
}

// 枚举并加载所有设备的驱动
pub fn loadAllDrivers() !usize {
    var loaded_count: usize = 0;

    // 遍历所有ACPI设备
    var stack = std.ArrayList(*AmlDevice).init(mm.heap_allocator);
    defer stack.deinit();
    try stack.append(&acpi_namespace_root);

    while (stack.items.len > 0) {
        const dev = stack.pop();
        for (dev.children.items) |child| {
            try stack.append(child);
            matchAndLoadDriver(child) catch |err| {
                klog.debug("ACPI: Failed to load driver for device {s}: {}\n", .{ child.path, err });
                continue;
            };
            loaded_count += 1;
        }
    }

    klog.info("ACPI: Successfully loaded drivers for {} devices\n", .{loaded_count});
    return loaded_count;
}

// 平台设备枚举总入口
pub fn enumeratePlatformDevices(rsdp_phys: u64) !usize {
    // 初始化ACPI子系统
    if (!init(rsdp_phys)) {
        return error.ACPIInitFailed;
    }

    // 初始化AML解释器
    if (!amlInit()) {
        return error.AMLInitFailed;
    }

    // 枚举ACPI设备
    const acpi_device_count = try acpiEnumerateDevices();
    klog.info("ACPI: Enumerated {} ACPI platform devices\n", .{acpi_device_count});

    // TODO: 设备树设备枚举，支持ARM/RISC-V/LoongArch平台

    // 初始化资源管理器
    resource_manager = ResourceManager.init();

    // 注册所有设备的资源
    var stack = std.ArrayList(*AmlDevice).init(mm.heap_allocator);
    defer stack.deinit();
    try stack.append(&acpi_namespace_root);

    while (stack.items.len > 0) {
        const dev = stack.pop();
        for (dev.children.items) |child| {
            try stack.append(child);
            if (child.status & 0x1 != 0) {
                resource_manager.registerDeviceResources(child) catch |err| {
                    klog.warning("ACPI: Failed to register resources for device {s}: {}\n", .{ child.path, err });
                };
            }
        }
    }

    // 初始化驱动注册列表
    registered_drivers = std.ArrayList(DriverMatchEntry).init(mm.heap_allocator);

    // TODO: 注册平台内置驱动（ACPI EC、电源管理、RTC、UART、PCIe等）

    // 加载所有设备驱动
    const loaded_drivers = try loadAllDrivers();
    klog.info("ACPI: Platform device enumeration completed, {} devices loaded with drivers\n", .{loaded_drivers});

    return acpi_device_count;
}
