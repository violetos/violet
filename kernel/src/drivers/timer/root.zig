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
const basalt = @import("basalt");

const log = std.log.scoped(.ints);

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const drivers = kernel.drivers;
const sched = kernel.sched;
const mem = kernel.mem;
const intc = drivers.intc;

const Future = sched.Future;

// --- drivers/timer/root.zig --- //

pub fn handle() !void {
    try sched.acknowledge(.none);
}

pub var impl: ?TimerImpl = null;

pub inline fn initPerCpu() !void {
    return impl.?.vtable.initPerCpu(impl.?.ptr);
}

pub inline fn now() u64 {
    return impl.?.vtable.now(impl.?.ptr);
}

pub inline fn arm(deadline_ns: u64) void {
    impl.?.vtable.arm(impl.?.ptr, deadline_ns);
}

pub inline fn setMask(masked: bool) void {
    impl.?.vtable.setMask(impl.?.ptr, masked);
}

pub inline fn onInterrupt() void {
    impl.?.vtable.onInterrupt(impl.?.ptr);
}

pub const TimerImpl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        initPerCpu: *const fn (ptr: *anyopaque) anyerror!void,
        now: *const fn (ptr: *anyopaque) u64,
        arm: *const fn (ptr: *anyopaque, deadline_ns: u64) void,
        setMask: *const fn (ptr: *anyopaque, masked: bool) void,
        onInterrupt: *const fn (ptr: *anyopaque) void,
    };
};

pub const TimerContext = struct {
    waited_queue: mem.utils.BinaryHeap(Future.Ref, .min, true),

    pub fn init(self: *TimerContext) !void {
        self.waited_queue = .empty;
    }

    pub fn current() *TimerContext {
        return &kernel.cpu.CpuContext.current().?.sched_context;
    }

    pub fn updateHhdm(self: *TimerContext) void {
        _ = self;
        // no task at this point
    }
};
