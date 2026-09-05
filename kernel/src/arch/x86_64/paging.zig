// Copyright (c) 2024-2026 YiraSan
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const paging = mem.paging;

comptime {
    if (paging.page_size != 4 * 1024) @compileError("x86_64 only supports a 4 KiB base page size");
}

// --- arch/x86_64/paging.zig --- //

fn patIndex(mem_type: paging.MemType) u3 {
    return switch (mem_type) {
        .writeback => 0,
        .write_combining => 1,
        .device => 2,
    };
}

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, sub: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\ cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
        : .{ .memory = true });

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;

    asm volatile (
        \\ rdmsr
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
        : .{ .memory = true });

    return (@as(u64, hi) << 32) | lo;
}

fn wrmsr(msr: u32, value: u64) void {
    const lo: u32 = @truncate(value);
    const hi: u32 = @truncate(value >> 32);

    asm volatile (
        \\ wrmsr
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
        : .{ .memory = true });
}

pub const ConfigureError = error{PatNotSupported};

pub fn configure() ConfigureError!void {
    const uc: u64 = 0x00;
    const wc: u64 = 0x01;
    const wt: u64 = 0x04;
    const wb: u64 = 0x06;

    const pat_value: u64 =
        (wb << 0) |
        (wc << 8) |
        (uc << 16) |
        (wt << 24) |
        (wb << 32) |
        (wc << 40) |
        (uc << 48) |
        (wt << 56);

    wrmsr(0x277, pat_value);
}

pub fn getBootTable() u64 {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );

    return cr3 & ~@as(u64, 0xFFF);
}

inline fn applyAttributes(pte: *CommonView, attrs: paging.Attributes, is_base_page: bool) void {
    pte.writable = attrs.permissions.writable;
    pte.user = attrs.permissions.user;
    pte.xd = !attrs.permissions.executable;
    pte.global = attrs.permissions.global;

    pte.accessed = true;
    pte.dirty = attrs.permissions.writable;

    const idx = patIndex(attrs.mem_type);
    pte.pwt = (idx & 0b001) != 0;
    pte.pcd = (idx & 0b010) != 0;

    if (is_base_page) {
        pte.ps_or_pat = (idx & 0b100) != 0;
    }
}

inline fn extractAttributes(pte: CommonView, is_base_page: bool) paging.Attributes {
    var idx: u3 = 0;
    idx |= @intFromBool(pte.pwt);
    idx |= @as(u3, @intFromBool(pte.pcd)) << 1;

    if (is_base_page) {
        idx |= @as(u3, @intFromBool(pte.ps_or_pat)) << 2;
    } else {
        idx |= @as(u3, @truncate(pte.address & 1)) << 2;
    }

    const mem_type: paging.MemType = switch (idx) {
        0 => .writeback,
        1 => .write_combining,
        2 => .device,
        else => .writeback,
    };

    return .{
        .permissions = .{
            .user = pte.user,
            .writable = pte.writable,
            .executable = !pte.xd,
            .global = pte.global,
        },
        .mem_type = mem_type,
    };
}

pub fn encode(level: paging.Level, entry: paging.Entry) u64 {
    var pte = ArchEntry.empty;

    const is_base_page = (level == 0);

    switch (entry) {
        .unmapped => {},
        .guard => pte.software.state = .guard,
        .uncommitted => |attrs| {
            std.debug.assert(attrs.mem_type != .device);

            if (is_base_page) {
                pte.common.present = true;
                applyAttributes(&pte.common, attrs, true);

                pte.rsw.uncommitted = true;
                pte.rsw.real_writable = attrs.permissions.writable;

                pte.common.writable = false;
                pte.common.dirty = false;

                pte.common.address = @truncate(kernel.mem.zero_page_pa >> paging.offset_bits);
            } else {
                pte.software.state = .uncommitted;
                pte.software.writable = attrs.permissions.writable;
                pte.software.executable = attrs.permissions.executable;
                pte.software.user = attrs.permissions.user;
                pte.software.global = attrs.permissions.global;
                pte.software.mem_type = switch (attrs.mem_type) {
                    .writeback => .writeback,
                    .write_combining => .write_combining,
                    .device => .device,
                };
            }
        },
        .table => |pa| {
            pte.common.present = true;
            pte.common.writable = true;
            pte.common.user = true;

            pte.common.address = @truncate(pa >> paging.offset_bits);
        },
        .leaf => |leaf| {
            pte.common.present = true;
            applyAttributes(&pte.common, leaf.attributes, is_base_page);

            var addr: u40 = @truncate(leaf.physical_address >> paging.offset_bits);

            if (!is_base_page) {
                pte.common.ps_or_pat = true;

                const idx = patIndex(leaf.attributes.mem_type);
                if ((idx & 0b100) != 0) addr |= 1;
            }

            pte.common.address = addr;
        },
    }

    return pte.raw;
}

pub fn decode(level: paging.Level, raw: u64) paging.Entry {
    const pte: ArchEntry = .{ .raw = raw };
    const is_base_page = (level == 0);

    if (!pte.common.present) {
        const sw = pte.software;
        return switch (sw.state) {
            .none => .unmapped,
            .guard => .guard,
            .uncommitted => .{ .uncommitted = .{
                .permissions = .{
                    .writable = sw.writable,
                    .executable = sw.executable,
                    .user = sw.user,
                    .global = sw.global,
                },
                .mem_type = switch (sw.mem_type) {
                    .writeback => .writeback,
                    .write_combining => .write_combining,
                    .device => .device,
                },
            } },
        };
    }

    if (is_base_page and pte.rsw.uncommitted) {
        var attrs = extractAttributes(pte.common, true);
        attrs.permissions.writable = pte.rsw.real_writable;
        return .{ .uncommitted = attrs };
    }

    const pa = @as(u64, pte.common.address) << paging.offset_bits;

    if (is_base_page) {
        return .{ .leaf = .{
            .physical_address = pa,
            .attributes = extractAttributes(pte.common, true),
        } };
    }

    if (pte.common.ps_or_pat) {
        const clean_pa = pa & ~(@as(u64, 1) << paging.offset_bits);
        return .{ .leaf = .{
            .physical_address = clean_pa,
            .attributes = extractAttributes(pte.common, false),
        } };
    }

    return .{ .table = pa };
}

var pdpe1gb_checked = false;
var pdpe1gb_supported = false;

fn hasPdpe1Gb() bool {
    if (pdpe1gb_checked) return pdpe1gb_supported;

    const features = cpuid(0x8000_0001, 0);
    pdpe1gb_supported = (features.edx & (1 << 26)) != 0;
    pdpe1gb_checked = true;

    return pdpe1gb_supported;
}

pub fn canMapAt(level: paging.Level) bool {
    return switch (level) {
        0 => true, // 4 KiB pages
        1 => true, // 2 MiB pages
        2 => hasPdpe1Gb(), // 1 GiB pages (CPUID.80000001H:EDX[26])
        else => false,
    };
}

pub fn activate(low_half_root: ?u64, high_half_root: u64) void {
    if (low_half_root) |lhr| {
        const user_pml4 = mem.toHhdm([512]u64, lhr);
        const kernel_pml4 = mem.toHhdm([512]u64, high_half_root);

        @memcpy(user_pml4[256..512], kernel_pml4[256..512]);

        asm volatile (
            \\ mov %[pa], %%cr3
            :
            : [pa] "r" (lhr),
            : .{ .memory = true });
    } else {
        asm volatile (
            \\ mov %[pa], %%cr3
            :
            : [pa] "r" (high_half_root),
            : .{ .memory = true });
    }
}

pub fn flush(scope: paging.FlushScope) void {
    switch (scope) {
        .all => {
            asm volatile (
                \\ mov %%cr3, %%rax
                \\ mov %%rax, %%cr3
                ::: .{ .rax = true, .memory = true });
        },
        .address => |addr| {
            asm volatile (
                \\ invlpg (%[va])
                :
                : [va] "r" (addr.va),
                : .{ .memory = true });
        },
    }
}

pub const low_half_max: u64 = (@as(u64, 1) << @intCast(paging.va_bits - 1)) - 1;
pub const high_half_min: u64 = ~low_half_max;

pub fn isCanonical(va: u64) bool {
    return va <= low_half_max or va >= high_half_min;
}

const ArchEntry = packed union {
    pub const empty: ArchEntry = .{ .raw = 0 };

    raw: u64,
    common: CommonView,
    rsw: RswView,
    software: SoftwareView,
};

const CommonView = packed struct(u64) {
    present: bool = false, // bit 0
    writable: bool = false, // bit 1
    user: bool = false, // bit 2
    pwt: bool = false, // bit 3
    pcd: bool = false, // bit 4
    accessed: bool = false, // bit 5
    dirty: bool = false, // bit 6 (leaf only)
    ps_or_pat: bool = false, // bit 7 (PAT for 4 KiB leaf, PS for PD/PDPT entries)
    global: bool = false, // bit 8 (leaf only)

    _avail_low: u3 = 0, // bits 9-11, software-available (see RswView)

    address: u40 = 0, // bits 12-51

    _ignored_high: u11 = 0, // bits 52-62

    xd: bool = false, // bit 63
};

const RswView = packed struct(u64) {
    _low: u9 = 0, // bits 0-8

    uncommitted: bool = false, // bit 9
    real_writable: bool = false, // bit 10

    _high: u53 = 0, // bits 11-63
};

const SoftwareView = packed struct(u64) {
    present: bool = false, // bit 0

    state: enum(u2) { // bits 1-2
        none = 0,
        uncommitted = 1,
        guard = 2,
    } = .none,

    writable: bool = false, // bit 3
    executable: bool = false, // bit 4
    user: bool = false, // bit 5
    global: bool = false, // bit 6

    mem_type: enum(u2) { // bits 7-8
        writeback = 0,
        write_combining = 1,
        device = 2,
    } = .writeback,

    _ignored: u55 = 0, // bits 9-63
};
