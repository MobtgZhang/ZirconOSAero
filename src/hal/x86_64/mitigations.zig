// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/mitigations.zig
// Purpose: x86_64 缓解：SMEP（CR4 位 20）；SMAP（CR4 位 21）可选启用（须在内核中凡访问用户页处配合 stac/clac）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel SDM Vol.3 4.6 Access Rights; AMD APM Vol.2 CR4

fn maxCpuidLeaf() u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 0)),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    _ = ebx ^ ecx ^ edx;
    return eax;
}

/// `CPUID.(EAX=07h,ECX=0):EBX` 位 7 — `SMEP` 支持。
fn cpuid7_ebx() u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 7)),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    _ = eax ^ ecx ^ edx;
    return ebx;
}

fn cr4Read() usize {
    var cr4: usize = undefined;
    asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (cr4),
    );
    return cr4;
}

fn cr4Write(v: usize) void {
    asm volatile ("mov %[r], %%cr4"
        :
        : [r] "r" (v),
    );
}

pub fn enableSmepIfAvailable() void {
    if (maxCpuidLeaf() < 7) return;
    if ((cpuid7_ebx() & (1 << 7)) == 0) return;
    var cr4 = cr4Read();
    cr4 |= @as(usize, 1) << 20;
    cr4Write(cr4);
}

/// `CPUID.(EAX=07h,ECX=0):EBX` 位 20 — `SMAP`。启用后内核直接解引用用户 VA 可能 #PF，须在合法访问用户页前 `stac`、结束后 `clac`（Intel SDM）。
/// 默认 **不** 在 `main` 调用；待全路径审计后再接 `main.zig`。
pub fn enableSmapIfAvailable() void {
    if (maxCpuidLeaf() < 7) return;
    if ((cpuid7_ebx() & (1 << 20)) == 0) return;
    var cr4 = cr4Read();
    cr4 |= @as(usize, 1) << 21;
    cr4Write(cr4);
}

pub fn smepEnabled() bool {
    return (cr4Read() & (@as(usize, 1) << 20)) != 0;
}

pub fn smapEnabled() bool {
    return (cr4Read() & (@as(usize, 1) << 21)) != 0;
}
