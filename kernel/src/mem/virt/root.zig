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

// --- dependencies -- //

const std = @import("std");
const limine = @import("limine");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const paging = mem.paging;
const phys = mem.phys;
const utils = mem.utils;

// --- exports --- //

pub const OwnedObject = @import("OwnedObject.zig");
pub const SharedObject = @import("SharedObject.zig");
pub const Space = @import("Space.zig");
pub const View = @import("View.zig");

// --- mem/virt.zig --- //

pub var kernel_space: Space.Ref = undefined;
pub var kernel_view: View.Ref = undefined;
pub var kernel_pagetable: u64 = undefined;
pub var kernel_start_pa: u64 = undefined;

export var address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};

pub fn init(memmap_entries: []*limine.MemoryMapEntry) !void {
    {
        mem.zero_page_pa = try phys.allocPage();
        const zero_page = mem.toHhdm([mem.paging.page_size]u8, mem.zero_page_pa);
        @memset(zero_page, 0);
    }

    {
        _, const space_ref = try Space.map.insert(try Space.init(.high));
        kernel_space = space_ref;

        _, const view_ref = try View.create(kernel_space.clone());
        kernel_view = view_ref;
    }

    const physical_base: u64 = address_request.response.?.physical_base;
    const k_view: *View = kernel_view.payload();

    kernel_start_pa = physical_base;

    try mapKernelRange(k_view, KernelMemory.rodataRange(), physical_base, .{
        .writable = false,
        .executable = false,
        .user = false,
        .global = true,
    });

    try mapKernelRange(k_view, KernelMemory.textRange(), physical_base, .{
        .writable = false,
        .executable = true,
        .user = false,
        .global = true,
    });

    try mapKernelRange(k_view, KernelMemory.dataRange(), physical_base, .{
        .writable = true,
        .executable = false,
        .user = false,
        .global = true,
    });

    const new_hhdm_offset = blk: {
        var max_phys_addr: u64 = 0;
        for (memmap_entries) |entry| {
            switch (entry.type) {
                .acpi_nvs,
                .acpi_reclaimable,
                .bootloader_reclaimable,
                .executable_and_modules,
                .reserved_mapped,
                .framebuffer,
                .usable,
                => {
                    const end_addr = entry.base + entry.length;
                    if (end_addr > max_phys_addr) {
                        max_phys_addr = end_addr;
                    }
                },
                else => {},
            }
        }

        const aligned_size = std.mem.alignForward(u64, max_phys_addr, paging.page_size);
        const page_count = aligned_size / paging.page_size;

        _, const ref = try OwnedObject.map.insert(OwnedObject{
            .length = page_count,
            .mem_type = .writeback,
            .permissions = .{
                .executable = false,
                .global = true,
                .user = false,
                .writable = true,
            },
            .owns_physical = false,
            .physical_mapping = .{ .contiguous = 0 },
        });

        break :blk try k_view.alloc(aligned_size, .{ .owned = ref }, false, 0);
    };

    kernel_pagetable = kernel_space.payload().page_table.root_pa;

    try kernel.cpu.allocInitStacks();

    const init_stack_top = kernel.cpu.CpuContext.current().?.init_stack_top;

    try kernel.arch.virt.prepare();

    {
        mem.old_hhdm = mem.hhdm_offset;
        mem.hhdm_offset = new_hhdm_offset;

        Space.map.updateHhdm();
        View.map.updateHhdm();
        OwnedObject.map.updateHhdm();
        SharedObject.map.updateHhdm();
        kernel_space.updateHhdm();
        kernel_view.updateHhdm();

        kernel.cpu.updateHhdm();
        mem.phys.updateHhdm();
    }

    kernel.arch.virt.configure(
        init_stack_top,
        @intFromPtr(&kernel.boot.stage2_entry),
    );
}

inline fn mapKernelRange(view: *View, range: KernelMemory.Range, physical_base: u64, permissions: paging.Permissions) !void {
    _, const ref = try OwnedObject.map.insert(OwnedObject{
        .length = range.pages(),
        .mem_type = .writeback,
        .permissions = permissions,
        .owns_physical = false,
        .physical_mapping = .{ .contiguous = range.offset(physical_base) },
    });

    try view.mapAt(range.start, range.end, .{ .owned = ref }, false);
}

// --- //

pub const KernelMemory = struct {
    extern var __rodata_start: u8;
    extern var __text_start: u8;
    extern var __data_start: u8;
    extern var __kernel_end: u8;

    pub const Range = struct {
        start: u64,
        end: u64,

        pub inline fn size(self: Range) u64 {
            return self.end - self.start;
        }

        pub inline fn pages(self: Range) u64 {
            return std.mem.alignForward(u64, self.size(), paging.page_size) / paging.page_size;
        }

        pub inline fn offset(self: Range, base: u64) u64 {
            return base + (self.start - @intFromPtr(&__rodata_start));
        }
    };

    pub inline fn rodataRange() Range {
        return .{
            .start = @intFromPtr(&__rodata_start),
            .end = @intFromPtr(&__text_start),
        };
    }

    pub inline fn textRange() Range {
        return .{
            .start = @intFromPtr(&__text_start),
            .end = @intFromPtr(&__data_start),
        };
    }

    pub inline fn dataRange() Range {
        return .{
            .start = @intFromPtr(&__data_start),
            .end = @intFromPtr(&__kernel_end),
        };
    }

    pub inline fn total() Range {
        return .{
            .start = @intFromPtr(&__rodata_start),
            .end = @intFromPtr(&__kernel_end),
        };
    }
};

pub fn mmio(base: u64, size: u64) !u64 {
    return kernel_view.payload().mmio(base, size);
}
