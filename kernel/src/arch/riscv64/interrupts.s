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

.equ GEN_SIZE,   256
.equ OFF_GEN_PC, 240
.equ OFF_GEN_SP, 248

.equ EXT_SIZE,     528
.equ OFF_EXT_FCSR, 256
.equ OFF_EXT_GEN,  272

.equ NESTED_SIZE,  256
.equ NOFF_SEPC,    240
.equ NOFF_SSTATUS, 248

.equ ANCHOR_CPU_CONTEXT, 0
.equ ANCHOR_KSP,         8
.equ ANCHOR_SCRATCH_T1,  16
.equ ANCHOR_SCRATCH_T2,  24
.equ ANCHOR_IN_HANDLER,  32

.section .text

.macro STORE_REDUCED
    sd ra,  (8*0)(sp)
    sd gp,  (8*1)(sp)
    sd tp,  (8*2)(sp)
    sd t0,  (8*3)(sp)
    sd t1,  (8*4)(sp)
    sd t2,  (8*5)(sp)
    sd s0,  (8*6)(sp)
    sd s1,  (8*7)(sp)
    sd a0,  (8*8)(sp)
    sd a1,  (8*9)(sp)
    sd a2,  (8*10)(sp)
    sd a3,  (8*11)(sp)
    sd a4,  (8*12)(sp)
    sd a5,  (8*13)(sp)
    sd a6,  (8*14)(sp)
    sd a7,  (8*15)(sp)
    sd s2,  (8*16)(sp)
    sd s3,  (8*17)(sp)
    sd s4,  (8*18)(sp)
    sd s5,  (8*19)(sp)
    sd s6,  (8*20)(sp)
    sd s7,  (8*21)(sp)
    sd s8,  (8*22)(sp)
    sd s9,  (8*23)(sp)
    sd s10, (8*24)(sp)
    sd s11, (8*25)(sp)
    sd t3,  (8*26)(sp)
    sd t4,  (8*27)(sp)
    sd t5,  (8*28)(sp)
    sd t6,  (8*29)(sp)
.endm

.macro LOAD_REDUCED_EXCEPT_SP_A0
    ld ra,  (8*0)(a0)
    ld gp,  (8*1)(a0)
    ld tp,  (8*2)(a0)
    ld t0,  (8*3)(a0)
    ld t1,  (8*4)(a0)
    ld t2,  (8*5)(a0)
    ld s0,  (8*6)(a0)
    ld s1,  (8*7)(a0)
    ld a1,  (8*9)(a0)
    ld a2,  (8*10)(a0)
    ld a3,  (8*11)(a0)
    ld a4,  (8*12)(a0)
    ld a5,  (8*13)(a0)
    ld a6,  (8*14)(a0)
    ld a7,  (8*15)(a0)
    ld s2,  (8*16)(a0)
    ld s3,  (8*17)(a0)
    ld s4,  (8*18)(a0)
    ld s5,  (8*19)(a0)
    ld s6,  (8*20)(a0)
    ld s7,  (8*21)(a0)
    ld s8,  (8*22)(a0)
    ld s9,  (8*23)(a0)
    ld s10, (8*24)(a0)
    ld s11, (8*25)(a0)
    ld t3,  (8*26)(a0)
    ld t4,  (8*27)(a0)
    ld t5,  (8*28)(a0)
    ld t6,  (8*29)(a0)
.endm

.global call_system
.type call_system, %function
call_system:
    csrr t0, sscratch
    li   t1, 1
    sd   t1, ANCHOR_IN_HANDLER(t0)

    csrci sstatus, 2

    addi sp, sp, -GEN_SIZE
    STORE_REDUCED

    addi t0, sp, GEN_SIZE
    sd t0, OFF_GEN_SP(sp)

    sd ra, OFF_GEN_PC(sp)

    mv a0, sp
    call internal_entry

    mv a0, sp
    call internal_call_system

    mv a0, sp
    tail internal_exit

.option push
.option arch, +f, +d

.global extend_frame
.type extend_frame, %function
extend_frame:
    addi a0, a0, -OFF_EXT_GEN

    fsd f0,  (8*0)(a0)
    fsd f1,  (8*1)(a0)
    fsd f2,  (8*2)(a0)
    fsd f3,  (8*3)(a0)
    fsd f4,  (8*4)(a0)
    fsd f5,  (8*5)(a0)
    fsd f6,  (8*6)(a0)
    fsd f7,  (8*7)(a0)
    fsd f8,  (8*8)(a0)
    fsd f9,  (8*9)(a0)
    fsd f10, (8*10)(a0)
    fsd f11, (8*11)(a0)
    fsd f12, (8*12)(a0)
    fsd f13, (8*13)(a0)
    fsd f14, (8*14)(a0)
    fsd f15, (8*15)(a0)
    fsd f16, (8*16)(a0)
    fsd f17, (8*17)(a0)
    fsd f18, (8*18)(a0)
    fsd f19, (8*19)(a0)
    fsd f20, (8*20)(a0)
    fsd f21, (8*21)(a0)
    fsd f22, (8*22)(a0)
    fsd f23, (8*23)(a0)
    fsd f24, (8*24)(a0)
    fsd f25, (8*25)(a0)
    fsd f26, (8*26)(a0)
    fsd f27, (8*27)(a0)
    fsd f28, (8*28)(a0)
    fsd f29, (8*29)(a0)
    fsd f30, (8*30)(a0)
    fsd f31, (8*31)(a0)

    frcsr t0
    sd t0, OFF_EXT_FCSR(a0)

    ret

.global restore_extended_via_sret
.type restore_extended_via_sret, %function
restore_extended_via_sret:
    fld f0,  (8*0)(a0)
    fld f1,  (8*1)(a0)
    fld f2,  (8*2)(a0)
    fld f3,  (8*3)(a0)
    fld f4,  (8*4)(a0)
    fld f5,  (8*5)(a0)
    fld f6,  (8*6)(a0)
    fld f7,  (8*7)(a0)
    fld f8,  (8*8)(a0)
    fld f9,  (8*9)(a0)
    fld f10, (8*10)(a0)
    fld f11, (8*11)(a0)
    fld f12, (8*12)(a0)
    fld f13, (8*13)(a0)
    fld f14, (8*14)(a0)
    fld f15, (8*15)(a0)
    fld f16, (8*16)(a0)
    fld f17, (8*17)(a0)
    fld f18, (8*18)(a0)
    fld f19, (8*19)(a0)
    fld f20, (8*20)(a0)
    fld f21, (8*21)(a0)
    fld f22, (8*22)(a0)
    fld f23, (8*23)(a0)
    fld f24, (8*24)(a0)
    fld f25, (8*25)(a0)
    fld f26, (8*26)(a0)
    fld f27, (8*27)(a0)
    fld f28, (8*28)(a0)
    fld f29, (8*29)(a0)
    fld f30, (8*30)(a0)
    fld f31, (8*31)(a0)

    ld t0, OFF_EXT_FCSR(a0)
    fscsr t0

    addi a0, a0, OFF_EXT_GEN
    j restore_reduced_via_sret

.global restore_extended_via_ret
.type restore_extended_via_ret, %function
restore_extended_via_ret:
    fld f0,  (8*0)(a0)
    fld f1,  (8*1)(a0)
    fld f2,  (8*2)(a0)
    fld f3,  (8*3)(a0)
    fld f4,  (8*4)(a0)
    fld f5,  (8*5)(a0)
    fld f6,  (8*6)(a0)
    fld f7,  (8*7)(a0)
    fld f8,  (8*8)(a0)
    fld f9,  (8*9)(a0)
    fld f10, (8*10)(a0)
    fld f11, (8*11)(a0)
    fld f12, (8*12)(a0)
    fld f13, (8*13)(a0)
    fld f14, (8*14)(a0)
    fld f15, (8*15)(a0)
    fld f16, (8*16)(a0)
    fld f17, (8*17)(a0)
    fld f18, (8*18)(a0)
    fld f19, (8*19)(a0)
    fld f20, (8*20)(a0)
    fld f21, (8*21)(a0)
    fld f22, (8*22)(a0)
    fld f23, (8*23)(a0)
    fld f24, (8*24)(a0)
    fld f25, (8*25)(a0)
    fld f26, (8*26)(a0)
    fld f27, (8*27)(a0)
    fld f28, (8*28)(a0)
    fld f29, (8*29)(a0)
    fld f30, (8*30)(a0)
    fld f31, (8*31)(a0)

    ld t0, OFF_EXT_FCSR(a0)
    fscsr t0

    addi a0, a0, OFF_EXT_GEN
    j restore_reduced_via_ret

.option pop

.global restore_reduced_via_sret
.type restore_reduced_via_sret, %function
restore_reduced_via_sret:
    csrr t0, sscratch
    sd   zero, ANCHOR_IN_HANDLER(t0)

    ld t0, OFF_GEN_PC(a0)
    csrw sepc, t0

    ld t1, OFF_GEN_SP(a0)
    mv sp, t1

    LOAD_REDUCED_EXCEPT_SP_A0
    ld a0, (8*8)(a0)

    sret

.global restore_reduced_via_ret
.type restore_reduced_via_ret, %function
restore_reduced_via_ret:
    csrr t0, sscratch
    sd   zero, ANCHOR_IN_HANDLER(t0)

    ld t1, OFF_GEN_SP(a0)
    mv sp, t1

    LOAD_REDUCED_EXCEPT_SP_A0
    ld a0, (8*8)(a0)

    csrsi sstatus, 2
    ret

.balign 4
.global trap_vector
.type trap_vector, %function
trap_vector:
    csrrw t0, sscratch, t0
    sd    t1, ANCHOR_SCRATCH_T1(t0)
    sd    t2, ANCHOR_SCRATCH_T2(t0)

    ld    t1, ANCHOR_IN_HANDLER(t0)
    bnez  t1, 2f

    li    t1, 1
    sd    t1, ANCHOR_IN_HANDLER(t0)

    mv    t2, sp
    addi  sp, t2, -GEN_SIZE
    STORE_REDUCED

    sd    t2, OFF_GEN_SP(sp)

    ld    t2, ANCHOR_SCRATCH_T2(t0)
    sd    t2, (8*5)(sp)
    ld    t2, ANCHOR_SCRATCH_T1(t0)
    sd    t2, (8*4)(sp)
    csrr  t2, sscratch
    sd    t2, (8*3)(sp)

    csrw  sscratch, t0

    csrr  t2, sepc
    sd    t2, OFF_GEN_PC(sp)

    ld    t2, ANCHOR_CPU_CONTEXT(t0)
    mv    tp, t2

    mv    a0, sp
    csrr  a1, sstatus

    ld    t2, ANCHOR_KSP(t0)
    mv    sp, t2

    tail  trap_top_level

2:
    ld    t2, ANCHOR_SCRATCH_T2(t0)
    ld    t1, ANCHOR_SCRATCH_T1(t0)
    csrrw t0, sscratch, t0
    j     nested_entry

nested_entry:
    addi sp, sp, -NESTED_SIZE

    sd ra,  (8*0)(sp)
    sd gp,  (8*1)(sp)
    sd tp,  (8*2)(sp)
    sd t0,  (8*3)(sp)
    sd t1,  (8*4)(sp)
    sd t2,  (8*5)(sp)
    sd s0,  (8*6)(sp)
    sd s1,  (8*7)(sp)
    sd a0,  (8*8)(sp)
    sd a1,  (8*9)(sp)
    sd a2,  (8*10)(sp)
    sd a3,  (8*11)(sp)
    sd a4,  (8*12)(sp)
    sd a5,  (8*13)(sp)
    sd a6,  (8*14)(sp)
    sd a7,  (8*15)(sp)
    sd s2,  (8*16)(sp)
    sd s3,  (8*17)(sp)
    sd s4,  (8*18)(sp)
    sd s5,  (8*19)(sp)
    sd s6,  (8*20)(sp)
    sd s7,  (8*21)(sp)
    sd s8,  (8*22)(sp)
    sd s9,  (8*23)(sp)
    sd s10, (8*24)(sp)
    sd s11, (8*25)(sp)
    sd t3,  (8*26)(sp)
    sd t4,  (8*27)(sp)
    sd t5,  (8*28)(sp)
    sd t6,  (8*29)(sp)

    csrr t0, sepc
    sd   t0, NOFF_SEPC(sp)
    csrr t0, sstatus
    sd   t0, NOFF_SSTATUS(sp)

    csrr a0, scause
    csrr a1, stval
    call trap_nested

    ld t0, NOFF_SEPC(sp)
    csrw sepc, t0
    ld t0, NOFF_SSTATUS(sp)
    csrw sstatus, t0

    ld ra,  (8*0)(sp)
    ld gp,  (8*1)(sp)
    ld tp,  (8*2)(sp)
    ld t0,  (8*3)(sp)
    ld t1,  (8*4)(sp)
    ld t2,  (8*5)(sp)
    ld s0,  (8*6)(sp)
    ld s1,  (8*7)(sp)
    ld a0,  (8*8)(sp)
    ld a1,  (8*9)(sp)
    ld a2,  (8*10)(sp)
    ld a3,  (8*11)(sp)
    ld a4,  (8*12)(sp)
    ld a5,  (8*13)(sp)
    ld a6,  (8*14)(sp)
    ld a7,  (8*15)(sp)
    ld s2,  (8*16)(sp)
    ld s3,  (8*17)(sp)
    ld s4,  (8*18)(sp)
    ld s5,  (8*19)(sp)
    ld s6,  (8*20)(sp)
    ld s7,  (8*21)(sp)
    ld s8,  (8*22)(sp)
    ld s9,  (8*23)(sp)
    ld s10, (8*24)(sp)
    ld s11, (8*25)(sp)
    ld t3,  (8*26)(sp)
    ld t4,  (8*27)(sp)
    ld t5,  (8*28)(sp)
    ld t6,  (8*29)(sp)

    addi sp, sp, NESTED_SIZE

    sret
