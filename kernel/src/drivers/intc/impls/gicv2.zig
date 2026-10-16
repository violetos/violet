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
const TrigIrq = intc.TrigIrq;

// --- drivers/intc/impls/gicv2.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.aarch64};
pub const discover_stage: ?drivers.Stage = .stage3;

var instance: Self = undefined;
var discovered: bool = false;

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    _ = stage;
    if (xsdt) |x| try xsdtDiscover(x);
    if (dt) |d| try dtDiscover(d);
}

inline fn xsdtDiscover(xsdt: *const acpi.Xsdt) !void {
    const madt = xsdt.find(acpi.Madt) orelse return;

    var gicd_phys: ?u64 = null;
    var gicc_phys: [GICV2_MAX_TARGET_PE]u64 = @splat(0);
    var gicc_count: u32 = 0;

    var it = madt.iterator();
    while (it.next()) |rec| {
        switch (rec) {
            .gicd => |g| {
                if (gicd_phys == null and (g.gic_version == 0 or g.gic_version == 2)) {
                    gicd_phys = g.physical_base_address;
                }
            },
            .gicc => |g| {
                if (gicc_count < GICV2_MAX_TARGET_PE) {
                    gicc_phys[gicc_count] = g.physical_base_address;
                    gicc_count += 1;
                }
            },
            else => {},
        }
    }

    const gicd_base = gicd_phys orelse return;
    if (gicc_count == 0) return;

    instance = .{ .gicd_base = try kernel.mem.virt.mmio(gicd_base, kernel.mem.paging.page_size) };

    var i: u32 = 0;
    while (i < gicc_count) : (i += 1) {
        instance.gicc_base[i] = try kernel.mem.virt.mmio(gicc_phys[i], kernel.mem.paging.page_size);
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

const GICD_CTLR: usize = 0x000;
const GICD_TYPER: usize = 0x004;
const GICD_ISENABLER: usize = 0x100;
const GICD_ICENABLER: usize = 0x180;
const GICD_ISPENDR: usize = 0x200;
const GICD_ICPENDR: usize = 0x280;
const GICD_ISACTIVER: usize = 0x300;
const GICD_ICACTIVER: usize = 0x380;
const GICD_IPRIORITYR: usize = 0x400;
const GICD_ITARGETSR: usize = 0x800;
/// 2 bits/interrupt; bit 1: 0 = level, 1 = edge. RO for SGIs.
const GICD_ICFGR: usize = 0xC00;
const GICD_SGIR: usize = 0xF00;

const GICC_CTLR: usize = 0x0000;
const GICC_PMR: usize = 0x0004;
const GICC_BPR: usize = 0x0008;
const GICC_IAR: usize = 0x000C;
const GICC_EOIR: usize = 0x0010;
const GICC_DIR: usize = 0x1000;

/// Architectural ceiling: ITARGETSR's CPU-targets field is 8 bits wide.
const GICV2_MAX_TARGET_PE: u32 = 8;
const GIC_SPURIOUS_INTID: u32 = 1023;
/// Only possible when Security Extensions are implemented.
const GIC_SECURE_HIDDEN_INTID: u32 = 1022;

const MIN_PPI_ID: u32 = 16;
const MIN_SPI_ID: u32 = 32;

const GicdCtlr = packed struct(u32) {
    enable: bool = false,
    _ignored: bool = false,
    _reserved: u30 = 0,
};

const GicdTyper = packed struct(u32) {
    it_lines_number: u5,
    cpu_number: u3,
    _reserved0: u2,
    security_extn: bool,
    lspi: u5,
    _reserved1: u16,
};

const GiccCtlr = packed struct(u32) {
    enable: bool = false,
    _ignored: bool = false,
    ack_ctl: bool = false,
    fiq_en: bool = false,
    cbpr: bool = false,
    fiq_byp_dis_grp0: bool = false,
    irq_byp_dis_grp0: bool = false,
    fiq_byp_dis_grp1: bool = false,
    irq_byp_dis_grp1: bool = false,
    eoi_mode: bool = false,
    _reserved: u22 = 0,
};

/// Format of GICC_IAR reads and of the value written back to GICC_EOIR /
/// GICC_DIR (spec §4.4.4/4.4.5 + GICC_DIR field description): cpu_id is
/// the SGI source's CPU interface id and must be echoed back verbatim.
const GiccIar = packed struct(u32) {
    interrupt_id: u10,
    cpu_id: u3,
    _reserved: u19 = 0,
};

const SgirTargetListFilter = enum(u2) {
    forward_to_list = 0,
    forward_to_all_but_self = 1,
    forward_to_self = 2,
    _reserved = 3,
};

const GicdSgir = packed struct(u32) {
    sgi_intid: u4,
    _reserved0: u11 = 0,
    nsatt: bool = false,
    cpu_target_list: u8,
    target_list_filter: SgirTargetListFilter,
    _reserved1: u6 = 0,
};

// --- //

const Self = @This();

gicd_base: usize,
gicc_base: [GICV2_MAX_TARGET_PE]usize = @splat(0),
max_intid: u32 = 0,
security_extensions: bool = false,
cpu_target: [GICV2_MAX_TARGET_PE]u8 = @splat(0),

inline fn gicdRead32(self: *const Self, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(self.gicd_base + offset);
    return ptr.*;
}

inline fn gicdWrite32(self: *const Self, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(self.gicd_base + offset);
    ptr.* = value;
}

inline fn giccRead32(self: *const Self, cpu_id: u32, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(self.gicc_base[cpu_id] + offset);
    return ptr.*;
}

inline fn giccWrite32(self: *const Self, cpu_id: u32, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(self.gicc_base[cpu_id] + offset);
    ptr.* = value;
}

inline fn currentCpuId() u32 {
    return @intCast(kernel.cpu.CpuContext.current().?.processor_id);
}

/// Byte-per-interrupt arrays (IPRIORITYR, ITARGETSR): 4 interrupts/register.
inline fn gicdReadByte(self: *const Self, base_offset: usize, id: u32) u8 {
    const word = self.gicdRead32(base_offset + (id / 4) * 4);
    const shift: u5 = @intCast((id % 4) * 8);
    return @truncate(word >> shift);
}

inline fn gicdWriteByte(self: *const Self, base_offset: usize, id: u32, value: u8) void {
    const reg_offset = base_offset + (id / 4) * 4;
    const shift: u5 = @intCast((id % 4) * 8);
    var word = self.gicdRead32(reg_offset);
    word &= ~(@as(u32, 0xFF) << shift);
    word |= @as(u32, value) << shift;
    self.gicdWrite32(reg_offset, word);
}

/// Bit-per-interrupt arrays: 32/register, all write-1-effects.
inline fn gicdSetBit(self: *const Self, base_offset: usize, id: u32) void {
    const reg_offset = base_offset + (id / 32) * 4;
    const shift: u5 = @intCast(id % 32);
    self.gicdWrite32(reg_offset, @as(u32, 1) << shift);
}

inline fn gicdGetBit(self: *const Self, base_offset: usize, id: u32) bool {
    const reg_offset = base_offset + (id / 32) * 4;
    const shift: u5 = @intCast(id % 32);
    return (self.gicdRead32(reg_offset) >> shift) & 1 != 0;
}

inline fn gicdGetCfgEdge(self: *const Self, id: u32) bool {
    const reg_offset = GICD_ICFGR + (id / 16) * 4;
    const shift: u5 = @intCast((id % 16) * 2);
    return (self.gicdRead32(reg_offset) >> (shift + 1)) & 1 != 0;
}

inline fn gicdSetCfgEdge(self: *const Self, id: u32, edge: bool) void {
    const reg_offset = GICD_ICFGR + (id / 16) * 4;
    const shift: u5 = @intCast((id % 16) * 2);
    var word = self.gicdRead32(reg_offset);
    const bit: u32 = @as(u32, 1) << (shift + 1);
    if (edge) word |= bit else word &= ~bit;
    self.gicdWrite32(reg_offset, word);
}

fn physicalMaskOf(self: *const Self, mask: u64) u8 {
    var out: u8 = 0;
    var i: u6 = 0;
    while (i < GICV2_MAX_TARGET_PE) : (i += 1) {
        if ((mask >> i) & 1 != 0) out |= self.cpu_target[i];
    }
    return out;
}

// --- //

fn distInit(self: *Self) void {
    const typer: GicdTyper = @bitCast(self.gicdRead32(GICD_TYPER));
    self.max_intid = @as(u32, typer.it_lines_number) * 32 + 31;
    self.security_extensions = typer.security_extn;

    self.gicdWrite32(GICD_CTLR, 0);

    var id: u32 = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 32) {
        const word_offset = ((id - MIN_SPI_ID) / 32) * 4;
        self.gicdWrite32(GICD_ICENABLER + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICPENDR + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICACTIVER + word_offset, 0xFFFF_FFFF);
    }

    id = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 1) {
        self.gicdWriteByte(GICD_IPRIORITYR, id, 0xA0); // conventional mid default
        self.gicdWriteByte(GICD_ITARGETSR, id, 0); // no PE brought up yet
        self.gicdSetCfgEdge(id, false); // level-sensitive default
    }

    var ctlr: GicdCtlr = .{};
    ctlr.enable = true;
    self.gicdWrite32(GICD_CTLR, @bitCast(ctlr));
}

// --- //

const vtable: intc.Domain.VTable = .{
    .init_local = &vInitLocal,
};

pub fn asIntc(self: *Self) intc.Domain {
    return .{
        .context = @ptrCast(self),
        .vtable = &vtable,
    };
}

fn vInitLocal(ctx: *anyopaque) callconv(basalt.system.call_conv) u64 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const cpu_id = currentCpuId();

    if (cpu_id >= GICV2_MAX_TARGET_PE) return 1;
    if (self.gicc_base[cpu_id] == 0) return 1;

    self.cpu_target[cpu_id] = self.gicdReadByte(GICD_ITARGETSR, 0);

    self.giccWrite32(cpu_id, GICC_PMR, 0xFF);
    self.giccWrite32(cpu_id, GICC_BPR, 0);

    var ctlr: GiccCtlr = .{};
    ctlr.enable = true;
    ctlr.eoi_mode = true; // split priority-drop/deactivate
    self.giccWrite32(cpu_id, GICC_CTLR, @bitCast(ctlr));

    return 0;
}
