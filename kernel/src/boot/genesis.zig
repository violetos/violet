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
const basalt = @import("basalt");
const limine = @import("limine");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const sched = kernel.sched;
const Process = sched.Process;
const Task = sched.Task;

// --- boot/genesis.zig --- //

export var module_request: limine.ModuleRequest linksection(".limine_requests") = .{};

pub fn init() !void {
    _, var process_ref = try Process.create(.{
        .privileged = true,
    });
    defer process_ref.release();

    _, var task_ref = try Task.create(.{
        .process = process_ref.clone(),
        .entry_point = @intFromPtr(&test_entry),
        .setting = .{
            .priority = .normal,
            .qt_div = .full,
        },
        .arg = 0,
        .tls = 0,
    });
    defer task_ref.release();

    try sched.push(task_ref.clone());
}

fn test_entry(arg: u64) callconv(basalt.system.call_conv) noreturn {
    test_main(arg) catch |err| {
        std.log.err("test_main(task): {s}", .{@errorName(err)});
    };
    arch.cpu.halt();
}

fn test_main(arg: u64) !void {
    _ = arg;

    const result = try basalt.system.call.syscall(.timer_single, .{
        .arg1 = 0xfaaf,
        .arg2 = 0xdaad,
        .arg3 = 0xfaaaa,
    });

    std.log.info("{any}", .{result});
}
