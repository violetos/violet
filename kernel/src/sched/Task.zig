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

const arch = kernel.arch;

const mem = kernel.mem;
const utils = mem.utils;

const sched = kernel.sched;

// --- sched/Task.zig --- //

const Task = @This();
const Map = utils.SlotMap(utils.Arc(Task));
var map: Map = .{};
pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;

// --- //

process: sched.Process.Ref,

interrupt_data: arch.interrupts.InterruptData,
