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

export var mp_request: limine.MpRequest linksection(".limine_requests") = .{
    .flags = .{ .x86_64_x2apic = false }, // unimplemented
};

pub fn init() !void {
    const mp_response: *limine.MpResponse = mp_request.response orelse return error.MpNotFound;

    const mp_infos = mp_response.getCpus();
    if (mp_infos.len == 0) return error.InvalidMp;

    var this_cpu: *CpuContext = undefined;

    for (mp_infos) |mp_info| {
        const cpu_context = try CpuContext.init(mp_info);

        switch (builtin.cpu.arch) {
            .aarch64 => if (mp_response.bsp_mpidr == cpu_context.hardware_id) {
                this_cpu = cpu_context;
            },
            .riscv64 => if (mp_response.bsp_hartid == cpu_context.hardware_id) {
                this_cpu = cpu_context;
            },
            .x86_64 => if (mp_response.bsp_lapic_id == cpu_context.hardware_id) {
                this_cpu = cpu_context;
            },
            else => unreachable,
        }
    }

    arch.cpu.setPerCpu(@intFromPtr(this_cpu));

    initialized = true;
}

inline fn hardwareId(mp_info: *limine.MpInfo) u64 {
    return switch (builtin.cpu.arch) {
        .aarch64 => mp_info.mpidr,
        .riscv64 => mp_info.hartid,
        .x86_64 => mp_info.lapic_id,
        else => unreachable,
    };
}

pub fn updateHhdm() void {
    var cpu_it = cpu_contexts.iterator();
    while (cpu_it.next()) |context| {
        context.updateHhdm();
    }

    cpu_contexts.updateHhdm();

    arch.cpu.setPerCpu(@intFromPtr(mem.updatePtr(CpuContext, @ptrFromInt(arch.cpu.getPerCpu()))));
}
