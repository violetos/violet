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
const utils = mem.utils;
const RwLock = utils.RwLock;
const BinaryHeap = utils.BinaryHeap;

const drivers = kernel.drivers;
const timer = drivers.timer;

// --- exports --- //

pub const Future = @import("Future.zig");
pub const Process = @import("Process.zig");
pub const Task = @import("Task.zig");

// --- sched/root.zig --- //

pub const SchedContext = struct {
    current_task: ?Task.Ref,
    in_kernel: bool,

    /// protect run_queue.
    run_lock: RwLock,
    run_queue: BinaryHeap(Task.Ref, .min, true),

    pub fn init(self: *SchedContext) !void {
        self.current_task = null;
        self.in_kernel = true;
    }

    pub fn current() *SchedContext {
        return &kernel.cpu.CpuContext.current().?.sched_context;
    }

    pub fn updateHhdm(self: *SchedContext) void {
        _ = self;
        // no task at this point
    }
};

// --- //

pub var newbie_lock: RwLock = .{};
pub var newbie_queue: BinaryHeap(Task.Ref, .min, true) = .empty;

pub fn push(task: Task.Ref) !void {
    const saved = newbie_lock.acquire(.write, 0);
    defer newbie_lock.release(.write, saved);

    try newbie_queue.push(.{
        .priority = kernel.drivers.timer.now(),
        .value = task,
    });
}

pub fn acknowledge(circumstance: Circumstance) !void {
    const ctx = SchedContext.current();

    var newbie: ?Task.Ref = null;
    if (newbie_lock.tryAcquire(.write)) |saved| {
        defer newbie_lock.release(.write, saved);

        if (newbie_queue.pop(.first)) |popped| {
            newbie = popped.value;
        }
    }

    const saved = ctx.run_lock.acquire(.write, 0);
    defer ctx.run_lock.release(.write, saved);

    const now = timer.now();

    if (newbie) |newbie_ref| {
        const newbie_task: *Task = newbie_ref.payload();

        try ctx.run_queue.push(.{
            .priority = now + newbie_task.setting.getDelay(),
            .value = newbie_ref,
        });
    }

    if (ctx.current_task) |current_task| {
        const task: *Task = current_task.payload();

        var elapsed, const overflowed = @subWithOverflow(now, task.last_resume);
        if (overflowed == 1) elapsed = 0;

        var should_prempt = false;
        if (circumstance == .event) {
            if (ctx.run_queue.peek(.first)) |popped| {
                const may_task: *Task = popped.value.payload();

                if (may_task.state.load(.acquire) == .suspended and
                    may_task.setting.priority == .realtime and
                    task.setting.priority != .realtime)
                {
                    should_prempt = true;
                }
            }
        }

        if (isNearlyComplete(elapsed, task.setting.getQuantum()) or should_prempt) {
            task.state.store(.pending, .release);

            try ctx.run_queue.push(.{
                .priority = now + task.setting.getDelay(),
                .value = current_task,
            });

            ctx.current_task = null;
        }
    }

    if (ctx.current_task == null) {
        if (ctx.run_queue.pop(.first)) |popped| {
            const task_ref = popped.value;
            const task: *Task = task_ref.payload();

            task.last_resume = now;
            const last_state = task.state.swap(.running, .acq_rel);
            {
                switch (last_state) {
                    .suspended => {
                        std.log.err("todo: should implement future resolution", .{});
                    },
                    .pending => {},
                    else => std.log.warn("incoherent task state", .{}),
                }
            }

            ctx.current_task = task_ref;
        } else {
            std.log.err("todo: should implement work stealing.", .{});
        }
    }
}

// --- //

pub const Circumstance = enum {
    none,
    event,
};

// --- //

inline fn isNearlyComplete(elapsed: u64, total: u64) bool {
    if (total == 0) return true;
    if (elapsed >= total) return true;

    const scaled_elapsed = @as(u128, elapsed) << 8;

    const t = @as(u128, total);
    const scaled_total = (t << 7) + (t << 6) + (t << 4) + (t << 3) + (t << 1);

    return scaled_elapsed >= scaled_total;
}
