// Copyright (c) 2024-2025 The violetOS authors
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

// --- imports --- //

const kernel = @import("root");
const arch = kernel.arch;
const syscall = kernel.syscall;

// --- syscall/timer.zig --- //

pub fn init() !void {
    syscall.register(.timer_single, &timer_single);
    syscall.register(.timer_sequential, &timer_sequential);
}

fn timer_single(frame: *arch.interrupts.ReducedFrame) !void {
    _ = frame;

    // doing nothing causes .internal_failure
}

fn timer_sequential(frame: *arch.interrupts.ReducedFrame) !void {
    _ = frame;

    // doing nothing causes .internal_failure
}
