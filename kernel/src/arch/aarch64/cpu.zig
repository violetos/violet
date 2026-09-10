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

// --- arch/aarch64/cpu.zig --- //

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub inline fn pause() void {
    asm volatile ("yield");
}

pub inline fn syncMem() void {
    asm volatile (
        \\ dsb ish
        \\ isb
        ::: .{ .memory = true });
}

pub inline fn syncStores() void {
    asm volatile (
        \\ dsb ishst
        \\ isb
        ::: .{ .memory = true });
}

pub inline fn getPerCpu() u64 {
    return arch.registers.loadTpidrEl1();
}

pub inline fn setPerCpu(val: u64) void {
    return arch.registers.storeTpidrEl1(val);
}
