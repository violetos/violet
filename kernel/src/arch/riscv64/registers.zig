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

// --- arch/riscv64/registers.zig --- //

pub inline fn csrRead(comptime name: []const u8) u64 {
    return asm volatile ("csrr %[ret], " ++ name
        : [ret] "=r" (-> u64),
    );
}

pub inline fn csrWrite(comptime name: []const u8, value: u64) void {
    asm volatile ("csrw " ++ name ++ ", %[val]"
        :
        : [val] "r" (value),
        : .{ .memory = true });
}

pub const Satp = packed struct(u64) {
    pub const Mode = enum(u4) {
        bare = 0,
        sv39 = 8,
        sv48 = 9,
        sv57 = 10,
    };

    ppn: u44 = 0,
    asid: u16 = 0,
    mode: Mode = .bare,

    pub inline fn load() Satp {
        return @bitCast(csrRead("satp"));
    }

    pub inline fn store(self: Satp) void {
        csrWrite("satp", @bitCast(self));
    }
};

pub const Sstatus = packed struct(u64) {
    _reserved0: u1 = 0,
    sie: bool = false,
    _reserved1: u3 = 0,
    spie: bool = false,
    ube: bool = false,
    _reserved2: u1 = 0,
    spp: enum(u1) { user = 0, supervisor = 1 } = .user,
    vs: u2 = 0,
    _reserved3: u2 = 0,
    fs: enum(u2) { off = 0, initial = 1, clean = 2, dirty = 3 } = .off,
    xs: u2 = 0,
    _reserved4: u1 = 0,
    sum: bool = false,
    mxr: bool = false,
    _reserved5: u12 = 0,
    uxl: u2 = 0,
    _reserved6: u29 = 0,
    sd: bool = false,

    pub inline fn load() Sstatus {
        return @bitCast(csrRead("sstatus"));
    }

    pub inline fn store(self: Sstatus) void {
        csrWrite("sstatus", @bitCast(self));
    }
};
