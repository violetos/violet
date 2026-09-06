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

// --- arch/aarch64/registers.zig --- //

pub inline fn loadTpidrEl0() u64 {
    return asm volatile ("mrs %[output], tpidr_el0"
        : [output] "=r" (-> u64),
    );
}

pub fn storeTpidrEl0(value: u64) void {
    asm volatile ("msr tpidr_el0, %[input]"
        :
        : [input] "r" (value),
    );
}

pub inline fn loadTpidrroEl0() u64 {
    return asm volatile ("mrs %[output], tpidrro_el0"
        : [output] "=r" (-> u64),
    );
}

pub inline fn storeTpidrroEl0(value: u64) void {
    asm volatile ("msr tpidrro_el0, %[input]"
        :
        : [input] "r" (value),
    );
}

pub inline fn loadTpidrEl1() u64 {
    return asm volatile ("mrs %[output], tpidr_el1"
        : [output] "=r" (-> u64),
    );
}

pub inline fn storeTpidrEl1(value: u64) void {
    asm volatile ("msr tpidr_el1, %[input]"
        :
        : [input] "r" (value),
    );
}

pub inline fn loadVbarEl1() u64 {
    return asm volatile ("mrs %[output], vbar_el1"
        : [output] "=r" (-> u64),
    );
}

pub inline fn storeVbarEl1(exception_vector_table: u64) void {
    asm volatile ("msr vbar_el1, %[input]"
        :
        : [input] "r" (exception_vector_table),
    );
}

pub inline fn loadFarEl1() u64 {
    return asm volatile ("mrs %[output], far_el1"
        : [output] "=r" (-> u64),
    );
}

pub inline fn storeFarEl1(l0_table: u64) void {
    asm volatile ("msr far_el1, %[input]"
        :
        : [input] "r" (l0_table),
    );
}

/// Assumes that we are at EL1h
pub inline fn storeSpEl0(sp_el0: u64) void {
    asm volatile (
        \\ msr sp_el0, %[sp_el0]
        :
        : [sp_el0] "r" (sp_el0),
    );
}

/// Assumes that we are at EL1h
pub inline fn storeSpEl1(sp_el1: u64) void {
    asm volatile (
        \\ msr spsel, #1
        \\ mov sp, %[sp_el1]
        \\ msr spsel, #0
        :
        : [sp_el1] "r" (sp_el1),
        : .{ .memory = true });
}

pub inline fn loadTtbr0El1() u64 {
    return asm volatile ("mrs %[output], ttbr0_el1"
        : [output] "=r" (-> u64),
        :
        : .{ .memory = true });
}

pub inline fn storeTtbr0El1(l0_table: u64) void {
    asm volatile ("msr ttbr0_el1, %[input]"
        :
        : [input] "r" (l0_table),
        : .{ .memory = true });
}

pub inline fn loadTtbr1El1() u64 {
    return asm volatile ("mrs %[output], ttbr1_el1"
        : [output] "=r" (-> u64),
        :
        : .{ .memory = true });
}

pub inline fn storeTtbr1El1(l0_table: u64) void {
    asm volatile ("msr ttbr1_el1, %[input]"
        :
        : [input] "r" (l0_table),
        : .{ .memory = true });
}

/// Translation Control Register (EL1)
pub const TCR_EL1 = packed struct(u64) {
    /// The size offset of the memory region addressed by TTBR0_EL1. The region size is 2(64-t0sz) bytes.
    t0sz: u6, // bit 0-5

    _reserved0: u1 = 0, // bit 6

    /// Translation table walk disable for translations using TTBR0_EL1.
    epd0: bool, // bit 7

    /// Inner cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
    irgn0: enum(u2) { // bit 8-9
        /// Non-cacheable
        nc = 0b00,
        /// Write-Back Read-Allocate Write-Allocate Cacheable
        wb_ra_wa = 0b01,
        /// Write-Through Read-Allocate No Write-Allocate Cacheable
        wt_ra_nwa = 0b10,
        /// Write-Back Read-Allocate No Write-Allocate Cacheable
        wb_ra_nwa = 0b11,
    },

    /// Outer cacheability attribute for memory associated with translation table walks using TTBR0_EL1.
    orgn0: enum(u2) { // bit 10-11
        /// Non-cacheable
        nc = 0b00,
        /// Write-Back Read-Allocate Write-Allocate Cacheable
        wb_ra_wa = 0b01,
        /// Write-Through Read-Allocate No Write-Allocate Cacheable
        wt_ra_nwa = 0b10,
        /// Write-Back Read-Allocate No Write-Allocate Cacheable
        wb_ra_nwa = 0b11,
    },

    /// Shareability attribute for memory associated with translation table walks using TTBR0_EL1
    sh0: enum(u2) { // bit 12-13
        non_shareable = 0b00,
        _reserved0 = 0b01,
        outer_shareable = 0b10,
        inner_shareable = 0b11,
    },

    /// Granule size for the TTBR0_EL1.
    tg0: enum(u2) { // bit 14-15
        @"4kb" = 0b00,
        @"64kb" = 0b01,
        @"16kb" = 0b10,
        /// Could be implementation defined.
        _reserved0 = 0b11,
    },

    /// The size offset of the memory region addressed by TTBR1_EL1. The region size is 2(64-t1sz) bytes.
    t1sz: u6, // bit 16-21

    /// Selects whether TTBR0_EL1 or TTBR1_EL1 defines the ASID.
    a1: enum(u1) { // bit 22
        ttbr0_el1 = 0b0,
        ttbr1_el1 = 0b1,
    },

    /// Translation table walk disable for translations using TTBR1_EL1.
    epd1: bool, // bit 23

    /// Inner cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
    irgn1: enum(u2) { // bit 24-25
        /// Non-cacheable
        nc = 0b00,
        /// Write-Back Read-Allocate Write-Allocate Cacheable
        wb_ra_wa = 0b01,
        /// Write-Through Read-Allocate No Write-Allocate Cacheable
        wt_ra_nwa = 0b10,
        /// Write-Back Read-Allocate No Write-Allocate Cacheable
        wb_ra_nwa = 0b11,
    },

    /// Outer cacheability attribute for memory associated with translation table walks using TTBR1_EL1.
    orgn1: enum(u2) { // bit 26-27
        /// Non-cacheable
        nc = 0b00,
        /// Write-Back Read-Allocate Write-Allocate Cacheable
        wb_ra_wa = 0b01,
        /// Write-Through Read-Allocate No Write-Allocate Cacheable
        wt_ra_nwa = 0b10,
        /// Write-Back Read-Allocate No Write-Allocate Cacheable
        wb_ra_nwa = 0b11,
    },

    /// Shareability attribute for memory associated with translation table walks using TTBR1_EL1
    sh1: enum(u2) { // bit 28-29
        non_shareable = 0b00,
        _reserved0 = 0b01,
        outer_shareable = 0b10,
        inner_shareable = 0b11,
    },

    /// Granule size for the TTBR1_EL1.
    tg1: enum(u2) { // bit 30-31
        /// Could be implementation defined.
        _reserved0 = 0b00,
        @"16kb" = 0b01,
        @"4kb" = 0b10,
        @"64kb" = 0b11,
    },

    /// Intermediate Physical Address Size.
    ips: enum(u3) { // bit 32-34
        @"32bits_4gb" = 0b000,
        @"36bits_64gb" = 0b001,
        @"40bits_1tb" = 0b010,
        @"42bits_4tb" = 0b011,
        @"44bits_16tb" = 0b100,
        @"48bits_256tb" = 0b101,
        @"52bits_4pb" = 0b110,
        @"56bits_64pb" = 0b111,
    },

    _reserved1: u1 = 0, // bit 35

    /// ASID Size.
    as: enum(u1) { // bit 36
        /// The upper 8 bits of TTBR0_EL1 and TTBR1_EL1 are ignored by hardware for every purpose except reading back the register,
        /// and are treated as if they are all zeros for when used for allocation and matching entries in the TLB.
        u8 = 0b0,
        /// The upper 16 bits of TTBR0_EL1 and TTBR1_EL1 are used for allocation and matching in the TLB.
        u16 = 0b1,
    } = .u8,

    /// Top Byte ignored. Indicates whether the top byte of an address is used for address match for the TTBR0_EL1 region, or ignored and used for tagged addresses.
    tbi0: enum(u1) { // bit 37
        used = 0b0,
        ignored = 0b1,
    },

    /// Top Byte ignored. Indicates whether the top byte of an address is used for address match for the TTBR1_EL1 region, or ignored and used for tagged addresses.
    tbi1: enum(u1) { // bit 38
        used = 0b0,
        ignored = 0b1,
    },

    /// Hardware Access flag update in stage 1 translations from EL0 and EL1.
    ///
    /// When FEAT_HAFDBS is implemented
    ha: bool = false, // bit 39

    /// Hardware management of dirty state in stage 1 translations from EL0 and EL1.
    ///
    /// When FEAT_HAFDBS is implemented
    hd: bool = false, // bit 40

    /// Hierarchical Permission Disables.
    ///
    /// This affects the hierarchical control bits, APTable, PXNTable, and UXNTable, except NSTable, in the translation tables pointed to by TTBR0_EL1.
    ///
    /// When FEAT_HPDS is implemented
    hpd0: enum(u1) { // bit 41
        enabled = 0b0,
        disabled = 0b1,
    } = .enabled,
    /// Hierarchical Permission Disables.
    ///
    /// This affects the hierarchical control bits, APTable, PXNTable, and UXNTable, except NSTable, in the translation tables pointed to by TTBR1_EL1.
    ///
    /// When FEAT_HPDS is implemented
    hpd1: enum(u1) { // bit 42
        enabled = 0b0,
        disabled = 0b1,
    } = .enabled,

    hwu059: u1 = 0, // bit 43
    hwu060: u1 = 0, // bit 44
    hwu061: u1 = 0, // bit 45
    hwu062: u1 = 0, // bit 46

    hwu159: u1 = 0, // bit 47
    hwu160: u1 = 0, // bit 48
    hwu161: u1 = 0, // bit 49
    hwu162: u1 = 0, // bit 50

    /// Controls the use of the top byte of instruction addresses for address matching (TTBR0_EL1).
    ///
    /// When FEAT_PAuth is implemented
    tbid0: u1 = 0, // bit 51
    /// Controls the use of the top byte of instruction addresses for address matching (TTBR1_EL1).
    ///
    /// When FEAT_PAuth is implemented
    tbid1: u1 = 0, // bit 52

    /// Non-Fault translation timing Disable when using TTBR0_EL1.
    ///
    /// When FEAT_SVE is implemented
    nfd0: u1 = 0, // bit 53
    /// Non-Fault translation timing Disable when using TTBR1_EL1.
    ///
    /// When FEAT_SVE is implemented
    nfd1: u1 = 0, // bit 54

    /// Faulting control for unprivileged access to any address translated by TTBR0_EL1.
    ///
    /// When FEAT_E0PD is implemented
    e0pd0: u1 = 0, // bit 55
    /// Faulting control for unprivileged access to any address translated by TTBR1_EL1.
    ///
    /// When FEAT_E0PD is implemented
    e0pd1: u1 = 0, // bit 56

    /// When FEAT_MTE2 is implemented
    tcma0: u1 = 0, // bit 57
    /// When FEAT_MTE2 is implemented
    tcma1: u1 = 0, // bit 58

    /// When FEAT_LPA2 is implemented and (FEAT_D128 is not implemented or TCR2_EL1.D128 == 0)
    ds: u1 = 0, // bit 59

    /// Extended memory tag checking (TTBR0_EL1).
    ///
    /// When FEAT_MTE_NO_ADDRESS_TAGS is implemented or FEAT_MTE_CANONICAL_TAGS is implemented
    mtx0: u1 = 0, // bit 6
    /// Extended memory tag checking (TTBR1_EL1).
    ///
    /// When FEAT_MTE_NO_ADDRESS_TAGS is implemented or FEAT_MTE_CANONICAL_TAGS is implemented
    mtx1: u1 = 0, // bit 61

    _reserved3: u2 = 0, // bit 62-63

    pub fn load() @This() {
        return asm volatile ("mrs %[output], tcr_el1"
            : [output] "=r" (-> @This()),
        );
    }

    pub fn store(self: @This()) void {
        asm volatile ("msr tcr_el1, %[input]"
            :
            : [input] "r" (self),
        );
    }
};

pub const ESR_EL1 = packed struct(u64) {
    iss: packed union { // bits 0-24
        unknown_reason: packed struct(u25) { _reserved0: u25 },
        brk_aarch64: packed struct(u25) {
            comment: u16, // bit 0-15
            _reserved0: u9, // bit 16-24
        },
        svc_hvc: packed struct(u25) {
            imm16: u16, // bit 0-15
            _reserved0: u9, // bit 16-24
        },
        data_abort: packed struct(u25) {
            /// Data Fault Status Code.
            dfsc: enum(u6) { // bit 0-5
                /// Address size fault, level 0 of translation or translation table base register.
                address_size_fault_lv0 = 0b000000,
                /// Address size fault, level 1.
                address_size_fault_lv1 = 0b000001,
                /// Address size fault, level 2.
                address_size_fault_lv2 = 0b000010,
                /// Address size fault, level 3.
                address_size_fault_lv3 = 0b000011,

                /// Translation fault, level 0.
                translation_fault_lv0 = 0b000100,
                /// Translation fault, level 1.
                translation_fault_lv1 = 0b000101,
                /// Translation fault, level 2.
                translation_fault_lv2 = 0b000110,
                /// Translation fault, level 3.
                translation_fault_lv3 = 0b000111,

                /// Translation fault, level 1.
                access_flag_lv1 = 0b001001,
                /// Translation fault, level 2.
                access_flag_lv2 = 0b001010,
                /// Translation fault, level 3.
                access_flag_lv3 = 0b001011,
                /// Translation fault, level 0.
                /// When FEAT_LPA2 is implemented.
                access_flag_lv0 = 0b001000,

                /// Permission fault, level 0.
                /// When FEAT_LPA2 is implemented
                permission_fault_lv0 = 0b001100,
                /// Permission fault, level 1.
                permission_fault_lv1 = 0b001101,
                /// Permission fault, level 2.
                permission_fault_lv2 = 0b001110,
                /// Permission fault, level 3.
                permission_fault_lv3 = 0b001111,

                /// Synchronous External abort, not on translation table walk or hardware update of translation table.
                synchronous_external_abort = 0b010000,

                // TODO ...

                alignment_fault = 0b100001,

                // TODO ...

                _,
            },
            /// Write not Read. Indicates whether a synchronous abort was caused by an instruction writing to a memory location, or by an instruction reading from a memory location.
            wnr: enum(u1) { // bit 6
                reading = 0b0,
                writing = 0b1,
            },
            /// For a stage 2 fault, indicates whether the fault was a stage 2 fault on an access made for a stage 1 translation table walk.
            s1ptw: enum(u1) { // bit 7
                fault_not_on_a_stage_2 = 0b0,
                fault_on_the_stage_2 = 0b01,
            },
            /// TODO.
            cm: u1, // bit 8
            ea: u1, // bit 9
            /// FAR Not Valid.
            fnv: enum(u1) { // bit 10
                valid = 0b0,
                not_valid = 0b1,
            },
            _bit11_12: u2, // bit 11-12
            _reserved0: u1, // bit 13
            _bit14: u1, // bit 14
            _bit15: u1, // bit 15
            _bit16_20: u5, // bit 16-20
            sse: u1, // bit 21
            sas: u2, // bit 22-23
            isv: u1,
        },
    },
    il: enum(u1) { // bit 25
        b16 = 0b0,
        b32 = 0b1,
    },
    ec: enum(u6) { // bits 26-31
        /// ISS encoding for exceptions with an unknown reason ;
        /// ISS2 encoding for all other exceptions.
        unknown_reason = 0b000000,
        trapped_wfi_wfe = 0b000001,
        trapped_mcr_mrc_cp15 = 0b000011,
        trapped_mcrr_mrrc_cp15 = 0b000100,
        trapped_mcr_mrc_cp14 = 0b000101,
        trapped_ldc_stc = 0b000110,
        trapped_sme_sve_simd_fp = 0b000111,
        trapped_ptr_auth = 0b001001,
        trapped_uncovered = 0b001010,
        trapped_mrrc_cp14 = 0b001100,
        branch_target_exception = 0b001101,
        illegal_execution = 0b001110,
        svc_inst_aarch32 = 0b010001,
        trapped_msrr_mrrs_sys_uncovered_aarch64 = 0b010100,
        /// ISS encoding for an exception from HVC or SVC instruction execution ;
        /// ISS2 encoding for all other exceptions.
        svc_inst_aarch64 = 0b010101,
        trapped_msr_mrs_sys_uncovered_aarch64 = 0b011000,
        trapped_sve = 0b011001,
        trapped_eret_erteaa_erteab = 0b011010,
        trapped_tstart = 0b011011,
        pac_fail = 0b011100,
        trapped_sme = 0b011101,
        inst_abort_lower_el = 0b100000,
        inst_abort_same_el = 0b100001,
        pc_align_fault = 0b100010,
        /// ISS encoding for an exception from a Data Abort ;
        /// ISS2 encoding for an exception from a Data Abort.
        data_abort_lower_el = 0b100100,
        /// ISS encoding for an exception from a Data Abort ;
        /// ISS2 encoding for an exception from a Data Abort.
        data_abort_same_el = 0b100101,
        sp_align_fault = 0b100110,
        mem_op = 0b100111,
        trapped_fp_aarch32 = 0b101000,
        trapped_fp_aarch64 = 0b101100,
        gcs = 0b101101,
        serror = 0b101111,
        breakpoint_lower_el = 0b110000,
        breakpoint_same_el = 0b110001,
        software_step_lower_el = 0b110010,
        software_step_same_el = 0b110011,
        watchpoint_lower_el = 0b110100,
        watchpoint_same_el = 0b110101,
        bkpt_aarch32 = 0b111000,
        brk_aarch64 = 0b111100,
        profiling = 0b111101,
    },
    iss2: packed union { // bit 32-55
        // TODO ...
        all_others: packed struct(u24) { _reserved0: u24 },
    },
    _reserved0: u8, // bit 56-63

    pub fn load() @This() {
        return asm volatile ("mrs %[output], esr_el1"
            : [output] "=r" (-> @This()),
        );
    }

    pub fn dump(self: @This()) void {
        std.log.info(
            \\ 
            \\ -------- ESR_EL1 --------
            \\
            // \\ iss {}
            \\ il {s}
            \\ ec {s}
            \\
            \\ -------------------------
        , .{
            // self.iss,
            @tagName(self.il),
            @tagName(self.ec),
        });
    }
};

/// Saved Program Status Register (EL1)
pub const SPSR_EL1 = packed struct(u64) {
    /// AArch64 Exception level and selected Stack Pointer.
    mode: enum(u4) { // bit 0-3
        el0 = 0b0000,
        el1t = 0b0100,
        el1h = 0b0101,
        // TODO. there's two others
    },
    es: u1 = 0, // bit 4,
    _reserved0: u1 = 0, // bit 5
    f: bool = false, // bit 6
    i: bool = false, // bit 7
    a: bool = false, // bit 8
    d: bool = false, // bit 9
    _reserved1: u18 = 0, // bit 10-17
    v: u1 = 0, // bit 28
    c: u1 = 0, // bit 29
    z: u1 = 0, // bit 30
    n: u1 = 0, // bit 31
    _reserved2: u32 = 0, // bit 32-63

    pub fn load() @This() {
        return asm volatile ("mrs %[output], spsr_el1"
            : [output] "=r" (-> @This()),
        );
    }

    pub fn store(self: @This()) void {
        asm volatile ("msr spsr_el1, %[input]"
            :
            : [input] "r" (self),
        );
    }
};

/// Memory Attribute Indirection Register (EL1)
pub const MAIR_EL1 = packed struct(u64) {
    attr0: u8 = 0,
    attr1: u8 = 0,
    attr2: u8 = 0,
    attr3: u8 = 0,
    attr4: u8 = 0,
    attr5: u8 = 0,
    attr6: u8 = 0,
    attr7: u8 = 0,

    pub const DEVICE_nGnRnE = 0b0000_00_00;
    pub const DEVICE_nGnRE = 0b0000_01_00;
    pub const DEVICE_nGRE = 0b0000_10_00;
    pub const DEVICE_GRE = 0b0000_11_00;

    pub const NORMAL_WRITEBACK_TRANSIENT = 0b0111_0111;
    pub const NORMAL_WRITEBACK_NONTRANSIENT = 0b1111_1111;
    pub const NORMAL_WRITETHROUGH_TRANSIENT = 0b0011_0011;
    pub const NORMAL_WRITETHROUGH_NONTRANSIENT = 0b1011_1011;
    pub const NORMAL_NONCACHEABLE = 0b0100_0100;

    pub fn load() @This() {
        return asm volatile ("mrs %[output], mair_el1"
            : [output] "=r" (-> @This()),
        );
    }

    pub fn store(self: @This()) void {
        asm volatile ("msr mair_el1, %[input]"
            :
            : [input] "r" (self),
        );
    }
};
