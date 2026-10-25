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

// --- arch/riscv64/virt.zig --- //

pub fn prepare() !void {}

pub fn configure(
    sp: u64,
    goto_address: u64,
) noreturn {
    configureWithArg(sp, goto_address, 0);
}

pub fn configureWithArg(
    sp: u64,
    goto_address: u64,
    arg: u64,
) noreturn {
    asm volatile (
        \\ mv s2, %[sp]
        \\ mv s3, %[goto]
        \\ mv s4, %[arg]
        :
        : [sp] "r" (sp),
          [goto] "r" (goto_address),
          [arg] "r" (arg),
        : .{ .s2 = true, .s3 = true, .s4 = true });

    arch.paging.activate(null, mem.virt.kernel_pagetable);

    asm volatile (
        \\ mv sp, s2
        \\ mv a0, s4
        \\ jr s3
    );

    unreachable;
}

pub fn clean() !void {}
