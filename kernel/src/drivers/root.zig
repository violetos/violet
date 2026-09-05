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

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

// --- exports --- //

pub const intc = @import("intc/root.zig");
pub const serial = @import("serial/root.zig");

pub const acpi = @import("acpi.zig");

// --- drivers/root.zig --- //

pub const Stage = enum {
    /// The HHDM is available.
    ///
    /// For MMIO mapping DO NOT use .stage0 via HHDM but proper MMIO mapping at .stage2+
    stage0,
    /// Physical memory allocator, interruptions and CpuContexts are initialized.
    stage1,
    /// The virtual memory manager is fully available.
    stage2,
    /// Interrupt Controller, Scheduler, Syscalls and Timer are initialized.
    stage3,
};

pub const Driver = enum {
    // serial
    uart_ns16550a,
    uart_pl011,
    legacy_sbi,

    pub fn isCompatible(comptime driver: Driver) bool {
        const Module = driver.moduleOf();
        for (Module.architectures) |arch| {
            if (arch == builtin.cpu.arch) return true;
        }
        return false;
    }

    pub fn moduleOf(comptime driver: Driver) type {
        return switch (driver) {
            .uart_ns16550a => @import("serial/uart_ns16550a.zig"),
            .uart_pl011 => @import("serial/uart_pl011.zig"),
            .legacy_sbi => @import("serial/legacy_sbi.zig"),
        };
    }
};

const all_drivers = blk: {
    var driver_set: std.EnumSet(Driver) = .empty;

    var it = std.mem.splitScalar(u8, build_options.drivers, ',');
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");

        if (token.len == 0) continue;

        if (std.meta.stringToEnum(Driver, token)) |driver| {
            if (!driver.isCompatible()) {
                @compileError(std.fmt.comptimePrint(
                    "Driver '{s}' is not compatible with target architecture '{s}'",
                    .{ token, @tagName(builtin.cpu.arch) },
                ));
            }

            driver_set.insert(driver);
        } else {
            @compileError(std.fmt.comptimePrint("Unknown driver '{s}'", .{token}));
        }
    }

    break :blk driver_set;
};

fn validateDriverModule(comptime Module: type) void {
    if (!@hasDecl(Module, "architectures")) @compileError("driver module is missing `architectures`");
    if (!@hasDecl(Module, "discover_stage")) @compileError("driver module is missing `discover_stage`");
    if (!@hasDecl(Module, "discover")) @compileError("driver module is missing `discover`");
}

pub const all_modules: []const type = blk: {
    var list: []const type = &.{};
    for (std.meta.tags(Driver)) |driver| {
        if (all_drivers.contains(driver)) {
            const Module = driver.moduleOf();
            validateDriverModule(Module);
            list = list ++ .{Module};
        }
    }
    break :blk list;
};

pub fn runStage(comptime stage: Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) void {
    inline for (all_modules) |Module| {
        comptime if (Module.discover_stage) |ds| if (ds != stage) continue;

        Module.discover(stage, xsdt, dt) catch |err| {
            std.debug.panic("driver '{s}' init at {s} failed: {s}", .{ @tagName(stage), @typeName(Module), @errorName(err) });
        };
    }
}

pub fn runLocal() void {
    inline for (all_modules) |Module| {
        if (@hasDecl(Module, "initLocal")) {
            Module.initLocal() catch |err| {
                std.debug.panic("driver '{s}' local init failed: {s}", .{ @typeName(Module), @errorName(err) });
            };
        }
    }
}

comptime {
    _ = all_modules;
}
