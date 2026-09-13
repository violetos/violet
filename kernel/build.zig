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
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const query = b.standardTargetOptionsQueryOnly(.{});
    const arch = query.cpu_arch orelse .aarch64;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = query.cpu_model,
        .cpu_features_add = getFeaturesAdd(arch),
        .cpu_features_sub = getFeaturesSub(arch),
    });

    const optimize = b.standardOptimizeOption(.{});
    if (optimize == .ReleaseFast) @panic("ReleaseFast is forbidden");

    const basalt_dep = b.dependency("basalt", .{ .is_module = true });
    const basalt_mod = basalt_dep.module("basalt");

    const build_options = b.addOptions();
    {
        const drivers = b.option([]const u8, "drivers", "kernel drivers set") orelse "";
        const page_size = b.option(u64, "page_size", "4, 16, 64") orelse 4;
        const page_levels = b.option(u8, "page_levels", "3, 4, 5") orelse 4;

        build_options.addOption([]const u8, "version", zon.version);
        build_options.addOption([]const u8, "drivers", drivers);
        build_options.addOption(u64, "page_size", page_size);
        build_options.addOption(u8, "page_levels", page_levels);
    }

    const limine_dep = b.dependency("limine", .{ .revision = 6 });
    const limine_mod = limine_dep.module("limine");

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "basalt", .module = basalt_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "limine", .module = limine_mod },
        },

        .target = target,
        .optimize = optimize,

        .code_model = switch (arch) {
            .aarch64 => .small,
            .riscv64 => .medany,
            else => unreachable,
        },
        .link_libc = false,
        .link_libcpp = false,
        .omit_frame_pointer = false,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
    });

    {
        const arch_path = b.fmt("src/arch/{s}/", .{@tagName(arch)});
        var asm_dir = try b.build_root.handle.openDir(b.graph.io, arch_path, .{ .iterate = true });
        defer asm_dir.close(b.graph.io);

        var walker = try asm_dir.walk(b.allocator);
        defer walker.deinit();

        while (try walker.next(b.graph.io)) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.basename);

                if (std.mem.eql(u8, ext, ".s")) {
                    const full_path = try std.fs.path.join(b.allocator, &.{ arch_path, entry.path });
                    kernel_mod.addAssemblyFile(b.path(full_path));
                }
            }
        }
    }

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    kernel_exe.bundle_compiler_rt = true;
    kernel_exe.entry = .disabled;
    kernel_exe.link_z_max_page_size = if (arch == .aarch64) 64 * 1024 else 4 * 1024;
    kernel_exe.lto = .none;
    kernel_exe.pie = false;

    kernel_exe.setLinkerScript(b.path("linker.lds"));

    b.installArtifact(kernel_exe);
}

fn getFeaturesAdd(arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    const features_add = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            _ = Feature;
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            _ = Feature;
        },
        else => unreachable,
    }

    return features_add;
}

fn getFeaturesSub(arch: std.Target.Cpu.Arch) std.Target.Cpu.Feature.Set {
    var features_sub = std.Target.Cpu.Feature.Set.empty;

    switch (arch) {
        .aarch64 => {
            const Feature = std.Target.aarch64.Feature;

            features_sub.addFeature(@intFromEnum(Feature.fp_armv8));
            features_sub.addFeature(@intFromEnum(Feature.neon));
            features_sub.addFeature(@intFromEnum(Feature.crypto));
        },
        .riscv64 => {
            const Feature = std.Target.riscv.Feature;

            features_sub.addFeature(@intFromEnum(Feature.f));
            features_sub.addFeature(@intFromEnum(Feature.d));
            features_sub.addFeature(@intFromEnum(Feature.q));
            features_sub.addFeature(@intFromEnum(Feature.zfa));
            features_sub.addFeature(@intFromEnum(Feature.zfhmin));

            features_sub.addFeature(@intFromEnum(Feature.v));
            features_sub.addFeature(@intFromEnum(Feature.zvbb));
            features_sub.addFeature(@intFromEnum(Feature.zvfhmin));
            features_sub.addFeature(@intFromEnum(Feature.zvkt));
        },
        else => unreachable,
    }

    return features_sub;
}
