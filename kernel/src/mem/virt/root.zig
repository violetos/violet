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

// --- mem/virt.zig --- //

pub var kernel_space: Space.Ref = undefined;

export var address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};

pub fn init(memmap_entries: []*limine.MemoryMapEntry) !void {
    {
        mem.zero_page_pa = try phys.allocPage();
        const zero_page = mem.toHhdm([mem.paging.page_size]u8, mem.zero_page_pa);
        @memset(zero_page, 0);
    }

    {
        _, const ref = try Space.map.insert(try Space.init(.high));
        kernel_space = ref;
    }

    const physical_base: u64 = address_request.response.?.physical_base;
    const space: *Space = kernel_space.payload();

    try map(space, KernelMemory.rodataRange(), physical_base, .{
        .writable = false,
        .executable = false,
        .user = false,
        .global = true,
    });

    try map(space, KernelMemory.textRange(), physical_base, .{
        .writable = false,
        .executable = true,
        .user = false,
        .global = true,
    });

    try map(space, KernelMemory.dataRange(), physical_base, .{
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
            .physical_mapping = .{ .contiguous = 0 },
        });

        break :blk try space.alloc(aligned_size, .{ .owned = ref }, false, 0);
    };

    const high_half_pa = kernel_space.payload().page_table.root_pa;

    try kernel.arch.virt.prepare();

    {
        mem.old_hhdm = mem.hhdm_offset;
        mem.hhdm_offset = new_hhdm_offset;

        Space.map.updateHhdm();
        OwnedObject.map.updateHhdm();
        kernel_space.updateHhdm();

        kernel.cpu.updateHhdm();
        mem.phys.updateHhdm();
    }

    try kernel.arch.virt.configure(high_half_pa);
}

inline fn map(space: *Space, range: KernelMemory.Range, physical_base: u64, permissions: paging.Permissions) !void {
    _, const ref = try OwnedObject.map.insert(OwnedObject{
        .length = range.pages(),
        .mem_type = .writeback,
        .permissions = permissions,
        .physical_mapping = .{ .contiguous = range.offset(physical_base) },
    });

    try space.mapAt(.{
        .base_va = range.start,
        .end_va = range.end,
        .kind = .{ .owned = .{
            .ref = ref,
            .has_guards = false,
        } },
    });
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
            return self.size() / paging.page_size;
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

pub inline fn mmio(base: u64, size: u64) !u64 {
    const k_space: *Space = kernel_space.payload();

    _, const ref = try OwnedObject.map.insert(OwnedObject{
        .length = size / paging.page_size,
        .mem_type = .device,
        .permissions = .{
            .executable = false,
            .global = true,
            .user = false,
            .writable = true,
        },
        .physical_mapping = .{ .contiguous = base },
    });

    return k_space.alloc(size, .{ .owned = ref }, false, 0);
}
