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

.arch armv8-a

.section .text

.global virt_switch
.type virt_switch, %function
virt_switch:
    // x0 = mair
    // x1 = tcr
    // x2 = ttbr1
    // x3 = sp
    // x4 = trampoline_pa
    // x5 = goto_address
    // x6 = arg

    br x4

.globl virt_trampoline
virt_trampoline:
    mrs x7, sctlr_el1
    bic x7, x7, #1
    msr sctlr_el1, x7
    isb

    msr mair_el1, x0
    msr ttbr1_el1, x2
    msr tcr_el1, x1
    isb
    dsb sy
    isb

    tlbi vmalle1
    dsb nsh
    isb

    mov sp, x3

    mrs x7, sctlr_el1
    orr x7, x7, #1
    msr sctlr_el1, x7
    isb

    ldr x7, =.Lvirt_high_half
    br x7

.Lvirt_high_half:
    mrs x7, tcr_el1
    orr x7, x7, #(1 << 7)
    msr tcr_el1, x7
    msr ttbr0_el1, xzr
    isb

    tlbi vmalle1
    dsb nsh
    isb

    mov x0, x6
    br x5
