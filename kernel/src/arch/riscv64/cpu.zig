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

// --- arch/riscv64/cpu.zig --- //

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub inline fn pause() void {
    asm volatile ("fence" ::: .{ .memory = true });
}

pub inline fn syncMem() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

pub inline fn syncStores() void {
    asm volatile ("fence w, w" ::: .{ .memory = true });
}

pub inline fn getPerCpu() u64 {
    const anchor_ptr = asm volatile ("csrr %[v], sscratch"
        : [v] "=r" (-> u64),
    );
    return @as(*const kernel.arch.interrupts.TrapAnchor, @ptrFromInt(anchor_ptr)).cpu_context;
}

pub inline fn setPerCpu(val: u64) void {
    const anchor_ptr = asm volatile ("csrr %[v], sscratch"
        : [v] "=r" (-> u64),
    );
    @as(*kernel.arch.interrupts.TrapAnchor, @ptrFromInt(anchor_ptr)).cpu_context = val;
}
