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

const mem = kernel.mem;
const utils = mem.utils;

const sched = kernel.sched;

// --- cpu/root.zig --- //

var initialized = false;
var bsp_index: usize = 0;
var online_cpus: std.atomic.Value(usize) = .init(0);
var scheduler_ready: std.atomic.Value(bool) = .init(false);

var cpu_contexts: utils.UnrolledList(CpuContext, null) = .{};

pub const CpuContext = struct {
    index: usize = 0,
    hardware_id: u64,
    processor_id: u64,
    init_stack_top: u64,
    mp_info: *limine.MpInfo,
    online: std.atomic.Value(bool) = .init(false),

    interrupts_context: arch.interrupts.InterruptsContext = undefined,
    phys_context: mem.phys.PhysContext = undefined,
    sched_context: sched.SchedContext = undefined,
    timer_context: drivers.timer.TimerContext = undefined,

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
            .mp_info = mp_info,
        });
        const cpu_context = cpu_contexts.getPtr(index).?;
        cpu_context.index = index;

        if (index > 0 and cpu_context.processor_id == 0) {
            cpu_context.processor_id = index;
        }

        try cpu_context.interrupts_context.init();
        try cpu_context.phys_context.init();
        try cpu_context.sched_context.init();
        try cpu_context.timer_context.init();

        return cpu_context;
    }

    pub fn updateHhdm(self: *CpuContext) void {
        self.mp_info = mem.updatePtr(limine.MpInfo, self.mp_info);
        self.interrupts_context.updateHhdm();
        self.phys_context.updateHhdm();
        self.sched_context.updateHhdm();
        self.timer_context.updateHhdm();
    }
};

pub fn getContext(index: usize) ?*CpuContext {
    return cpu_contexts.getPtr(index);
}

// --- //

export var mp_request: limine.MpRequest linksection(".limine_requests") = .{};

pub fn count() usize {
    return cpu_contexts.len;
}

pub fn onlineCount() usize {
    return online_cpus.load(.acquire);
}

pub fn init() !void {
    const mp_response: *limine.MpResponse = mp_request.response orelse return error.MpNotFound;

    const mp_infos = mp_response.getCpus();
    if (mp_infos.len == 0) return error.InvalidMp;

    var this_cpu: ?*CpuContext = null;

    for (mp_infos) |mp_info| {
        const cpu_context = try CpuContext.init(mp_info);

        const is_bsp = switch (comptime builtin.cpu.arch) {
            .aarch64 => mp_response.bsp_mpidr == cpu_context.hardware_id,
            .riscv64 => mp_response.bsp_hartid == cpu_context.hardware_id,
            else => unreachable,
        };

        if (is_bsp) {
            this_cpu = cpu_context;
            bsp_index = cpu_context.index;
        }
    }

    const bsp = this_cpu orelse return error.BspNotFound;
    bsp.online.store(true, .release);
    online_cpus.store(1, .release);

    arch.interrupts.cpuInit(bsp);

    initialized = true;
}

pub fn initSecondary() !void {
    const total_cpus = cpu_contexts.len;

    if (total_cpus > 1) {
        var cpu_it = cpu_contexts.iterator();
        while (cpu_it.next()) |context| {
            if (context.index == bsp_index) continue;

            @atomicStore(u64, &context.mp_info.extra_argument, @intFromPtr(context), .release);
            @atomicStore(?limine.GotoAddress, &context.mp_info.goto_address, &secondary_entry, .release);
        }

        switch (comptime builtin.cpu.arch) {
            .aarch64 => asm volatile ("dsb ishst\nsev" ::: .{ .memory = true }),
            .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
            else => unreachable,
        }

        while (online_cpus.load(.acquire) < total_cpus) {
            std.atomic.spinLoopHint();
        }
    }

    try arch.virt.clean();

    std.log.info("{} / {} CPUs online", .{ online_cpus.load(.acquire), total_cpus });
}

pub fn releaseSecondaryToScheduler() void {
    scheduler_ready.store(true, .release);
    switch (comptime builtin.cpu.arch) {
        .aarch64 => asm volatile ("dsb ishst\nsev" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        else => unreachable,
    }
}

fn secondary_entry(mp_info: *limine.MpInfo) callconv(.c) noreturn {
    const context_new_va = @atomicLoad(u64, &mp_info.extra_argument, .acquire);
    const context_old_ptr: *const CpuContext = @ptrFromInt(context_new_va - mem.hhdm_offset + mem.old_hhdm);
    const init_stack_top = context_old_ptr.init_stack_top;

    arch.virt.configureWithArg(
        init_stack_top,
        @intFromPtr(&secondary_stage2),
        context_new_va,
    );
}

fn secondary_stage2(cpu_context: *CpuContext) callconv(.c) noreturn {
    arch.interrupts.cpuInit(cpu_context);

    const root_dom = drivers.intc.getRoot() catch |err| {
        std.debug.panic("AP {}: Root.InterruptController: {s}", .{ cpu_context.processor_id, @errorName(err) });
    };

    root_dom.initLocal() catch |err| {
        std.debug.panic("AP {}: Root.InterruptController.initLocal: {s}", .{ cpu_context.processor_id, @errorName(err) });
    };

    drivers.timer.initPerCpu() catch |err| {
        std.debug.panic("AP {}: drivers.timer.initPerCpu: {s}", .{ cpu_context.processor_id, @errorName(err) });
    };

    cpu_context.online.store(true, .release);
    _ = online_cpus.fetchAdd(1, .acq_rel);

    while (!scheduler_ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    _ = arch.interrupts.set(.enabled);

    drivers.timer.arm(drivers.timer.now());

    arch.cpu.halt();
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
    const k_view: *mem.virt.View = mem.virt.kernel_view.payload();

    var cpu_it = cpu_contexts.iterator();
    while (cpu_it.next()) |context| {
        const stack_size = 64 * 1024; // 64 KiB
        const pages_count = stack_size / mem.paging.page_size;
        const stack_base_pa = try mem.phys.allocContiguous(pages_count);

        _, const ref = mem.virt.OwnedObject.map.insert(.{
            .length = pages_count,
            .mem_type = .writeback,
            .permissions = .{
                .executable = false,
                .global = true,
                .user = false,
                .writable = true,
            },
            .owns_physical = true,
            .physical_mapping = .{ .contiguous = stack_base_pa },
        }) catch |err| {
            mem.phys.freeContiguous(stack_base_pa, pages_count);
            return err;
        };

        const stack_base_va = try k_view.alloc(stack_size, .{
            .owned = ref,
        }, true, 0);

        _ = try k_view.pinRange(stack_base_va, stack_size, .{
            .writable = true,
            .executable = false,
            .user = false,
            .global = true,
        });

        context.init_stack_top = stack_base_va + stack_size;
    }
}
