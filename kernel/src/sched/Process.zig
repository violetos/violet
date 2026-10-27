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

// --- dependencies -- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const utils = mem.utils;
const virt = mem.virt;
const Space = virt.Space;
const View = virt.View;

const sched = kernel.sched;
const Future = sched.Future;
const Task = sched.Task;

// --- sched/Process.zig --- //

const Process = @This();
const Map = utils.SlotMap(utils.Arc(Process));
var map: Map = .{};
pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

// --- //

view: mem.virt.View.Ref,

affinity_offset: u8,

lock: mem.utils.RwLock = .{},
/// Protected by Process.lock
task_head: ?Task.Ref = null,
/// Protected by Process.lock
future_head: ?Future.Ref = null,

pub fn create(options: Options) !New {
    var virt_space: Space.New = if (options.privileged)
        undefined
    else
        try Space.map.insert(try Space.init(.high));
    defer if (!options.privileged) virt_space.@"1".release();

    var virt_view: View.New = if (options.privileged)
        try mem.virt.kernel_view.payload().createSubView()
    else
        try View.create(virt_space.@"1".clone());
    errdefer virt_view.@"1".release();

    const new_process = try map.insert(Process{
        .view = virt_view.@"1",
        .affinity_offset = 0,
    });

    return new_process;
}

pub fn isPrivileged(self: *const Process) bool {
    return self.view.payload().space.index == mem.virt.kernel_space.index;
}

// --- //

pub const Options = struct {
    privileged: bool,
};
