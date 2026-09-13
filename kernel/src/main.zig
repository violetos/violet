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
const builtin = @import("builtin");

// --- exports --- //

pub const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64/root.zig"),
    .riscv64 => @import("arch/riscv64/root.zig"),
    else => @compileError("Unsupported architecture."),
};

pub const boot = @import("boot/root.zig");
pub const cpu = @import("cpu/root.zig");
pub const drivers = @import("drivers/root.zig");
pub const mem = @import("mem/root.zig");
pub const sched = @import("sched/root.zig");
pub const syscall = @import("syscall/root.zig");

// --- main.zig --- //

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = stack_trace;
    _ = return_address;

    drivers.serial.print(
        null,
        .err,
        "kernel",
        "{s}",
        .{message},
    );

    arch.cpu.halt();
}

pub fn logFn(comptime message_level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    drivers.serial.print(
        null,
        message_level,
        "kernel" ++ if (scope == .default) "" else ":" ++ @tagName(scope),
        format,
        args,
    );
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .page_size_min = mem.paging.page_size,
    .page_size_max = mem.paging.page_size,
};

comptime {
    _ = arch;
    _ = boot;
    _ = cpu;
    _ = drivers;
    _ = mem;
    _ = sched;
    _ = syscall;
}
