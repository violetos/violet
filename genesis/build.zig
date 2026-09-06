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

const std = @import("std");
const basalt = @import("basalt");

pub fn build(b: *std.Build) void {
    const target = basalt.standardTargetOptions(b);
    const optimize = b.standardOptimizeOption(.{});

    const basalt_dep = b.dependency("basalt", .{ .is_module = target.is_module });
    const basalt_mod = basalt_dep.module("basalt");

    const lib_mod = b.addModule("libgenesis", .{ .root_source_file = b.path("lib/root.zig"), .imports = &.{
        .{ .name = "basalt", .module = basalt_mod },
    } });

    const exe_mod = b.createModule(.{ .root_source_file = b.path("exe/main.zig"), .imports = &.{
        .{ .name = "basalt", .module = basalt_mod },
        .{ .name = "genesis", .module = lib_mod },
    } });

    if (target.is_module) {
        const exe = basalt.addExecutable(b, .{
            .name = "genesis",
            .optimize = optimize,
            .root_module = exe_mod,
            .target = target,
        });

        b.installArtifact(exe);
    }
}
