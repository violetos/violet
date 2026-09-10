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

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const mem = kernel.mem;
const paging = mem.paging;

// --- arch/aarch64/virt.zig --- //

extern fn virt_switch(
    mair: u64,
    tcr: u64,
    ttbr1: u64,
    sp: u64,
    trampoline_pa: u64,
    goto_address: u64,
) noreturn;

extern const virt_trampoline: opaque {};

pub const mair = arch.registers.MAIR{
    .attr0 = arch.registers.MAIR.NORMAL_WRITEBACK_NONTRANSIENT,
    .attr1 = arch.registers.MAIR.NORMAL_NONCACHEABLE,
    .attr2 = arch.registers.MAIR.DEVICE_nGnRnE,
};

var trampoline_ttbr0: mem.paging.PageTable = undefined;
var trampoline_pa: u64 = undefined;

pub fn prepare() !void {
    const high_va = @intFromPtr(&virt_trampoline);
    const kernel_base_va = mem.virt.KernelMemory.total().start;
    const offset_va = high_va - kernel_base_va;
    trampoline_pa = mem.virt.kernel_start_pa + offset_va;

    const base_start = std.mem.alignBackward(u64, trampoline_pa, paging.page_size);
    const base_end = std.mem.alignForward(u64, trampoline_pa + paging.page_size, paging.page_size);
    const base_count = (base_end - base_start) / paging.page_size;

    trampoline_ttbr0 = try .init(null);

    var query = mem.paging.Query{
        .virtual_address = base_start,
        .physical_address = base_start,
        .batch_size = base_count,
        .mem_type = .writeback,
        .state = .committed,
        .permissions = .{
            .executable = true,
            .global = true,
            .user = false,
            .writable = false,
        },
    };
    try trampoline_ttbr0.submit(&query);
}

pub fn configure(sp: u64, goto_address: u64) noreturn {
    var tcr = arch.registers.TCR.load();
    tcr.epd0 = true;
    tcr.store();

    asm volatile (
        \\ dsb nshst
        \\ isb
        ::: .{ .memory = true });

    arch.registers.storeTtbr0El1(trampoline_ttbr0.root_pa);

    tcr.epd0 = false;
    tcr.tg0 = switch (mem.paging.page_size) {
        4 * 1024 => .@"4kb",
        16 * 1024 => .@"16kb",
        64 * 1024 => .@"64kb",
        else => unreachable,
    };
    tcr.t0sz = @intCast(@as(u8, 64) - paging.va_bits);
    tcr.store();

    asm volatile (
        \\ isb
        \\ dsb sy
        \\ isb
        \\
        \\ tlbi vmalle1
        \\ dsb nsh
        \\ isb
        ::: .{ .memory = true });

    tcr.tg1 = switch (mem.paging.page_size) {
        4 * 1024 => .@"4kb",
        16 * 1024 => .@"16kb",
        64 * 1024 => .@"64kb",
        else => unreachable,
    };
    tcr.t1sz = tcr.t0sz;

    asm volatile (
        \\ dsb nshst
        ::: .{ .memory = true });

    virt_switch(
        @bitCast(mair),
        @bitCast(tcr),
        mem.virt.kernel_pagetable,
        sp,
        trampoline_pa,
        goto_address,
    );
}

/// done after BSP and all APs called configure()
pub fn clean() !void {
    trampoline_ttbr0.deinit();
}
