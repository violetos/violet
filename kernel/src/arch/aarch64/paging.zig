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

const arch = kernel.arch;

const mem = kernel.mem;
const paging = mem.paging;

comptime {
    if (paging.page_levels == 4) std.debug.assert(paging.page_size <= 16 * 1024);
}

// --- arch/aarch64/paging.zig --- //

inline fn applyAttributes(pte: *ArchEntry, attrs: paging.Attributes) void {
    pte.lower_attrs.attr_index = switch (attrs.mem_type) {
        .writeback => .writeback,
        .write_combining => .write_combining,
        .device => .device,
    };

    pte.lower_attrs.not_global = !attrs.permissions.global;
    pte.lower_attrs.shareability = .inner_shareable;
    pte.lower_attrs.access_flag = true;

    if (attrs.permissions.user) {
        pte.lower_attrs.ap = if (attrs.permissions.writable) .priv_rw_unp_rw else .priv_rw_unp_ro;
        pte.upper_attrs.uxn = !attrs.permissions.executable;
        pte.upper_attrs.pxn = true;
    } else {
        pte.lower_attrs.ap = if (attrs.permissions.writable) .priv_rw else .priv_ro;
        pte.upper_attrs.pxn = !attrs.permissions.executable;
        pte.upper_attrs.uxn = true;
    }
}

inline fn extractAttributes(pte: ArchEntry) paging.Attributes {
    const mem_type: paging.MemType = switch (pte.lower_attrs.attr_index) {
        .writeback => .writeback,
        .write_combining => .write_combining,
        .device => .device,
    };

    var user = false;
    var writable = false;
    var executable = false;

    switch (pte.lower_attrs.ap) {
        .priv_rw => {
            user = false;
            writable = true;
        },
        .priv_rw_unp_rw => {
            user = true;
            writable = true;
        },
        .priv_ro => {
            user = false;
            writable = false;
        },
        .priv_rw_unp_ro => {
            user = true;
            writable = false;
        },
    }

    if (user) {
        executable = !pte.upper_attrs.uxn;
    } else {
        executable = !pte.upper_attrs.pxn;
    }

    return .{
        .permissions = .{
            .user = user,
            .writable = writable,
            .executable = executable,
            .global = !pte.lower_attrs.not_global,
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

            applyAttributes(&pte, attrs);

            pte.software.state = .uncommitted;

            if (is_base_page) {
                pte.format.valid = true;
                pte.format.kind = 1;
                pte.address.output_address = @truncate(kernel.mem.zero_page_pa >> paging.offset_bits);

                pte.software.uncommitted_ap = pte.lower_attrs.ap;
                pte.lower_attrs.ap = if (attrs.permissions.user) .priv_rw_unp_ro else .priv_ro;
            }
        },
        .table => |pa| {
            pte.format.valid = true;
            pte.format.kind = 1;

            pte.address.output_address = @truncate(pa >> paging.offset_bits);
        },
        .leaf => |leaf| {
            pte.format.valid = true;
            pte.format.kind = if (is_base_page) 1 else 0;

            pte.address.output_address = @truncate(leaf.physical_address >> paging.offset_bits);
            applyAttributes(&pte, leaf.attributes);
        },
    }

    return pte.raw;
}

pub fn decode(level: paging.Level, raw: u64) paging.Entry {
    const pte: ArchEntry = .{ .raw = raw };

    if (!pte.format.valid) {
        return switch (pte.software.state) {
            .none => .unmapped,
            .guard => .guard,
            .uncommitted => .{ .uncommitted = extractAttributes(pte) },
        };
    }

    const is_base_page = (level == 0);

    if (is_base_page and pte.software.state == .uncommitted) {
        var attrs = extractAttributes(pte);

        const real_ap = pte.software.uncommitted_ap;
        attrs.permissions.writable = (real_ap == .priv_rw or real_ap == .priv_rw_unp_rw);

        return .{ .uncommitted = attrs };
    }

    const pa = @as(u64, pte.address.output_address) << paging.offset_bits;

    if (is_base_page) {
        return .{ .leaf = .{
            .physical_address = pa,
            .attributes = extractAttributes(pte),
        } };
    } else {
        if (pte.format.kind == 1) {
            return .{ .table = pa };
        } else {
            return .{ .leaf = .{
                .physical_address = pa,
                .attributes = extractAttributes(pte),
            } };
        }
    }
}

pub fn canMapAt(level: paging.Level) bool {
    return switch (level) {
        1 => true,
        2 => paging.page_size == 4 * 1024,
        else => false,
    };
}

pub fn activate(low_half_root: ?u64, high_half_root: u64) void {
    if (low_half_root) |lhr| {
        arch.registers.storeTtbr0El1(lhr);
    }

    arch.registers.storeTtbr1El1(high_half_root);

    kernel.arch.cpu.syncMem();
}

pub fn flush(scope: paging.FlushScope) void {
    switch (scope) {
        .all => {
            asm volatile (
                \\ dsb ishst
                \\ tlbi vmalle1is
                \\ dsb ish
                \\ isb
                ::: .{ .memory = true });
        },
        .address => |addr| {
            const va_shifted = addr.va >> paging.offset_bits;

            if (addr.global) {
                asm volatile (
                    \\ dsb ishst
                    \\ tlbi vaae1is, %[val]
                    \\ dsb ish
                    \\ isb
                    :
                    : [val] "r" (va_shifted),
                    : .{ .memory = true });
            } else {
                asm volatile (
                    \\ dsb ishst
                    \\ tlbi vae1is, %[val]
                    \\ dsb ish
                    \\ isb
                    :
                    : [val] "r" (va_shifted),
                    : .{ .memory = true });
            }
        },
    }
}

pub const low_half_max: u64 = (@as(u64, 1) << @intCast(paging.va_bits)) - 1;
pub const high_half_min: u64 = ~low_half_max;

pub fn isCanonical(va: u64) bool {
    return va <= low_half_max or va >= high_half_min;
}

pub fn getBootTable() u64 {
    return arch.registers.loadTtbr1El1();
}

const ArchEntry = packed union {
    pub const empty: ArchEntry = .{ .raw = 0 };

    raw: u64,
    format: FormatView,
    address: AddressView,
    lower_attrs: LowerAttrsView,
    upper_attrs: UpperAttrsView,
    software: SoftwareView,
};

const FormatView = packed struct(u64) {
    valid: bool = false, // bit 0

    kind: u1 = 0, // bit 1

    _ignored_high: u62 = 0, // bits 2-63
};

const AddressView = packed struct(u64) {
    const gap_bits = paging.offset_bits - 12;
    const addr_bits = 48 - paging.offset_bits;

    _ignored_low: u12 = 0, // bits 0-11

    _reserved0: std.meta.Int(.unsigned, gap_bits) = 0,
    output_address: std.meta.Int(.unsigned, addr_bits) = 0,

    _ignored_high: u16 = 0, // bits 48-63
};

const ApEncoding = enum(u2) {
    priv_rw = 0b00,
    priv_rw_unp_rw = 0b01,
    priv_ro = 0b10,
    priv_rw_unp_ro = 0b11,
};

const LowerAttrsView = packed struct(u64) {
    _ignored_low: u2 = 0, // bits 0-1

    attr_index: enum(u3) { // bits 2-4
        writeback = 0,
        write_combining = 1,
        device = 2,
    } = .writeback,

    non_secure: bool = false, // bit 5

    ap: ApEncoding = .priv_rw, // bits 6-7

    shareability: enum(u2) { // bits 8-9
        non_shareable = 0b00,
        outer_shareable = 0b10,
        inner_shareable = 0b11,
    } = .inner_shareable,

    access_flag: bool = true, // bit 10
    not_global: bool = false, // bit 11

    _ignored_high: u52 = 0, // bits 12-63
};

const UpperAttrsView = packed struct(u64) {
    _ignored_low: u50 = 0, // bits 0-49

    guarded_page: bool = false, // bit 50
    dirty_modifier: u1 = 0, // bit 51
    contiguous: bool = false, // bit 52
    pxn: bool = false, // bit 53
    uxn: bool = false, // bit 54

    _ignored_high: u9 = 0, // bits 55-63
};

const SoftwareView = packed struct(u64) {
    _ignored_low: u55 = 0, // bits 0-54

    state: enum(u2) { // bits 55-56
        none = 0,
        uncommitted = 1,
        guard = 2,
    } = .none,

    uncommitted_ap: ApEncoding = .priv_rw, // bits 57-58

    _ignored_high: u5 = 0, // bits 59-63
};
