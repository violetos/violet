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

// --- exports --- //

pub const Process = @import("Process.zig");
pub const Task = @import("Task.zig");

// --- sched/root.zig --- //

pub const SchedContext = struct {
    current_task: ?Task.Ref,

    pub fn init(self: *SchedContext) !void {
        self.current_task = null;
    }

    pub fn current() *SchedContext {
        return &kernel.cpu.CpuContext.current().?.sched_context;
    }

    pub fn updateHhdm(self: *SchedContext) void {
        _ = self;
        // no task at this point
    }
};
