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

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const drivers = kernel.drivers;
const acpi = drivers.acpi;

const mem = kernel.mem;
const utils = mem.utils;

const sched = kernel.sched;

// --- cpu/root.zig --- //

var initialized = false;
var cpu_contexts: utils.UnrolledList(CpuContext, null) = .{};

pub const CpuContext = struct {
    index: usize = 0,
    hardware_id: u64,
    processor_id: u64,
    init_stack_top: u64,

    interrupts_context: arch.interrupts.InterruptsContext = undefined,
    phys_context: mem.phys.PhysContext = undefined,
    sched_context: sched.SchedContext = undefined,

    /// Return `null` if CpuContexts are not initialized.
    pub inline fn current() ?*CpuContext {
        if (!initialized) {
            @branchHint(.cold);
            return null;
        } else {
            @branchHint(.likely);
            return @ptrFromInt(arch.cpu.getPerCpu());
        }
    }

    pub fn init(mp_info: *limine.MpInfo) !*CpuContext {
        const index = try cpu_contexts.append(.{
            .hardware_id = hardwareId(mp_info),
            .processor_id = mp_info.processor_id,
            .init_stack_top = 0,
        });
        const cpu_context = cpu_contexts.getPtr(index).?;
        cpu_context.index = index;

        try arch.interrupts.InterruptsContext.init(&cpu_context.interrupts_context);
        try mem.phys.PhysContext.init(&cpu_context.phys_context);
        try sched.SchedContext.init(&cpu_context.sched_context);

        return cpu_context;
    }

    pub fn updateHhdm(self: *CpuContext) void {
        self.interrupts_context.updateHhdm();
        self.phys_context.updateHhdm();
        self.sched_context.updateHhdm();
    }
};

// --- //

export var mp_request: limine.MpRequest linksection(".limine_requests") = .{};

pub fn init() !void {
    const mp_response: *limine.MpResponse = mp_request.response orelse return error.MpNotFound;

    const mp_infos = mp_response.getCpus();
    if (mp_infos.len == 0) return error.InvalidMp;

    var this_cpu: *CpuContext = undefined;

    for (mp_infos) |mp_info| {
        const cpu_context = try CpuContext.init(mp_info);

        switch (comptime builtin.cpu.arch) {
            .aarch64 => if (mp_response.bsp_mpidr == cpu_context.hardware_id) {
                this_cpu = cpu_context;
            },
            .riscv64 => if (mp_response.bsp_hartid == cpu_context.hardware_id) {
                this_cpu = cpu_context;
            },
            else => unreachable,
        }
    }

    arch.interrupts.cpuInit(this_cpu);

    initialized = true;
}

inline fn hardwareId(mp_info: *limine.MpInfo) u64 {
    return switch (builtin.cpu.arch) {
        .aarch64 => mp_info.mpidr,
        .riscv64 => mp_info.hartid,
        else => unreachable,
    };
}

pub fn updateHhdm() void {
    var cpu_it = cpu_contexts.iterator();
    while (cpu_it.next()) |context| {
        context.updateHhdm();
    }

    cpu_contexts.updateHhdm();
}

pub fn allocInitStacks() !void {
    const kernel_space: *mem.virt.Space = mem.virt.kernel_space.payload();

    var cpu_it = cpu_contexts.iterator();
    while (cpu_it.next()) |context| {
        const stack_size = 64 * 1024; // 64 KiB
        const pages_count = stack_size / mem.paging.page_size;
        const stack_base_pa = try mem.phys.allocContiguous(pages_count);

        _, var ref = try mem.virt.OwnedObject.map.insert(.{
            .length = pages_count,
            .mem_type = .writeback,
            .permissions = .{
                .executable = false,
                .global = true,
                .user = false,
                .writable = true,
            },
            .physical_mapping = .{ .contiguous = stack_base_pa },
        });
        errdefer ref.release();

        const stack_base_va = try kernel_space.alloc(stack_size, .{
            .owned = ref,
        }, true, 0);

        const stack_top_va = stack_base_va + stack_size;
        context.init_stack_top = stack_top_va;
    }
}
