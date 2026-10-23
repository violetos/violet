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

    instance = .{
        .gicd_base = try kernel.mem.virt.mmio(gicd_base, GICD_MMIO_SIZE),
    };

    var i: u32 = 0;
    while (i < gicc_count) : (i += 1) {
        if (i > 0 and gicc_phys[i] == gicc_phys[0]) {
            instance.gicc_base[i] = instance.gicc_base[0];
        } else {
            instance.gicc_base[i] = try kernel.mem.virt.mmio(gicc_phys[i], GICC_MMIO_SIZE);
        }
    }

    instance.distInit();

    try intc.registerRoot(instance.asIntc());

    discovered = true;
}

inline fn dtDiscover(dt: void) !void {
    if (discovered) return;
    _ = dt;
}

// --- Constants & Registers (ARM IHI 0048B.b) --- //

/// GICD register space is 4KB (0x000..0xFFF).
const GICD_MMIO_SIZE: usize = 0x1000;
/// GICC register space is 8KB (0x0000..0x1FFF) because GICC_DIR sits at 0x1000.
const GICC_MMIO_SIZE: usize = 0x2000;

const GICD_CTLR: usize = 0x000;
const GICD_TYPER: usize = 0x004;
const GICD_IIDR: usize = 0x008;
const GICD_IGROUPR: usize = 0x080;
const GICD_ISENABLER: usize = 0x100;
const GICD_ICENABLER: usize = 0x180;
const GICD_ISPENDR: usize = 0x200;
const GICD_ICPENDR: usize = 0x280;
const GICD_ISACTIVER: usize = 0x300;
const GICD_ICACTIVER: usize = 0x380;
const GICD_IPRIORITYR: usize = 0x400;
const GICD_ITARGETSR: usize = 0x800;
/// 2 bits/interrupt; bit 1: 0 = level-sensitive, 1 = edge-triggered. RO for SGIs.
const GICD_ICFGR: usize = 0xC00;
const GICD_SGIR: usize = 0xF00;
const GICD_CPENDSGIR: usize = 0xF10;
const GICD_SPENDSGIR: usize = 0xF20;

const GICC_CTLR: usize = 0x0000;
const GICC_PMR: usize = 0x0004;
const GICC_BPR: usize = 0x0008;
const GICC_IAR: usize = 0x000C;
const GICC_EOIR: usize = 0x0010;
const GICC_RPR: usize = 0x0014;
const GICC_HPPIR: usize = 0x0018;
const GICC_DIR: usize = 0x1000;

/// Architectural ceiling: ITARGETSR's CPU-targets field is 8 bits wide.
const GICV2_MAX_TARGET_PE: u32 = 8;

const MIN_SGI_ID: u32 = 0;
const MAX_SGI_ID: u32 = 15;
const MIN_PPI_ID: u32 = 16;
const MAX_PPI_ID: u32 = 31;
const MIN_SPI_ID: u32 = 32;
/// Interrupt IDs 1020..1023 are reserved for special purposes (spec §2.2.1).
const MAX_VALID_INTID: u32 = 1019;
const MAX_SPI_COUNT: usize = MAX_VALID_INTID - MIN_SPI_ID + 1; // 988

const GIC_SECURE_HIDDEN_INTID: u32 = 1022;
const GIC_SPURIOUS_INTID: u32 = 1023;

const DEFAULT_PRIORITY: u8 = 0xA0;

const GicdCtlr = packed struct(u32) {
    enable_grp0: bool = false,
    enable_grp1: bool = false,
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

/// Covers both the Non-Secure view and single-security-state view of GICC_CTLR:
/// bit 0 enables signaling to the PE, bit 9 enables split priority-drop/deactivate (EOImode).
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
/// GICC_DIR (spec §4.4.4, §4.4.5, §4.4.17): cpu_id is the SGI source's CPU
/// interface ID and must be echoed back verbatim.
const GiccIar = packed struct(u32) {
    interrupt_id: u10,
    cpu_id: u3,
    _reserved: u19 = 0,
};

const SgirTargetListFilter = enum(u2) {
    forward_to_list = 0b00,
    forward_to_all_but_self = 0b01,
    forward_to_self = 0b10,
    _reserved = 0b11,
};

const GicdSgir = packed struct(u32) {
    sgi_intid: u4,
    _reserved0: u11 = 0,
    nsatt: bool = false,
    cpu_target_list: u8 = 0,
    target_list_filter: SgirTargetListFilter,
    _reserved1: u6 = 0,
};

// --- //

const Self = @This();

gicd_base: usize,
gicc_base: [GICV2_MAX_TARGET_PE]usize = @splat(0),

max_intid: u32 = 0,
security_extensions: bool = false,

/// Maps logical OS processor_id -> 8-bit one-hot GIC target mask from ITARGETSR0.
cpu_target: [GICV2_MAX_TARGET_PE]u8 = @splat(0),

local_irqs: [GICV2_MAX_TARGET_PE * 32]?VirtIrq.Handle = @splat(null),
shared_irqs: [MAX_SPI_COUNT]?VirtIrq.Handle = @splat(null),
irqs_lock: RwLock = .{},

// --- Low-Level MMIO Helpers --- //

inline fn gicdRead32(self: *const Self, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(self.gicd_base + offset);
    return ptr.*;
}

inline fn gicdWrite32(self: *const Self, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(self.gicd_base + offset);
    ptr.* = value;
}

/// GICD_IPRIORITYRn, GICD_ITARGETSRn, GICD_CPENDSGIRn and GICD_SPENDSGIRn
/// natively support atomic 8-bit accesses in hardware (spec §4.1.4).
inline fn gicdReadByte(self: *const Self, base_offset: usize, index: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(self.gicd_base + base_offset + index);
    return ptr.*;
}

inline fn gicdWriteByte(self: *const Self, base_offset: usize, index: u32, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(self.gicd_base + base_offset + index);
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

/// Write-1-to-set / Write-1-to-clear bit arrays (ISENABLER, ICENABLER, ICPENDR, ICACTIVER).
inline fn gicdWriteBit(self: *const Self, base_offset: usize, id: u32) void {
    const reg_offset = base_offset + (id / 32) * 4;
    const shift: u5 = @intCast(id % 32);
    self.gicdWrite32(reg_offset, @as(u32, 1) << shift);
}

inline fn gicdReadBit(self: *const Self, base_offset: usize, id: u32) bool {
    const reg_offset = base_offset + (id / 32) * 4;
    const shift: u5 = @intCast(id % 32);
    return (self.gicdRead32(reg_offset) >> shift) & 1 != 0;
}

/// GICD_ICFGR is only word-accessible (spec §4.1.4): 16 interrupts/register, 2 bits/interrupt.
inline fn gicdSetCfgEdge(self: *const Self, id: u32, edge: bool) void {
    const reg_offset = GICD_ICFGR + (id / 16) * 4;
    const shift: u5 = @intCast((id % 16) * 2 + 1); // Bit [2n+1] selects level (0) vs edge (1)
    var word = self.gicdRead32(reg_offset);
    const bit: u32 = @as(u32, 1) << shift;
    if (edge) word |= bit else word &= ~bit;
    self.gicdWrite32(reg_offset, word);
}

fn physicalMaskOf(self: *const Self, logical_mask: u64) u8 {
    var out: u8 = 0;
    var i: u6 = 0;
    while (i < GICV2_MAX_TARGET_PE) : (i += 1) {
        if ((logical_mask >> i) & 1 != 0) {
            out |= self.cpu_target[i];
        }
    }
    return out;
}

// --- Hardware Initialization --- //

fn distInit(self: *Self) void {
    const typer: GicdTyper = @bitCast(self.gicdRead32(GICD_TYPER));
    const raw_max = (@as(u32, typer.it_lines_number) + 1) * 32 - 1;
    self.max_intid = @min(raw_max, MAX_VALID_INTID);
    self.security_extensions = typer.security_extn;

    // Disable distributor before configuring SPIs.
    self.gicdWrite32(GICD_CTLR, 0);

    // Disable, clear pending, and clear active state for all implemented SPIs (32..max_intid).
    var id: u32 = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 32) {
        const word_offset = (id / 32) * 4;
        self.gicdWrite32(GICD_ICENABLER + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICPENDR + word_offset, 0xFFFF_FFFF);
        self.gicdWrite32(GICD_ICACTIVER + word_offset, 0xFFFF_FFFF);
    }

    // Set default priority, clear targets, and default to level-sensitive for all SPIs.
    id = MIN_SPI_ID;
    while (id <= self.max_intid) : (id += 1) {
        self.gicdWriteByte(GICD_IPRIORITYR, id, DEFAULT_PRIORITY);
        self.gicdWriteByte(GICD_ITARGETSR, id, 0);
        self.gicdSetCfgEdge(id, false);
    }

    // Enable distributor (both Group 0 and Group 1 if applicable in current security state).
    self.gicdWrite32(GICD_CTLR, @bitCast(GicdCtlr{
        .enable_grp0 = true,
        .enable_grp1 = true,
    }));
    asm volatile ("dsb sy" ::: .{ .memory = true });
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

    if (cpu_id >= GICV2_MAX_TARGET_PE) return .bad_request;
    if (self.gicc_base[cpu_id] == 0) return .bad_request;

    // Discover this PE's hardware target mask from banked GICD_ITARGETSR0 (spec §4.3.12).
    // On uniprocessor implementations where ITARGETSR0 is RAZ/WI, fall back to (1 << cpu_id).
    const hw_mask = self.gicdReadByte(GICD_ITARGETSR, 0);
    self.cpu_target[cpu_id] = if (hw_mask != 0) hw_mask else (@as(u8, 1) << @intCast(cpu_id));

    // Clean up banked SGI (0..15) and PPI (16..31) state for this PE:
    // Disable all PPIs (SGIs 0..15 may be fixed-enabled in HW, clear their pending state via CPENDSGIR).
    self.gicdWrite32(GICD_ICENABLER, 0xFFFF_0000);
    self.gicdWrite32(GICD_ICPENDR, 0xFFFF_FFFF);
    self.gicdWrite32(GICD_ICACTIVER, 0xFFFF_FFFF);

    var sgi_word: usize = 0;
    while (sgi_word < 16) : (sgi_word += 4) {
        self.gicdWrite32(GICD_CPENDSGIR + sgi_word, 0xFFFF_FFFF);
    }

    var id: u32 = 0;
    while (id < MIN_SPI_ID) : (id += 1) {
        self.gicdWriteByte(GICD_IPRIORITYR, id, DEFAULT_PRIORITY);
    }

    // Configure CPU interface: unmask all priority levels (0xFF) and finest binary point (0).
    self.giccWrite32(cpu_id, GICC_PMR, 0xFF);
    self.giccWrite32(cpu_id, GICC_BPR, 0);

    // Enable CPU interface with Split Priority Drop / Deactivate (EOImode = 1).
    self.giccWrite32(cpu_id, GICC_CTLR, @bitCast(GiccCtlr{
        .enable = true,
        .eoi_mode = true,
    }));
    asm volatile ("dsb sy\nisb" ::: .{ .memory = true });

    return .success;
}

fn vDeinitGlobal(context: *anyopaque) callconv(basalt.system.call_conv) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.gicdWrite32(GICD_CTLR, 0);
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn vRegister(context: *anyopaque, request: intc.Domain.Request, virq: VirtIrq.Handle) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (request.hardware_irq > self.max_intid) {
        return .bad_request;
    }

    const hw_irq: u32 = @intCast(request.hardware_irq);
    const cpu_id = currentCpuId();

    const slot: *?VirtIrq.Handle = if (hw_irq < MIN_SPI_ID)
        &self.local_irqs[cpu_id * 32 + hw_irq]
    else
        &self.shared_irqs[hw_irq - MIN_SPI_ID];

    if (slot.* != null) {
        return .already_registered;
    }

    slot.* = virq;

    // For SPIs, route by default to the registering PE if no target mask was set yet.
    if (hw_irq >= MIN_SPI_ID and self.gicdReadByte(GICD_ITARGETSR, hw_irq) == 0) {
        self.gicdWriteByte(GICD_ITARGETSR, hw_irq, self.cpu_target[cpu_id]);
    }

    return .success;
}

fn vAcknowledge(context: *anyopaque) callconv(basalt.system.call_conv) intc.Domain.AckRes {
    const self: *Self = @ptrCast(@alignCast(context));
    const cpu_id = currentCpuId();

    const raw = self.giccRead32(cpu_id, GICC_IAR);
    const iar: GiccIar = @bitCast(raw);
    const irq_id: u32 = iar.interrupt_id;

    // IDs 1020..1023 are reserved/spurious (1022 = Secure hidden, 1023 = Spurious).
    if (irq_id > self.max_intid) {
        return .{ .code = .spurious };
    }

    const maybe_handle = if (irq_id < MIN_SPI_ID)
        self.local_irqs[cpu_id * 32 + irq_id]
    else
        self.shared_irqs[irq_id - MIN_SPI_ID];

    const handle = maybe_handle orelse {
        // Spurious/unregistered valid INTID: drop priority & deactivate immediately
        // so the CPU interface Running Priority does not lock up!
        self.giccWrite32(cpu_id, GICC_EOIR, raw);
        self.giccWrite32(cpu_id, GICC_DIR, raw);
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
    const iar: GiccIar = @bitCast(raw);
    if (iar.interrupt_id != hw_irq or iar._reserved != 0) return .bad_request;

    // Spec §4.4.5: Write the exact GICC_IAR value (including CPUID[12:10] for SGIs) to GICC_EOIR.
    self.giccWrite32(currentCpuId(), GICC_EOIR, raw);
    return .success;
}

fn vDeactivate(context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid or token > std.math.maxInt(u32)) return .bad_request;

    const raw: u32 = @truncate(token);
    const iar: GiccIar = @bitCast(raw);
    if (iar.interrupt_id != hw_irq or iar._reserved != 0) return .bad_request;

    // Spec §4.4.17: Write the exact GICC_IAR value (including CPUID[12:10] for SGIs) to GICC_DIR.
    self.giccWrite32(currentCpuId(), GICC_DIR, raw);
    return .success;
}

fn vSetEnabled(context: *anyopaque, hw_irq: u64, enabled: bool) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    const id: u32 = @intCast(hw_irq);

    self.gicdWriteBit(if (enabled) GICD_ISENABLER else GICD_ICENABLER, id);
    return .success;
}

fn vSetPriority(context: *anyopaque, hw_irq: u64, priority: u8) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    // Priority 0xFF is reserved for GICC_PMR idle threshold; clamp to 0xFE so the IRQ remains deliverable.
    const safe_prio: u8 = @min(priority, 0xFE);
    self.gicdWriteByte(GICD_IPRIORITYR, @intCast(hw_irq), safe_prio);

    return .success;
}

fn vSetTriggerMode(context: *anyopaque, hw_irq: u64, trigger_mode: VirtIrq.TriggerMode) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq > self.max_intid) return .bad_request;
    // Spec §4.3.13: SGIs (0..15) are permanently edge-triggered; ICFGR0 is read-only.
    if (hw_irq < MIN_PPI_ID) {
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

    // Note: For PPIs (16..31), ICFGR1 is often RO in hardware; writing is safe (WI).
    self.gicdSetCfgEdge(@intCast(hw_irq), edge);

    return .success;
}

fn vSetTarget(context: *anyopaque, hw_irq: u64, cpu_mask: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    // Spec §4.3.12: ITARGETSR0..7 (IDs 0..31) are read-only and hardwired to the local PE.
    if (hw_irq < MIN_SPI_ID or hw_irq > self.max_intid) return .bad_request;

    const phys_mask = self.physicalMaskOf(cpu_mask);
    if (phys_mask == 0) return .bad_request;

    self.gicdWriteByte(GICD_ITARGETSR, @intCast(hw_irq), phys_mask);
    return .success;
}

fn vSendIpi(context: *anyopaque, hw_irq: u64, target: intc.Domain.IpiTarget) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    // Spec §4.3.15: Only SGIs (0..15) can be generated via GICD_SGIR.
    if (hw_irq > MAX_SGI_ID) return .bad_request;

    const sgir: GicdSgir = switch (target.filter) {
        .self => .{
            .sgi_intid = @intCast(hw_irq),
            .target_list_filter = .forward_to_self,
        },
        .all_but_self => .{
            .sgi_intid = @intCast(hw_irq),
            .target_list_filter = .forward_to_all_but_self,
        },
        .mask => blk: {
            const phys_mask = self.physicalMaskOf(target.cpu_mask);
            if (phys_mask == 0) return .bad_request;
            break :blk .{
                .sgi_intid = @intCast(hw_irq),
                .cpu_target_list = phys_mask,
                .target_list_filter = .forward_to_list,
            };
        },
    };

    // Ensure all prior memory stores (e.g., IPI message queues) are visible to
    // other inner-shareable PEs before the SGI is dispatched by the distributor.
    asm volatile ("dsb ishst" ::: .{ .memory = true });
    self.gicdWrite32(GICD_SGIR, @bitCast(sgir));

    return .success;
}
