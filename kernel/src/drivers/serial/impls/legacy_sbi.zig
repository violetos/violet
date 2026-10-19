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

// --- imports --- //

const kernel = @import("root");

const drivers = kernel.drivers;
const acpi = drivers.acpi;

const mem = kernel.mem;

// --- drivers/serial/legacy_sbi.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.riscv64};
pub const discover_stage: ?drivers.Stage = .stage0;

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    _ = stage;
    _ = xsdt;
    _ = dt;

    drivers.serial.register(.{
        .name = "sbi_console",
        .context = @ptrCast(&sbi_ctx),
        .vtable = .{ .write = write, .read = null },
    }, 1);
}

const SbiContext = struct {};
var sbi_ctx: SbiContext = .{};

fn write(_: *anyopaque, data: []const u8) void {
    for (data) |byte| {
        if (byte == '\n') writeChar('\r');
        writeChar(byte);
    }
}

inline fn writeChar(c: u8) void {
    var error_code: usize = undefined;
    var return_value: usize = undefined;

    asm volatile ("ecall"
        : [err] "={a0}" (error_code),
          [ret] "={a1}" (return_value),
        : [ext] "{a7}" (@as(usize, 0x01)),
          [arg] "{a0}" (@as(usize, c)),
        : .{ .memory = true });
}
