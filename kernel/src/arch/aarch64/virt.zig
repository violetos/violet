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

pub const mair = arch.registers.MAIR{
    .attr0 = arch.registers.MAIR.NORMAL_WRITEBACK_NONTRANSIENT,
    .attr1 = arch.registers.MAIR.NORMAL_NONCACHEABLE,
    .attr2 = arch.registers.MAIR.DEVICE_nGnRnE,
};

pub fn prepare() !void {
    (arch.registers.MAIR_EL1{
        .attr0 = arch.registers.MAIR_EL1.NORMAL_WRITEBACK_NONTRANSIENT,
        .attr1 = arch.registers.MAIR_EL1.NORMAL_NONCACHEABLE,
        .attr2 = arch.registers.MAIR_EL1.DEVICE_nGnRnE,
    }).store();
}

pub fn configure(high_half_pa: u64) !void {
    arch.paging.activate(null, high_half_pa);
}
