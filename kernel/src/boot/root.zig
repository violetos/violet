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
const limine = @import("limine");
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const mem = kernel.mem;

const drivers = kernel.drivers;
const acpi = drivers.acpi;

// --- boot/main.zig --- //

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(6);
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};
export var pagingmode_request: limine.PagingModeRequest linksection(".limine_requests") = .{ .mode = requested_mode, .max_mode = requested_mode, .min_mode = requested_mode };

export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

var xsdt_pa: ?u64 = null;

inline fn getXsdt() ?*const acpi.Xsdt {
    if (xsdt_pa) |pa| {
        return mem.toHhdm(acpi.Xsdt, pa);
    }
    return null;
}

export fn kernel_entry() callconv(.c) noreturn {
    if (!base_revision.isSupported()) {
        arch.cpu.halt();
    }

    const pagingmode_response: *limine.PagingModeResponse = pagingmode_request.response.?;
    if (pagingmode_response.mode != requested_mode) unreachable;

    mem.hhdm_offset = hhdm_request.response.?.offset;

    xsdt_pa = if (rsdp_request.response) |rsdp_response| blk: {
        const rsdp: *acpi.Rsdp = @ptrCast(@alignCast(rsdp_response.address));
        if (!rsdp.isValid()) break :blk null;

        const xsdt = mem.toHhdm(acpi.Xsdt, rsdp.xsdt_address);
        if (!xsdt.isValid()) break :blk null;

        break :blk rsdp.xsdt_address;
    } else null;

    drivers.serial.init();

    drivers.runStage(.stage0, getXsdt(), null);

    const memmap_entries: []*limine.MemoryMapEntry = memmap_request.response.?.getEntries();
    mem.phys.init(memmap_entries) catch |err| {
        std.debug.panic("mem.phys.init failed: {s}", .{@errorName(err)});
    };

    kernel.cpu.init() catch |err| {
        std.debug.panic("cpu.init failed: {s}", .{@errorName(err)});
    };

    arch.interrupts.init() catch |err| {
        std.debug.panic("arch.interrupts.init failed: {s}", .{@errorName(err)});
    };

    drivers.runStage(.stage1, getXsdt(), null);

    mem.virt.init(memmap_entries) catch |err| {
        std.debug.panic("mem.virt.init failed: {s}", .{@errorName(err)});
    };

    drivers.runStage(.stage2, getXsdt(), null);

    kernel.syscall.init() catch |err| {
        std.debug.panic("kernel.syscall.init failed: {s}", .{@errorName(err)});
    };

    drivers.runStage(.stage3, getXsdt(), null);

    if (framebuffer_request.response) |fbr| {
        const fb_response: *limine.FramebufferResponse = mem.updatePtr(limine.FramebufferResponse, fbr);

        if (fb_response.framebuffer_count > 0) {
            const framebuffers: [*]*limine.Framebuffer = mem.updatePtrs(*limine.Framebuffer, fb_response.framebuffers.?);
            const framebuffer = mem.updatePtr(limine.Framebuffer, framebuffers[0]);

            const old_fb_ptr: [*]u32 = @ptrCast(@alignCast(framebuffer.address));
            const fb_ptr: [*]volatile u32 = mem.updatePtrs(u32, old_fb_ptr);

            for (0..100) |i| {
                fb_ptr[i * (framebuffer.pitch / 4) + i] = 0xffffff;
            }
        }
    }

    drivers.serial.clear(null);
    std.log.info("version {s}", .{build_options.version});

    const available_mib = mem.phys.availablePages() * mem.paging.page_size / 1024 / 1024;
    if (available_mib < 384) std.debug.panic("available memory: {} MiB is under 384 MiB requirement", .{available_mib});
    std.log.info("available memory: {} MiB", .{available_mib});

    arch.cpu.halt();
}

// --- //

const requested_mode: limine.PagingMode = switch (builtin.cpu.arch) {
    .aarch64 => switch (build_options.page_levels) {
        3, 4 => .@"4lvl",
        5 => .@"5lvl",
        else => @panic("this level is unsupported on aarch64"),
    },
    .riscv64 => switch (build_options.page_levels) {
        3 => .sv39,
        4 => .sv48,
        5 => .sv57,
        else => @panic("this level is unsupported on riscv64"),
    },
    .x86_64 => switch (build_options.page_levels) {
        4 => .@"4lvl",
        5 => .@"5lvl",
        else => @panic("this level is unsupported on x86_64"),
    },
    else => @panic("arch unsupported"),
};
