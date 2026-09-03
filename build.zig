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

const Arch = std.Target.Cpu.Arch;

pub fn build(b: *std.Build) !void {
    const board = b.option(Board, "board", "The target board");
    const arch = if (board) |bo| bo.getSoC().getArch() else b.option(Arch, "arch", "The target arch") orelse b.graph.host.result.cpu.arch;

    const target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .freestanding, .abi = .none, .cpu_model = .{ .explicit = if (board) |bo|
        bo.getSoC().getCpuModel()
    else switch (arch) {
        .x86_64 => &std.Target.x86.cpu.x86_64_v2,
        else => std.Target.Cpu.Model.baseline(arch, .{ .tag = .freestanding, .version_range = .{ .none = {} } }),
    } } });

    const optimize = b.standardOptimizeOption(.{});
    if (optimize == .ReleaseFast) @panic("ReleaseFast is forbidden");

    const img_root = createImgRoot(b, arch);
    {
        const page_size = b.option(u64, "page_size", "4, 16, 64") orelse
            if (board) |bo| bo.getSoC().getPageSize() else 4;

        const page_levels = b.option(u8, "page_levels", "3, 4, 5") orelse
            if (board) |bo| bo.getSoC().getPageLevels() else 4;

        const drivers = b.option([]const u8, "drivers", "kernel drivers set") orelse
            if (board) |bo|
                try concat(b, bo.getSoC().getDrivers(), bo.getDrivers())
            else switch (arch) {
                .x86_64 => "uart_ns16550a",
                .aarch64 => "uart_pl011",
                .riscv64 => "legacy_sbi",
                else => "",
            };

        const kernel_dep = b.dependency("kernel", .{
            .target = target,
            .optimize = optimize,
            .drivers = drivers,
            .page_size = page_size,
            .page_levels = page_levels,
        });
        const kernel_exe = kernel_dep.artifact("kernel");

        if (optimize == .Debug) b.installArtifact(kernel_exe);

        _ = img_root.addCopyFile(kernel_exe.getEmittedBin(), "core/kernel.elf");
    }

    setupFirmware(b, img_root, board);

    const make_img = b.addRunArtifact(makeImageExe(b));
    make_img.step.dependOn(&img_root.step);

    make_img.addDirectoryArg(img_root.getDirectory());

    const violet_img = b.addInstallFile(
        make_img.addOutputFileArg("violet.img"),
        if (board) |bo|
            b.fmt("violet-{s}.img", .{@tagName(bo)})
        else
            b.fmt("violet-{s}.img", .{@tagName(arch)}),
    );
    b.getInstallStep().dependOn(&violet_img.step);

    make_img.addArgs(&.{ "--label", "VIOLET", "--volume-label", "VIOLET" });

    const run_cmd = runCmd(b, arch, violet_img.source);

    const run_step = b.step("run", "Boot violetOS in QEMU");
    if (board == null) {
        run_step.dependOn(&run_cmd.step);
        run_step.dependOn(b.getInstallStep());
    }
}

fn createImgRoot(b: *std.Build, arch: Arch) *std.Build.Step.WriteFile {
    const root = b.addWriteFiles();

    _ = root.addCopyFile(b.path("LICENSE"), "LICENSE");
    _ = root.addCopyFile(b.path("NOTICE.md"), "NOTICE.md");

    const limine_binary = b.dependency("limine_binary", .{});

    _ = root.addCopyFile(b.path("build/limine.conf"), "limine.conf");

    const efi_file_name = switch (arch) {
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        .x86_64 => "BOOTX64.EFI",
        else => unreachable,
    };

    _ = root.addCopyFile(limine_binary.path(efi_file_name), b.fmt("EFI/BOOT/{s}", .{efi_file_name}));

    return root;
}

fn setupFirmware(b: *std.Build, img_root: *std.Build.Step.WriteFile, board: ?Board) void {
    if (board) |bo| switch (bo) {
        .raspberry_pi4 => {
            const rpi4_uefi = b.dependency("rpi4_uefi", .{});
            _ = img_root.addCopyDirectory(rpi4_uefi.path("."), ".", .{ .exclude_extensions = &.{"md"} });
        },
        else => @panic("This board is not supported yet."),
    };
}

fn makeImageExe(b: *std.Build) *std.Build.Step.Compile {
    const make_img = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });

    const fatfs = b.dependency("fatfs", .{});
    const fatfs_src = b.addWriteFiles();
    _ = fatfs_src.addCopyFile(b.path("build/ffconf.h"), "ffconf.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ff.c"), "ff.c");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ff.h"), "ff.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/diskio.h"), "diskio.h");
    _ = fatfs_src.addCopyFile(fatfs.path("source/ffunicode.c"), "ffunicode.c");

    const fatfs_dir = fatfs_src.getDirectory();

    make_img.addCSourceFile(.{
        .file = b.path("build/make_img.c"),
        .flags = &.{"-std=c11"},
    });

    make_img.addCSourceFile(.{
        .file = fatfs_dir.path(b, "ff.c"),
        .flags = &.{"-std=c89"},
    });

    make_img.addCSourceFile(.{
        .file = fatfs_dir.path(b, "ffunicode.c"),
        .flags = &.{"-std=c89"},
    });

    make_img.addIncludePath(fatfs_dir);

    return b.addExecutable(.{
        .name = "make_img",
        .root_module = make_img,
    });
}

fn downloadAndDecompress(b: *std.Build, url: []const u8, out_name: []const u8) std.Build.LazyPath {
    const download_cmd = b.addSystemCommand(&.{ "curl", "-sS", "-L", "-o" });
    const bz2_path = download_cmd.addOutputFileArg(b.fmt("{s}.bz2", .{out_name}));
    download_cmd.addArg(url);

    const decompress_cmd = b.addSystemCommand(&.{ "bunzip2", "-c" });
    decompress_cmd.addFileArg(bz2_path);
    return decompress_cmd.captureStdOut(.{});
}

const qemu_pc_bios_base = "https://gitlab.com/qemu-project/qemu/-/raw/v11.1.1/pc-bios/";

fn edk2File(b: *std.Build, arch: Arch) std.Build.LazyPath {
    const remote_name = switch (arch) {
        .aarch64 => "edk2-aarch64-code.fd",
        .riscv64 => "edk2-riscv-code.fd",
        .x86_64 => "edk2-x86_64-code.fd",
        else => unreachable,
    };

    return downloadAndDecompress(
        b,
        b.fmt("{s}{s}.bz2", .{ qemu_pc_bios_base, remote_name }),
        b.fmt("edk2-{s}-code.fd", .{@tagName(arch)}),
    );
}

fn edk2VarsFile(b: *std.Build, arch: Arch) std.Build.LazyPath {
    const remote_name = switch (arch) {
        .aarch64 => "edk2-arm-vars.fd",
        .riscv64 => "edk2-riscv-vars.fd",
        .x86_64 => "edk2-i386-vars.fd",
        else => unreachable,
    };

    return downloadAndDecompress(
        b,
        b.fmt("{s}{s}.bz2", .{ qemu_pc_bios_base, remote_name }),
        b.fmt("edk2-{s}-vars.fd", .{@tagName(arch)}),
    );
}

fn runCmd(b: *std.Build, arch: Arch, violet_img: std.Build.LazyPath) *std.Build.Step.Run {
    const qemu_exe = switch (arch) {
        .aarch64 => "qemu-system-aarch64",
        .riscv64 => "qemu-system-riscv64",
        .x86_64 => "qemu-system-x86_64",
        else => @panic("Architecture not supported yet"),
    };

    const run_cmd = b.addSystemCommand(&.{qemu_exe});

    run_cmd.addArg("-blockdev");
    run_cmd.addPrefixedFileArg(
        "node-name=pflash0,driver=file,read-only=on,filename=",
        edk2File(b, arch),
    );

    run_cmd.addArg("-blockdev");
    run_cmd.addPrefixedFileArg(
        "node-name=pflash1,driver=file,filename=",
        edk2VarsFile(b, arch),
    );

    // Machine Config
    {
        switch (arch) {
            .aarch64 => run_cmd.addArgs(&.{
                "-machine", "virt,secure=off,virtualization=off,pflash0=pflash0,pflash1=pflash1",
                "-cpu",     "cortex-a57",
            }),
            .riscv64 => run_cmd.addArgs(&.{
                "-machine", "virt,pflash0=pflash0,pflash1=pflash1",
                "-cpu",     "rv64",
            }),
            .x86_64 => run_cmd.addArgs(&.{
                "-machine", "q35,pflash0=pflash0,pflash1=pflash1",
                "-cpu",     "max",
            }),
            else => unreachable,
        }

        run_cmd.addArgs(&.{ "-m", "2G", "-smp", "4" });
        run_cmd.addArgs(&.{ "-serial", "stdio" });
        run_cmd.addArgs(&.{ "-no-reboot", "-no-shutdown" });
        run_cmd.addArgs(&.{ "-device", if (arch == .x86_64) "virtio-gpu" else "ramfb" });
    }

    // violet.img
    {
        run_cmd.addArgs(&.{ "-device", "virtio-blk-pci,drive=disk0,disable-legacy=on,bootindex=0", "-drive" });
        run_cmd.addPrefixedFileArg("if=none,id=disk0,format=raw,file=", violet_img);
    }

    const debug_mode = b.option(bool, "debug", "QEMU debug mode") orelse false;
    if (debug_mode) run_cmd.addArgs(&.{ "-s", "-S" });

    const int_mode = b.option(bool, "int", "Verbose interrupts into debug.log") orelse false;
    if (int_mode) run_cmd.addArgs(&.{ "-d", "int", "-D", "debug.log" });

    const accel_mode = b.option(bool, "accel", "QEMU acceleration") orelse false;
    if (accel_mode) {
        const accel_tag = switch (b.graph.host.result.os.tag) {
            .linux => "kvm",
            .macos => "hvf",
            else => "tcg",
        };

        run_cmd.addArgs(&.{ "-accel", accel_tag });
    }

    return run_cmd;
}

pub const SoC = enum {
    // aarch64
    bcm2711,
    rk3588,

    // riscv64
    jh7110,

    pub fn getArch(self: SoC) Arch {
        return switch (self) {
            .bcm2711, .rk3588 => .aarch64,
            .jh7110 => .riscv64,
        };
    }

    pub fn getPageSize(self: SoC) u64 {
        return switch (self) {
            .bcm2711, .rk3588 => 16,
            .jh7110 => 4,
        };
    }

    pub fn getPageLevels(self: SoC) u8 {
        return switch (self) {
            .bcm2711, .rk3588, .jh7110 => 3,
        };
    }

    pub fn getDrivers(self: SoC) []const u8 {
        return switch (self) {
            else => "",
        };
    }

    pub fn getModules(self: SoC) []const u8 {
        return switch (self) {
            else => "",
        };
    }

    pub fn getCpuModel(self: SoC) *const std.Target.Cpu.Model {
        return switch (self) {
            .bcm2711 => &bcm2711_cpu_model,
            .jh7110 => &std.Target.riscv.cpu.sifive_u74,
            else => unreachable,
        };
    }

    const bcm2711_cpu_model: std.Target.Cpu.Model = .{
        .name = "cortex_a72",
        .llvm_name = "cortex-a72",
        .features = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
            .addr_lsl_slow_14,
            .crc,
            .enable_select_opt,
            .fuse_adrp_add,
            .fuse_literals,
            .perfmon,
            .predictable_select_expensive,
            .v8a,
        }),
    };
};

pub const Board = enum {
    // aarch64
    raspberry_pi4,
    radxa_rock5b,
    orange_pi5_plus,

    // riscv64
    vision_five2,

    pub fn getSoC(self: Board) SoC {
        return switch (self) {
            .raspberry_pi4 => .bcm2711,
            .radxa_rock5b, .orange_pi5_plus => .rk3588,
            .vision_five2 => .jh7110,
        };
    }

    pub fn getDrivers(self: Board) []const u8 {
        return switch (self) {
            else => "",
        };
    }

    pub fn getModules(self: Board) []const u8 {
        return switch (self) {
            else => "",
        };
    }
};

pub const Module = enum {
    virtio,
};

fn concat(b: *std.Build, str1: []const u8, str2: []const u8) ![]const u8 {
    var str1_it = std.mem.splitScalar(u8, str1, ',');
    var str2_it = std.mem.splitScalar(u8, str2, ',');

    var buf_set: std.BufSet = .init(b.allocator);
    defer buf_set.deinit();

    while (str1_it.next()) |opt| try buf_set.insert(opt);
    while (str2_it.next()) |opt| try buf_set.insert(opt);

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    var it = buf_set.iterator();
    while (it.next()) |opt| {
        try list.append(b.allocator, opt.*);
    }

    return std.mem.join(b.allocator, ",", list.items);
}
