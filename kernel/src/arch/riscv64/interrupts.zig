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

// --- arch/riscv64/interrupts.zig --- //

pub fn init() !void {}

pub const InterruptsContext = struct {
    pub fn init(self: *InterruptsContext) !void {
        _ = self;
    }

    pub fn current() *InterruptsContext {
        return &kernel.cpu.CpuContext.current().?.interrupts_context;
    }

    pub fn updateHhdm(self: *InterruptsContext) void {
        _ = self;
    }
};

pub const ReducedFrame = extern struct {
    pub fn setArg(self: *ReducedFrame, comptime index: usize, value: u64) void {
        _ = self;
        _ = index;
        _ = value;

        unreachable;
    }

    pub fn getArg(self: *ReducedFrame, comptime index: usize) u64 {
        _ = self;
        _ = index;

        unreachable;
    }
};

pub const ExtendedFrame = extern struct {};

pub const InterruptData = struct {
    pub fn init(data: *InterruptData, privileged: bool) !void {
        _ = data;
        _ = privileged;
    }

    pub fn deinit(data: *InterruptData) void {
        _ = data;
    }
};

// --- //

pub const InterruptState = enum(u1) { disabled = 0, enabled = 1 };

pub inline fn set(new: InterruptState) InterruptState {
    const old: u64 = switch (new) {
        .disabled => asm volatile ("csrrc %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (@as(u64, 0x2)),
        ),
        .enabled => asm volatile ("csrrs %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (@as(u64, 0x2)),
        ),
    };
    return if ((old & 0x2) != 0) .enabled else .disabled;
}
