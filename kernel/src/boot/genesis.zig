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

//! Genesis Monitor Interface (GMI).

// --- dependencies --- //

const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const sched = kernel.sched;
const Process = sched.Process;

// --- boot/genesis.zig --- //

export var module_request: limine.ModuleRequest linksection(".limine_requests") = .{};

pub fn init() !void {}
