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
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const drivers = kernel.drivers;
const acpi = drivers.acpi;
const intc = drivers.intc;

const Domain = intc.Domain;
const VirtIrq = intc.VirtIrq;

const mem = kernel.mem;
const utils = mem.utils;
const RwLock = utils.RwLock;
const UnrolledList = utils.UnrolledList;

// --- drivers/intc/impls/gicv3.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.aarch64};
pub const discover_stage: ?drivers.Stage = .stage3;

var instance: Self = undefined;
var discovered: bool = false;

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    _ = stage;
    if (xsdt) |x| try xsdtDiscover(x);
    if (dt) |d| try dtDiscover(d);
}

inline fn xsdtDiscover(xsdt: *const acpi.Xsdt) !void {
    const madt = xsdt.find(acpi.Madt) orelse return;

    var gicd_phys: ?u64 = null;
    var gicc_count: usize = 0;

    var it = madt.iterator();
    while (it.next()) |rec| {
        switch (rec) {
            .gicd => |g| {
                if (gicd_phys == null and (g.gic_version == 3 or g.gic_version == 4)) {
                    gicd_phys = g.physical_base_address;
                }
            },
            .gicc => |g| {
                if (g.flags.enabled or g.flags.online_capable) {
                    gicc_count += 1;
                }
            },
            else => {},
        }
    }

    const gicd_base_phys = gicd_phys orelse return;

    instance = .{
        .gicd_base = try kernel.mem.virt.mmio(gicd_base_phys, GICD_MMIO_SIZE),
    };
    errdefer {
        instance.redists.deinit();
        instance.cpus.deinit();
    }

    var it2 = madt.iterator();
    while (it2.next()) |rec| {
        switch (rec) {
            .gicr => |r| {
                if (r.discovery_range_base_address != 0 and r.discovery_range_length >= GICR_RD_AND_SGI_SIZE) {
                    try instance.discoverGicrRange(r.discovery_range_base_address, r.discovery_range_length);
                }
            },
            .gicc => |g| {
                if ((g.flags.enabled or g.flags.online_capable) and g.gicr_base_address != 0) {
                    try instance.discoverSingleGicr(g.gicr_base_address);
                }
            },
            else => {},
        }
    }

    if (instance.redists.len == 0) {
        instance.redists.deinit();
        instance.cpus.deinit();
        return;
    }

    const cpu_slots = @max(gicc_count, instance.redists.len);
    var i: usize = 0;
    while (i < cpu_slots) : (i += 1) {
        const default_redist = instance.redists.get(i) orelse instance.redists.get(0).?;
        _ = try instance.cpus.append(.{
            .rd_base = default_redist.rd_base,
            .sgi_base = default_redist.sgi_base,
            .affinity = default_redist.affinity,
        });
    }

    instance.distInit();

    try intc.registerRoot(instance.asIntc());

    discovered = true;
}

inline fn dtDiscover(dt: void) !void {
    if (discovered) return;
    _ = dt;
}

// --- //

/// GICv3 Distributor register space is 64KB (0x0000..0xFFFF).
const GICD_MMIO_SIZE: usize = 0x10000;
/// Each Redistributor contains at least RD_base (64KB) + SGI_base (64KB) = 128KB.
const GICR_RD_AND_SGI_SIZE: usize = 0x20000;
/// When GICR_TYPER.VLPIS == 1 (GICv4), VLPI_base (64KB) + Reserved (64KB) follow = 256KB stride.
const GICR_V4_STRIDE: usize = 0x40000;
/// Offset from RD_base to the SGI/PPI frame (SGI_base).
const GICR_SGI_OFFSET: usize = 0x10000;

// Distributor (GICD) offsets
const GICD_CTLR: usize = 0x0000;
const GICD_TYPER: usize = 0x0004;
const GICD_IIDR: usize = 0x0008;
const GICD_IGROUPR: usize = 0x0080;
const GICD_ISENABLER: usize = 0x0100;
const GICD_ICENABLER: usize = 0x0180;
const GICD_ISPENDR: usize = 0x0200;
const GICD_ICPENDR: usize = 0x0280;
const GICD_ISACTIVER: usize = 0x0300;
const GICD_ICACTIVER: usize = 0x0380;
const GICD_IPRIORITYR: usize = 0x0400;
const GICD_ICFGR: usize = 0x0C00;
const GICD_IGRPMODR: usize = 0x0D00;
/// 64-bit routing register per SPI: GICD_IROUTER<n> sits at 0x6000 + 8 * n (for n >= 32).
const GICD_IROUTER: usize = 0x6000;

// Redistributor RD_base offsets (Frame 0: 0x00000..0x0FFFF)
const GICR_CTLR: usize = 0x0000;
const GICR_IIDR: usize = 0x0004;
const GICR_TYPER: usize = 0x0008;
const GICR_WAKER: usize = 0x0014;

// Redistributor SGI_base offsets (Frame 1: 0x10000..0x1FFFF)
const GICR_IGROUPR0: usize = 0x0080;
const GICR_ISENABLER0: usize = 0x0100;
const GICR_ICENABLER0: usize = 0x0180;
const GICR_ISPENDR0: usize = 0x0200;
const GICR_ICPENDR0: usize = 0x0280;
const GICR_ISACTIVER0: usize = 0x0300;
const GICR_ICACTIVER0: usize = 0x0380;
const GICR_IPRIORITYR: usize = 0x0400;
const GICR_ICFGR0: usize = 0x0C00;
const GICR_ICFGR1: usize = 0x0C04;
const GICR_IGRPMODR0: usize = 0x0D00;

// CPU Interface System Registers (AArch64 architectural encodings)
const ICC_PMR_EL1 = "S3_0_C4_C6_0";
const ICC_DIR_EL1 = "S3_0_C12_C11_1";
const ICC_RPR_EL1 = "S3_0_C12_C11_3";
const ICC_SGI1R_EL1 = "S3_0_C12_C11_5";
const ICC_IAR1_EL1 = "S3_0_C12_C12_0";
const ICC_EOIR1_EL1 = "S3_0_C12_C12_1";
const ICC_HPPIR1_EL1 = "S3_0_C12_C12_2";
const ICC_BPR1_EL1 = "S3_0_C12_C12_3";
const ICC_CTLR_EL1 = "S3_0_C12_C12_4";
const ICC_SRE_EL1 = "S3_0_C12_C12_5";
const ICC_IGRPEN1_EL1 = "S3_0_C12_C12_7";

const MIN_SGI_ID: u32 = 0;
const MAX_SGI_ID: u32 = 15;
const MIN_PPI_ID: u32 = 16;
const MAX_PPI_ID: u32 = 31;
const MIN_SPI_ID: u32 = 32;
/// Standard SPI range 32..1019 (IDs 1020..1023 are reserved/spurious).
const MAX_VALID_INTID: u32 = 1019;
const MAX_SPI_COUNT: usize = MAX_VALID_INTID - MIN_SPI_ID + 1; // 988

const DEFAULT_PRIORITY: u8 = 0xA0;
const RWP_SPIN_LIMIT: usize = 1_000_000;

const GicdCtlr = packed struct(u32) {
    enable_grp0_or_ns1: bool = false,
    enable_grp1ns_or_ns1a: bool = false,
    enable_grp1s: bool = false,
    _reserved0: u1 = 0,
    are_s_or_ns: bool = false,
    are_ns: bool = false,
    ds: bool = false,
    e1nwf: bool = false,
    _reserved1: u23 = 0,
    rwp: bool = false,
};

const GicdTyper = packed struct(u32) {
    it_lines_number: u5,
    cpu_number: u3,
    espi: bool,
    _reserved0: u1,
    security_extn: bool,
    num_lpis: u5,
    mbis: bool,
    lpis: bool,
    dvis: bool,
    id_bits: u5,
    a3v: bool,
    no_1n: bool,
    rss: bool,
    espi_range: u5,
};

const GicrCtlr = packed struct(u32) {
    enable_lpis: bool = false,
    ces: bool = false,
    ir: bool = false,
    rwp: bool = false,
    _reserved0: u20 = 0,
    dpg0: bool = false,
    dpg1ns: bool = false,
    dpg1s: bool = false,
    _reserved1: u4 = 0,
    uwp: bool = false,
};

const GicrTyper = packed struct(u64) {
    plpis: bool,
    vlpis: bool,
    dirty: bool,
    direct_lpi: bool,
    last: bool,
    dpgs: bool,
    mpam: bool,
    rvpeid: bool,
    processor_number: u16,
    common_lpi_aff: u2,
    vsgi: bool,
    ppi_num: u5,
    affinity_value: u32,
};

const GicrWaker = packed struct(u32) {
    impl_def0: bool = false,
    processor_sleep: bool = false,
    children_asleep: bool = false,
    _reserved: u28 = 0,
    impl_def31: bool = false,
};

const GicdIrouter = packed struct(u64) {
    aff0: u8 = 0,
    aff1: u8 = 0,
    aff2: u8 = 0,
    _reserved0: u7 = 0,
    /// false (0) = route to the specific PE identified by Aff3.Aff2.Aff1.Aff0.
    /// true  (1) = route to any participating PE (1-of-N).
    irm: bool = false,
    aff3: u8 = 0,
    _reserved1: u24 = 0,
};

const IccSreEl1 = packed struct(u64) {
    sre: bool = false,
    dfb: bool = false,
    dib: bool = false,
    _reserved: u61 = 0,
};

const IccCtlrEl1 = packed struct(u64) {
    cbpr: bool = false,
    eoi_mode: bool = false,
    _reserved0: u4 = 0,
    pmhe: bool = false,
    _reserved1: u1 = 0,
    pri_bits: u3 = 0,
    id_bits: u3 = 0,
    seis: bool = false,
    a3v: bool = false,
    _reserved2: u2 = 0,
    rss: bool = false,
    ext_range: bool = false,
    _reserved3: u44 = 0,
};

const IccIar1El1 = packed struct(u32) {
    intid: u24,
    _reserved: u8 = 0,
};

const IccSgi1rEl1 = packed struct(u64) {
    target_list: u16 = 0,
    aff1: u8 = 0,
    intid: u4 = 0,
    _reserved0: u4 = 0,
    aff2: u8 = 0,
    /// false (0) = route to PEs specified by Aff3.Aff2.Aff1.RS.TargetList.
    /// true  (1) = route to all PEs in the system except self.
    irm: bool = false,
    _reserved1: u3 = 0,
    rs: u4 = 0,
    aff3: u8 = 0,
    _reserved2: u8 = 0,
};

const Affinity = packed struct(u32) {
    aff0: u8 = 0,
    aff1: u8 = 0,
    aff2: u8 = 0,
    aff3: u8 = 0,

    pub inline fn fromBits(bits: u32) Affinity {
        return @bitCast(bits);
    }

    pub inline fn toBits(self: Affinity) u32 {
        return @bitCast(self);
    }

    pub inline fn fromMpidr(mpidr: u64) Affinity {
        return .{
            .aff0 = @truncate(mpidr),
            .aff1 = @truncate(mpidr >> 8),
            .aff2 = @truncate(mpidr >> 16),
            .aff3 = @truncate(mpidr >> 32),
        };
    }

    pub inline fn toIrouter(self: Affinity, one_of_n: bool) GicdIrouter {
        return .{
            .aff0 = self.aff0,
            .aff1 = self.aff1,
            .aff2 = self.aff2,
            .irm = one_of_n,
            .aff3 = self.aff3,
        };
    }

    pub inline fn rs(self: Affinity) u4 {
        return @intCast(self.aff0 / 16);
    }

    pub inline fn targetBit(self: Affinity) u16 {
        return @as(u16, 1) << @intCast(self.aff0 % 16);
    }

    pub inline fn clusterKey(self: Affinity) u32 {
        return (@as(u32, self.aff3) << 24) |
            (@as(u32, self.aff2) << 16) |
            (@as(u32, self.aff1) << 8) |
            @as(u32, self.rs());
    }
};

const RedistFrame = struct {
    rd_base: usize,
    sgi_base: usize,
    affinity: Affinity,
    processor_number: u16,
};

const CpuState = struct {
    rd_base: usize = 0,
    sgi_base: usize = 0,
    affinity: Affinity = .{},
    online: bool = false,
    local_irqs: [32]?VirtIrq.Handle = @splat(null),
};

comptime {
    std.debug.assert(@sizeOf(RedistFrame) <= 1024);
    std.debug.assert(@sizeOf(CpuState) <= 1024);
}

// --- //

const Self = @This();
const RedistList = UnrolledList(RedistFrame, null);
const CpuList = UnrolledList(CpuState, null);

gicd_base: usize,

max_intid: u32 = 0,
security_extensions: bool = false,
no_1n: bool = true,
rss_supported: bool = false,

redists: RedistList = .{},
cpus: CpuList = .{},

shared_irqs: [MAX_SPI_COUNT]?VirtIrq.Handle = @splat(null),
irqs_lock: RwLock = .{},

// --- //

inline fn mmioRead32(base: usize, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

inline fn mmioWrite32(base: usize, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
}

inline fn mmioRead64(base: usize, offset: usize) u64 {
    const ptr: *volatile u64 = @ptrFromInt(base + offset);
    return ptr.*;
}

inline fn mmioWrite64(base: usize, offset: usize, value: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(base + offset);
    ptr.* = value;
}

inline fn mmioReadByte(base: usize, base_offset: usize, index: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(base + base_offset + index);
    return ptr.*;
}

inline fn mmioWriteByte(base: usize, base_offset: usize, index: u32, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(base + base_offset + index);
    ptr.* = value;
}

inline fn gicdRead32(self: *const Self, offset: usize) u32 {
    return mmioRead32(self.gicd_base, offset);
}

inline fn gicdWrite32(self: *const Self, offset: usize, value: u32) void {
    mmioWrite32(self.gicd_base, offset, value);
}

inline fn gicdRead64(self: *const Self, offset: usize) u64 {
    return mmioRead64(self.gicd_base, offset);
}

inline fn gicdWrite64(self: *const Self, offset: usize, value: u64) void {
    mmioWrite64(self.gicd_base, offset, value);
}

inline fn gicdWriteByte(self: *const Self, base_offset: usize, index: u32, value: u8) void {
    mmioWriteByte(self.gicd_base, base_offset, index, value);
}

inline fn gicdWriteBit(self: *const Self, base_offset: usize, id: u32) void {
    const reg_offset = base_offset + (id / 32) * 4;
    const shift: u5 = @intCast(id % 32);
    self.gicdWrite32(reg_offset, @as(u32, 1) << shift);
}

inline fn setCfgEdgeAt(base: usize, id: u32, edge: bool) void {
    const reg_offset = (id / 16) * 4;
    const shift: u5 = @intCast((id % 16) * 2 + 1);
    var word = mmioRead32(base, reg_offset);
    const bit: u32 = @as(u32, 1) << shift;
    if (edge) word |= bit else word &= ~bit;
    mmioWrite32(base, reg_offset, word);
}

inline fn sysRegRead(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %[ret], " ++ reg
        : [ret] "=r" (-> u64),
    );
}

inline fn sysRegWrite(comptime reg: []const u8, val: u64) void {
    asm volatile ("msr " ++ reg ++ ", %[val]"
        :
        : [val] "r" (val),
        : .{ .memory = true });
}

inline fn readMpidr() u64 {
    return asm volatile ("mrs %[ret], mpidr_el1"
        : [ret] "=r" (-> u64),
    );
}

inline fn currentCpuId() u32 {
    return @intCast(kernel.cpu.CpuContext.current().?.processor_id);
}

inline fn gicdWaitRwp(self: *const Self) void {
    var spins: usize = 0;
    while (spins < RWP_SPIN_LIMIT) : (spins += 1) {
        const ctlr: GicdCtlr = @bitCast(self.gicdRead32(GICD_CTLR));
        if (!ctlr.rwp) return;
        std.atomic.spinLoopHint();
    }
}

inline fn gicrWaitRwp(rd_base: usize) void {
    var spins: usize = 0;
    while (spins < RWP_SPIN_LIMIT) : (spins += 1) {
        const ctlr: GicrCtlr = @bitCast(mmioRead32(rd_base, GICR_CTLR));
        if (!ctlr.rwp) return;
        std.atomic.spinLoopHint();
    }
}

// --- //

fn discoverGicrRange(self: *Self, base_phys: u64, length: u32) !void {
    const range_virt = try kernel.mem.virt.mmio(base_phys, length);

    var offset: usize = 0;
    while (offset + GICR_RD_AND_SGI_SIZE <= length) {
        const frame_virt = range_virt + offset;
        const typer: GicrTyper = @bitCast(mmioRead64(frame_virt, GICR_TYPER));
        const aff = Affinity.fromBits(typer.affinity_value);

        if (!self.hasRedistForAffinity(aff)) {
            _ = try self.redists.append(.{
                .rd_base = frame_virt,
                .sgi_base = frame_virt + GICR_SGI_OFFSET,
                .affinity = aff,
                .processor_number = typer.processor_number,
            });
        }

        if (typer.last) break;

        const stride: usize = if (typer.vlpis) GICR_V4_STRIDE else GICR_RD_AND_SGI_SIZE;
        offset += stride;
    }
}

fn discoverSingleGicr(self: *Self, gicr_phys: u64) !void {
    const frame_virt = try kernel.mem.virt.mmio(gicr_phys, GICR_RD_AND_SGI_SIZE);
    const typer: GicrTyper = @bitCast(mmioRead64(frame_virt, GICR_TYPER));
    const aff = Affinity.fromBits(typer.affinity_value);

    if (!self.hasRedistForAffinity(aff)) {
        _ = try self.redists.append(.{
            .rd_base = frame_virt,
            .sgi_base = frame_virt + GICR_SGI_OFFSET,
            .affinity = aff,
            .processor_number = typer.processor_number,
        });
    }
}

fn hasRedistForAffinity(self: *Self, aff: Affinity) bool {
    var it = self.redists.iterator();
    while (it.next()) |frame| {
        if (frame.affinity.toBits() == aff.toBits()) return true;
    }
    return false;
}

fn findRedistByAffinity(self: *Self, aff: Affinity, fallback_idx: u32) ?RedistFrame {
    var it = self.redists.iterator();
    while (it.next()) |frame| {
        if (frame.affinity.toBits() == aff.toBits()) return frame.*;
    }
    return self.redists.get(fallback_idx);
}

fn ensureCpuSlot(self: *Self, cpu_id: u32) ?*CpuState {
    if (self.cpus.getPtr(cpu_id)) |slot| return slot;

    const saved = self.irqs_lock.acquire(.write, 0);
    defer self.irqs_lock.release(.write, saved);

    while (self.cpus.len <= cpu_id) {
        const default_redist = self.redists.get(self.cpus.len) orelse self.redists.get(0) orelse return null;
        _ = self.cpus.append(.{
            .rd_base = default_redist.rd_base,
            .sgi_base = default_redist.sgi_base,
            .affinity = default_redist.affinity,
        }) catch return null;
    }

    return self.cpus.getPtr(cpu_id);
}

// --- //

fn distInit(self: *Self) void {
    const typer: GicdTyper = @bitCast(self.gicdRead32(GICD_TYPER));
    const raw_max = (@as(u32, typer.it_lines_number) + 1) * 32 - 1;
    self.max_intid = @min(raw_max, MAX_VALID_INTID);
    self.security_extensions = typer.security_extn;
    self.no_1n = typer.no_1n;
    self.rss_supported = typer.rss;

    self.gicdWrite32(GICD_CTLR, 0);
    self.gicdWaitRwp();

    self.gicdWrite32(GICD_CTLR, @bitCast(GicdCtlr{
        .are_s_or_ns = true,
        .are_ns = true,
    }));
    self.gicdWaitRwp();

    const default_aff: Affinity = if (self.redists.get(0)) |r0| r0.affinity else .{};
    const default_route: u64 = @bitCast(default_aff.toIrouter(false));

    var id: u32 = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 32) {
        const word_offset = (id / 32) * 4;
        self.gicdWrite32(GICD_ICENABLER + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICPENDR + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICACTIVER + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_IGROUPR + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_IGRPMODR + word_offset, 0x0000_0000);
    }
    self.gicdWaitRwp();

    id = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 1) {
        self.gicdWriteByte(GICD_IPRIORITYR, id, DEFAULT_PRIORITY);
        setCfgEdgeAt(self.gicd_base + GICD_ICFGR, id, false);
        self.gicdWrite64(GICD_IROUTER + @as(usize, id) * 8, default_route);
    }

    self.gicdWrite32(GICD_CTLR, @bitCast(GicdCtlr{
        .enable_grp0_or_ns1 = true,
        .enable_grp1ns_or_ns1a = true,
        .are_s_or_ns = true,
        .are_ns = true,
    }));
    self.gicdWaitRwp();
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn wakeRedistributor(rd_base: usize) intc.Domain.ResultCode {
    var waker: GicrWaker = @bitCast(mmioRead32(rd_base, GICR_WAKER));
    if (waker.processor_sleep) {
        waker.processor_sleep = false;
        mmioWrite32(rd_base, GICR_WAKER, @bitCast(waker));
    }

    var spins: usize = 0;
    while (spins < RWP_SPIN_LIMIT) : (spins += 1) {
        waker = @bitCast(mmioRead32(rd_base, GICR_WAKER));
        if (!waker.children_asleep) return .success;
        std.atomic.spinLoopHint();
    }

    return .bad_request;
}

// --- //

const vtable: intc.Domain.VTable = .{
    .init_local = &vInitLocal,
    .deinit_global = &vDeinitGlobal,

    .register = &vRegister,

    .acknowledge = &vAcknowledge,
    .priority_drop = &vPriorityDrop,
    .deactivate = &vDeactivate,

    .set_enabled = &vSetEnabled,
    .set_priority = &vSetPriority,
    .set_trigger_mode = &vSetTriggerMode,
    .set_target = &vSetTarget,

    .send_ipi = &vSendIpi,
};

pub fn asIntc(self: *Self) intc.Domain {
    return .{
        .parent = null,
        .context = @ptrCast(self),
        .vtable = &vtable,
    };
}

fn vInitLocal(context: *anyopaque) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));
    const cpu_id = currentCpuId();

    const my_aff = Affinity.fromMpidr(readMpidr());
    const redist = self.findRedistByAffinity(my_aff, cpu_id) orelse return .bad_request;
    const cpu_state = self.ensureCpuSlot(cpu_id) orelse return .bad_request;

    cpu_state.rd_base = redist.rd_base;
    cpu_state.sgi_base = redist.sgi_base;
    cpu_state.affinity = my_aff;

    const wake_res = wakeRedistributor(redist.rd_base);
    if (wake_res != .success) return wake_res;

    mmioWrite32(redist.sgi_base, GICR_IGROUPR0, 0xFFFF_FFFF);
    mmioWrite32(redist.sgi_base, GICR_IGRPMODR0, 0x0000_0000);

    mmioWrite32(redist.sgi_base, GICR_ICENABLER0, 0xFFFF_0000);
    mmioWrite32(redist.sgi_base, GICR_ISENABLER0, 0x0000_FFFF);
    gicrWaitRwp(redist.rd_base);

    mmioWrite32(redist.sgi_base, GICR_ICPENDR0, 0xFFFF_FFFF);
    mmioWrite32(redist.sgi_base, GICR_ICACTIVER0, 0xFFFF_FFFF);

    var id: u32 = 0;
    while (id < MIN_SPI_ID) : (id += 1) {
        mmioWriteByte(redist.sgi_base, GICR_IPRIORITYR, id, DEFAULT_PRIORITY);
    }

    var sre: IccSreEl1 = @bitCast(sysRegRead(ICC_SRE_EL1));
    sre.sre = true;
    sre.dfb = true;
    sre.dib = true;
    sysRegWrite(ICC_SRE_EL1, @bitCast(sre));
    asm volatile ("isb" ::: .{ .memory = true });

    const verify_sre: IccSreEl1 = @bitCast(sysRegRead(ICC_SRE_EL1));
    if (!verify_sre.sre) return .bad_request;

    sysRegWrite(ICC_PMR_EL1, 0xFF);
    sysRegWrite(ICC_BPR1_EL1, 0);

    var icc_ctlr: IccCtlrEl1 = @bitCast(sysRegRead(ICC_CTLR_EL1));
    icc_ctlr.cbpr = false;
    icc_ctlr.eoi_mode = true;
    sysRegWrite(ICC_CTLR_EL1, @bitCast(icc_ctlr));

    sysRegWrite(ICC_IGRPEN1_EL1, 1);
    asm volatile ("dsb sy\nisb" ::: .{ .memory = true });

    @atomicStore(bool, &cpu_state.online, true, .release);

    return .success;
}

fn vDeinitGlobal(context: *anyopaque) callconv(basalt.system.call_conv) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.gicdWrite32(GICD_CTLR, 0);
    self.gicdWaitRwp();
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn vRegister(context: *anyopaque, request: intc.Domain.Request, virq: VirtIrq.Handle) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (request.hardware_irq > self.max_intid) {
        return .bad_request;
    }

    const hw_irq: u32 = @intCast(request.hardware_irq);
    const cpu_id = currentCpuId();
    const cpu_state = self.cpus.getPtr(cpu_id) orelse return .bad_request;

    const saved = self.irqs_lock.acquire(.write, 0);
    defer self.irqs_lock.release(.write, saved);

    const slot: *?VirtIrq.Handle = if (hw_irq < MIN_SPI_ID)
        &cpu_state.local_irqs[hw_irq]
    else
        &self.shared_irqs[hw_irq - MIN_SPI_ID];

    if (slot.* != null) {
        return .already_registered;
    }

    slot.* = virq;

    if (hw_irq >= MIN_SPI_ID) {
        const route: u64 = @bitCast(cpu_state.affinity.toIrouter(false));
        self.gicdWrite64(GICD_IROUTER + @as(usize, hw_irq) * 8, route);
    }

    return .success;
}

fn vAcknowledge(context: *anyopaque) callconv(basalt.system.call_conv) intc.Domain.AckRes {
    const self: *Self = @ptrCast(@alignCast(context));
    const cpu_id = currentCpuId();

    const raw64 = sysRegRead(ICC_IAR1_EL1);
    asm volatile ("isb" ::: .{ .memory = true });

    const raw: u32 = @truncate(raw64);
    const iar: IccIar1El1 = @bitCast(raw);
    const irq_id: u32 = iar.intid;

    if (irq_id > self.max_intid) {
        return .{ .code = .spurious };
    }

    const maybe_handle: ?VirtIrq.Handle = if (irq_id < MIN_SPI_ID) blk: {
        const cpu_state = self.cpus.getPtr(cpu_id) orelse break :blk null;
        break :blk cpu_state.local_irqs[irq_id];
    } else self.shared_irqs[irq_id - MIN_SPI_ID];

    const handle = maybe_handle orelse {
        sysRegWrite(ICC_EOIR1_EL1, raw);
        sysRegWrite(ICC_DIR_EL1, raw);
        asm volatile ("isb" ::: .{ .memory = true });
        return .{ .code = .unregistered };
    };

    return .{
        .code = .success,
        .virtirq = handle,
        .token = raw,
    };
}

fn vPriorityDrop(context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid or token > std.math.maxInt(u32)) return .bad_request;

    const raw: u32 = @truncate(token);
    const iar: IccIar1El1 = @bitCast(raw);
    if (iar.intid != hw_irq or iar._reserved != 0) return .bad_request;

    sysRegWrite(ICC_EOIR1_EL1, raw);
    asm volatile ("isb" ::: .{ .memory = true });
    return .success;
}

fn vDeactivate(context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid or token > std.math.maxInt(u32)) return .bad_request;

    const raw: u32 = @truncate(token);
    const iar: IccIar1El1 = @bitCast(raw);
    if (iar.intid != hw_irq or iar._reserved != 0) return .bad_request;

    sysRegWrite(ICC_DIR_EL1, raw);
    asm volatile ("isb" ::: .{ .memory = true });
    return .success;
}

fn vSetEnabled(context: *anyopaque, hw_irq: u64, enabled: bool) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    const id: u32 = @intCast(hw_irq);

    if (id < MIN_SPI_ID) {
        const cpu_state = self.cpus.getPtr(currentCpuId()) orelse return .bad_request;
        const reg_offset = if (enabled) GICR_ISENABLER0 else GICR_ICENABLER0;
        const shift: u5 = @intCast(id);
        mmioWrite32(cpu_state.sgi_base, reg_offset, @as(u32, 1) << shift);
        if (!enabled) gicrWaitRwp(cpu_state.rd_base);
    } else {
        self.gicdWriteBit(if (enabled) GICD_ISENABLER else GICD_ICENABLER, id);
        if (!enabled) self.gicdWaitRwp();
    }

    return .success;
}

fn vSetPriority(context: *anyopaque, hw_irq: u64, priority: u8) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    const id: u32 = @intCast(hw_irq);
    const safe_prio: u8 = @min(priority, 0xFE);

    if (id < MIN_SPI_ID) {
        const cpu_state = self.cpus.getPtr(currentCpuId()) orelse return .bad_request;
        mmioWriteByte(cpu_state.sgi_base, GICR_IPRIORITYR, id, safe_prio);
    } else {
        self.gicdWriteByte(GICD_IPRIORITYR, id, safe_prio);
    }

    return .success;
}

fn vSetTriggerMode(context: *anyopaque, hw_irq: u64, trigger_mode: VirtIrq.TriggerMode) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    const id: u32 = @intCast(hw_irq);

    if (id < MIN_PPI_ID) {
        return switch (trigger_mode) {
            .edge_rising, .edge_falling => .success,
            else => .bad_request,
        };
    }

    const edge = switch (trigger_mode) {
        .edge_rising, .edge_falling => true,
        .level_high, .level_low => false,
        .message => return .bad_request,
    };

    if (id < MIN_SPI_ID) {
        const cpu_state = self.cpus.getPtr(currentCpuId()) orelse return .bad_request;
        setCfgEdgeAt(cpu_state.sgi_base + GICR_ICFGR0, id, edge);
    } else {
        setCfgEdgeAt(self.gicd_base + GICD_ICFGR, id, edge);
    }

    return .success;
}

fn vSetTarget(context: *anyopaque, hw_irq: u64, cpu_mask: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq < MIN_SPI_ID or hw_irq > self.max_intid or cpu_mask == 0) {
        return .bad_request;
    }

    var mask = cpu_mask;
    var first_aff: ?Affinity = null;
    var valid_targets: usize = 0;

    while (mask != 0) {
        const cpu_idx: u6 = @intCast(@ctz(mask));
        mask &= ~(@as(u64, 1) << cpu_idx);

        if (self.cpus.getPtr(cpu_idx)) |cpu_state| {
            if (first_aff == null) first_aff = cpu_state.affinity;
            valid_targets += 1;
        }
    }

    const target_aff = first_aff orelse return .bad_request;
    const use_1n = (valid_targets > 1) and !self.no_1n;
    const route: u64 = @bitCast(target_aff.toIrouter(use_1n));

    self.gicdWrite64(GICD_IROUTER + @as(usize, @intCast(hw_irq)) * 8, route);
    return .success;
}

fn vSendIpi(context: *anyopaque, hw_irq: u64, target: intc.Domain.IpiTarget) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > MAX_SGI_ID) return .bad_request;
    const sgi_id: u4 = @intCast(hw_irq);

    asm volatile ("dsb ishst" ::: .{ .memory = true });

    switch (target.filter) {
        .self => {
            const my_aff = if (self.cpus.getPtr(currentCpuId())) |c|
                c.affinity
            else
                Affinity.fromMpidr(readMpidr());

            if (my_aff.rs() != 0 and !self.rss_supported) return .bad_request;

            const sgi1r: IccSgi1rEl1 = .{
                .target_list = my_aff.targetBit(),
                .aff1 = my_aff.aff1,
                .intid = sgi_id,
                .aff2 = my_aff.aff2,
                .irm = false,
                .rs = my_aff.rs(),
                .aff3 = my_aff.aff3,
            };
            sysRegWrite(ICC_SGI1R_EL1, @bitCast(sgi1r));
        },
        .all_but_self => {
            const sgi1r: IccSgi1rEl1 = .{
                .intid = sgi_id,
                .irm = true,
            };
            sysRegWrite(ICC_SGI1R_EL1, @bitCast(sgi1r));
        },
        .mask => {
            var remaining = target.cpu_mask;
            var sent_any = false;

            while (remaining != 0) {
                const lead_idx: u6 = @intCast(@ctz(remaining));
                const lead_bit = @as(u64, 1) << lead_idx;
                remaining &= ~lead_bit;

                const lead_cpu = self.cpus.getPtr(lead_idx) orelse continue;
                const lead_aff = lead_cpu.affinity;
                if (lead_aff.rs() != 0 and !self.rss_supported) continue;

                const cluster_key = lead_aff.clusterKey();
                var target_list: u16 = lead_aff.targetBit();

                var scan = remaining;
                while (scan != 0) {
                    const idx: u6 = @intCast(@ctz(scan));
                    const bit = @as(u64, 1) << idx;
                    scan &= ~bit;

                    if (self.cpus.getPtr(idx)) |peer_cpu| {
                        const peer_aff = peer_cpu.affinity;
                        if (peer_aff.clusterKey() == cluster_key) {
                            target_list |= peer_aff.targetBit();
                            remaining &= ~bit;
                        }
                    }
                }

                const sgi1r: IccSgi1rEl1 = .{
                    .target_list = target_list,
                    .aff1 = lead_aff.aff1,
                    .intid = sgi_id,
                    .aff2 = lead_aff.aff2,
                    .irm = false,
                    .rs = lead_aff.rs(),
                    .aff3 = lead_aff.aff3,
                };
                sysRegWrite(ICC_SGI1R_EL1, @bitCast(sgi1r));
                sent_any = true;
            }

            if (!sent_any) return .bad_request;
        },
    }

    asm volatile ("isb" ::: .{ .memory = true });
    return .success;
}
