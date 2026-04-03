// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/loader/seh_pdata_min.zig
// Purpose: x64 **RUNTIME_FUNCTION / .pdata** 解析与栈展开子集路线图（阶段四 SEH；PE 规范表驱动）。
//
// This is an independent clean-room implementation.
// Ref: PE Format — Exception Directory; https://learn.microsoft.com/windows/win32/debug/pe-format

/// PE `IMAGE_RUNTIME_FUNCTION_ENTRY` 最小视图（BeginAddress/EndAddress/UnwindData RVA）。
pub const RuntimeFunctionEntry = extern struct {
    begin_address: u32,
    end_address: u32,
    unwind_data: u32,
};

/// 占位：自映像 `.pdata` 节查找 `pc_rva` 所在函数项（未实现）。
pub fn findRuntimeFunctionForPc(_pdata: []const RuntimeFunctionEntry, _pc_rva: u32) ?*const RuntimeFunctionEntry {
    _ = _pdata;
    _ = _pc_rva;
    return null;
}
