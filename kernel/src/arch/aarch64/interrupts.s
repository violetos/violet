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

.equ GEN_SIZE,       288
.equ EXT_SIZE,       816

.equ OFF_GEN_LR,     240
.equ OFF_GEN_PC,     248
.equ OFF_GEN_SPSR,   256
.equ OFF_GEN_TPIDR,  264
.equ OFF_GEN_SP,     272

.equ OFF_EXT_FPCR,   512
.equ OFF_EXT_FPSR,   520
.equ OFF_EXT_GEN,    528

.section .text

.global call_system
.type call_system, %function
call_system:
    msr daifset, #0b0011
    isb

    msr spsel, #1

    stp x0, x1, [sp, #-16]!

    mrs x0, sp_el0
    mov x1, x0
    sub x0, x0, #GEN_SIZE
    msr sp_el0, x0

    str x1, [x0, #OFF_GEN_SP]

    str x30, [x0, #OFF_GEN_PC] // in order to make it compatible with ERET
    str x30, [x0, #OFF_GEN_LR]

    mrs x1, tpidr_el0
    str x1, [x0, #OFF_GEN_TPIDR]

    stp x2, x3,   [x0, #(16 * 1)]
    stp x4, x5,   [x0, #(16 * 2)]
    stp x6, x7,   [x0, #(16 * 3)]
    stp x8, x9,   [x0, #(16 * 4)]
    stp x10, x11, [x0, #(16 * 5)]
    stp x12, x13, [x0, #(16 * 6)]
    stp x14, x15, [x0, #(16 * 7)]
    stp x16, x17, [x0, #(16 * 8)]
    stp x18, x19, [x0, #(16 * 9)]
    stp x20, x21, [x0, #(16 * 10)]
    stp x22, x23, [x0, #(16 * 11)]
    stp x24, x25, [x0, #(16 * 12)]
    stp x26, x27, [x0, #(16 * 13)]
    stp x28, x29, [x0, #(16 * 14)]

    ldp x2, x3, [sp], #16
    stp x2, x3, [x0, #(16 * 0)]

    str x0, [sp, #-16]!

    bl internal_entry

    ldr x0, [sp]
    bl internal_call_system

    ldr x0, [sp], #16
    b internal_exit

.global extend_frame
.type extend_frame, %function
extend_frame:
    sub x0, x0, #OFF_EXT_GEN

    stp q0, q1,   [x0, #(32 * 0)]
    stp q2, q3,   [x0, #(32 * 1)]
    stp q4, q5,   [x0, #(32 * 2)]
    stp q6, q7,   [x0, #(32 * 3)]
    stp q8, q9,   [x0, #(32 * 4)]
    stp q10, q11, [x0, #(32 * 5)]
    stp q12, q13, [x0, #(32 * 6)]
    stp q14, q15, [x0, #(32 * 7)]
    stp q16, q17, [x0, #(32 * 8)]
    stp q18, q19, [x0, #(32 * 9)]
    stp q20, q21, [x0, #(32 * 10)]
    stp q22, q23, [x0, #(32 * 11)]
    stp q24, q25, [x0, #(32 * 12)]
    stp q26, q27, [x0, #(32 * 13)]
    stp q28, q29, [x0, #(32 * 14)]
    stp q30, q31, [x0, #(32 * 15)]

    mrs x1, fpcr
    str x1, [x0, #OFF_EXT_FPCR]
    mrs x2, fpsr
    str x2, [x0, #OFF_EXT_FPSR]

    ret

.global restore_reduced_via_eret
.type restore_reduced_via_eret, %function
restore_reduced_via_eret:
    mov sp, x1

    ldr x1, [x0, #OFF_GEN_PC]
    msr elr_el1, x1

    ldr x1, [x0, #OFF_GEN_TPIDR]
    msr tpidr_el0, x1

    ldr x1, [x0, #OFF_GEN_SP]
    msr sp_el0, x1

    ldp x2, x3,   [x0, #(16 * 1)]
    ldp x4, x5,   [x0, #(16 * 2)]
    ldp x6, x7,   [x0, #(16 * 3)]
    ldp x8, x9,   [x0, #(16 * 4)]
    ldp x10, x11, [x0, #(16 * 5)]
    ldp x12, x13, [x0, #(16 * 6)]
    ldp x14, x15, [x0, #(16 * 7)]
    ldp x16, x17, [x0, #(16 * 8)]
    ldp x18, x19, [x0, #(16 * 9)]
    ldp x20, x21, [x0, #(16 * 10)]
    ldp x22, x23, [x0, #(16 * 11)]
    ldp x24, x25, [x0, #(16 * 12)]
    ldp x26, x27, [x0, #(16 * 13)]
    ldp x28, x29, [x0, #(16 * 14)]
    ldr x30,      [x0, #OFF_GEN_LR]

    ldp x0, x1,   [x0, #(16 * 0)]

    eret

.global restore_extended_via_eret
.type restore_extended_via_eret, %function
restore_extended_via_eret:
    ldp q0, q1,   [x0, #0]
    ldp q2, q3,   [x0, #32]
    ldp q4, q5,   [x0, #64]
    ldp q6, q7,   [x0, #96]
    ldp q8, q9,   [x0, #128]
    ldp q10, q11, [x0, #160]
    ldp q12, q13, [x0, #192]
    ldp q14, q15, [x0, #224]
    ldp q16, q17, [x0, #256]
    ldp q18, q19, [x0, #288]
    ldp q20, q21, [x0, #320]
    ldp q22, q23, [x0, #352]
    ldp q24, q25, [x0, #384]
    ldp q26, q27, [x0, #416]
    ldp q28, q29, [x0, #448]
    ldp q30, q31, [x0, #480]

    ldr x2, [x0, #OFF_EXT_FPCR]
    msr fpcr, x2
    ldr x2, [x0, #OFF_EXT_FPSR]
    msr fpsr, x2

    add x0, x0, #OFF_EXT_GEN
    b restore_reduced_via_eret

.global restore_reduced_via_ret
.type restore_reduced_via_ret, %function
restore_reduced_via_ret:
    mov sp, x1

    ldr x1,       [x0, #OFF_GEN_SP]
    msr sp_el0, x1

    ldr x1,       [x0, #OFF_GEN_TPIDR]
    msr tpidr_el0, x1

    ldp x2, x3,   [x0, #(16 * 1)]
    ldp x4, x5,   [x0, #(16 * 2)]
    ldp x6, x7,   [x0, #(16 * 3)]
    ldp x8, x9,   [x0, #(16 * 4)]
    ldp x10, x11, [x0, #(16 * 5)]
    ldp x12, x13, [x0, #(16 * 6)]
    ldp x14, x15, [x0, #(16 * 7)]
    ldp x16, x17, [x0, #(16 * 8)]
    ldp x18, x19, [x0, #(16 * 9)]
    ldp x20, x21, [x0, #(16 * 10)]
    ldp x22, x23, [x0, #(16 * 11)]
    ldp x24, x25, [x0, #(16 * 12)]
    ldp x26, x27, [x0, #(16 * 13)]
    ldp x28, x29, [x0, #(16 * 14)]

    ldr x30,      [x0, #OFF_GEN_LR]

    ldp x0, x1,   [x0, #(16 * 0)]

    msr spsel, #0

    msr daifclr, #0b0011
    isb

    ret

.global restore_extended_via_ret
.type restore_extended_via_ret, %function
restore_extended_via_ret:
    ldp q0, q1,   [x0, #0]
    ldp q2, q3,   [x0, #32]
    ldp q4, q5,   [x0, #64]
    ldp q6, q7,   [x0, #96]
    ldp q8, q9,   [x0, #128]
    ldp q10, q11, [x0, #160]
    ldp q12, q13, [x0, #192]
    ldp q14, q15, [x0, #224]
    ldp q16, q17, [x0, #256]
    ldp q18, q19, [x0, #288]
    ldp q20, q21, [x0, #320]
    ldp q22, q23, [x0, #352]
    ldp q24, q25, [x0, #384]
    ldp q26, q27, [x0, #416]
    ldp q28, q29, [x0, #448]
    ldp q30, q31, [x0, #480]

    ldr x2, [x0, #OFF_EXT_FPCR]
    msr fpcr, x2
    ldr x2, [x0, #OFF_EXT_FPSR]
    msr fpsr, x2

    add x0, x0, #OFF_EXT_GEN
    b restore_reduced_via_ret

.macro EXCEPTION_HANDLER handler
    sub sp, sp, #64

    stp x0, x1, [sp, #16]

    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #0]

    mrs x0, esr_el1
    mrs x1, far_el1
    stp x0, x1, [sp, #32]

    mrs x0, sp_el0
    mov x1, x0
    sub x0, x0, #GEN_SIZE
    msr sp_el0, x0

    str x1, [x0, #OFF_GEN_SP]

    mrs x1, tpidr_el0
    str x1, [x0, #OFF_GEN_TPIDR]

    stp x2, x3,   [x0, #(16 * 1)]
    stp x4, x5,   [x0, #(16 * 2)]
    stp x6, x7,   [x0, #(16 * 3)]
    stp x8, x9,   [x0, #(16 * 4)]
    stp x10, x11, [x0, #(16 * 5)]
    stp x12, x13, [x0, #(16 * 6)]
    stp x14, x15, [x0, #(16 * 7)]
    stp x16, x17, [x0, #(16 * 8)]
    stp x18, x19, [x0, #(16 * 9)]
    stp x20, x21, [x0, #(16 * 10)]
    stp x22, x23, [x0, #(16 * 11)]
    stp x24, x25, [x0, #(16 * 12)]
    stp x26, x27, [x0, #(16 * 13)]
    stp x28, x29, [x0, #(16 * 14)]

    str x30,      [x0, #OFF_GEN_LR]

    ldp x2, x3, [sp, #16] 
    stp x2, x3, [x0, #(16 * 0)]

    ldr x1, [sp, #0]
    str x1, [x0, #OFF_GEN_PC]

    ldr x1, [sp, #8]
    msr spsr_el1, x1

    ldp x2, x3, [sp, #32]
    msr esr_el1, x2
    msr far_el1, x3

    add sp, sp, #64

    b \handler
.endm

.macro NESTED_HANDLER handler
    stp x0, x1, [sp, #-16]!
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    stp x8, x9, [sp, #-16]!
    stp x10, x11, [sp, #-16]!
    stp x12, x13, [sp, #-16]!
    stp x14, x15, [sp, #-16]!
    stp x16, x17, [sp, #-16]!
    stp x18, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    stp x24, x25, [sp, #-16]!
    stp x26, x27, [sp, #-16]!
    stp x28, x29, [sp, #-16]!
    str x30,      [sp, #-16]!

    mrs x10, elr_el1
    mrs x11, spsr_el1

    stp x10, x11, [sp, #-16]!

    mrs x0, esr_el1
    mrs x1, far_el1

    bl \handler

    ldp x10, x11, [sp], #16

    msr elr_el1, x10
    msr spsr_el1, x11

    ldr x30,      [sp], #16
    ldp x28, x29, [sp], #16
    ldp x26, x27, [sp], #16
    ldp x24, x25, [sp], #16
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x18, x19, [sp], #16
    ldp x16, x17, [sp], #16
    ldp x14, x15, [sp], #16
    ldp x12, x13, [sp], #16
    ldp x10, x11, [sp], #16
    ldp x8, x9,   [sp], #16
    ldp x6, x7,   [sp], #16
    ldp x4, x5,   [sp], #16
    ldp x2, x3,   [sp], #16
    ldp x0, x1,   [sp], #16

    eret
.endm

// --- EL1t --- //

_handler_el1t_sync:
    EXCEPTION_HANDLER el1t_sync

_handler_el1t_irq:
    EXCEPTION_HANDLER el1t_irq

_handler_el1t_fiq:
    EXCEPTION_HANDLER el1t_fiq

_handler_el1t_serror:
    EXCEPTION_HANDLER el1t_serror

// --- EL1h --- //

_handler_el1h_sync:
    NESTED_HANDLER el1h_sync

_handler_el1h_irq:
    NESTED_HANDLER el1h_irq

_handler_el1h_fiq:
    NESTED_HANDLER el1h_fiq

_handler_el1h_serror:
    NESTED_HANDLER el1h_serror

// --- EL0 --- //

_handler_el0_sync:
    EXCEPTION_HANDLER el0_sync

_handler_el0_irq:
    EXCEPTION_HANDLER el0_irq

_handler_el0_fiq:
    EXCEPTION_HANDLER el0_fiq

_handler_el0_serror:
    EXCEPTION_HANDLER el0_serror

.balign 0x800
.globl exception_vector_table
exception_vector_table:

_el1t_sync:
    b _handler_el1t_sync
.balign 0x80
_el1t_irq:
    b _handler_el1t_irq
.balign 0x80
_el1t_fiq:
    b _handler_el1t_fiq
.balign 0x80
_el1t_serror:
    b _handler_el1t_serror

.balign 0x80
_el1h_sync:
    b _handler_el1h_sync
.balign 0x80
_el1h_irq:
    b _handler_el1h_irq
.balign 0x80
_el1h_fiq:
    b _handler_el1h_fiq
.balign 0x80
_el1h_serror:
    b _handler_el1h_serror

.balign 0x80
_el0_sync:
    b _handler_el0_sync
.balign 0x80
_el0_irq:
    b _handler_el0_irq
.balign 0x80
_el0_fiq:
    b _handler_el0_fiq
.balign 0x80
_el0_serror:
    b _handler_el0_serror

.balign 0x80
_el0_32_sync:
    b .
.balign 0x80
_el0_32_irq:
    b .
.balign 0x80
_el0_32_fiq:
    b .
.balign 0x80
_el0_32_serror:
    b .
.balign 0x80
