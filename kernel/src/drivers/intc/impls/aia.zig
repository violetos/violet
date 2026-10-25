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

// --- drivers/intc/impls/aia.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.riscv64};
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

    instance = .{};
    errdefer instance.cpus.deinit();

    var min_imsic_phys: u64 = std.math.maxInt(u64);
    var aplic_rec: ?*const acpi.Madt.RiscvAplic = null;

    var it = madt.iterator();
    while (it.next()) |rec| {
        switch (rec) {
            .riscv_imsic => |im| {
                if (im.num_ids > 0) {
                    instance.imsic_num_ids = @min(@as(u32, im.num_ids), MAX_IMSIC_ID);
                }
                instance.hart_index_bits = @truncate(im.hart_index_bits);
                instance.group_index_bits = @truncate(im.group_index_bits);
                instance.group_index_shift = @truncate(im.group_index_shift);
            },
            .riscv_aplic => |ap| {
                if (aplic_rec == null and ap.physical_base_address != 0) {
                    aplic_rec = ap;
                }
            },
            .riscv_intc => |r| {
                if (!r.flags.enabled and !r.flags.online_capable) continue;

                var imsic_virt: usize = 0;
                if (r.imsic_base_address != 0) {
                    const imsic_len = @max(@as(usize, r.imsic_size), IMSIC_FILE_SIZE);
                    imsic_virt = try kernel.mem.virt.mmio(r.imsic_base_address, imsic_len);
                    instance.has_imsic = true;
                    min_imsic_phys = @min(min_imsic_phys, r.imsic_base_address);
                }

                _ = try instance.cpus.append(.{
                    .hart_id = r.hart_id,
                    .imsic_phys = r.imsic_base_address,
                    .imsic_base = imsic_virt,
                    .idc_index = @truncate(r.ext_intc_id),
                });
            },
            else => {},
        }
    }

    if (aplic_rec) |ap| {
        const aplic_len = @max(@as(usize, ap.size), APLIC_MIN_MMIO_SIZE);
        instance.aplic_base = try kernel.mem.virt.mmio(ap.physical_base_address, aplic_len);
        instance.max_source_id = @min(@as(u32, ap.num_sources), MAX_APLIC_SOURCES);
        instance.num_idc = ap.num_idc;
    }

    if (!instance.has_imsic and instance.aplic_base == 0) {
        instance.cpus.deinit();
        return;
    }

    if (instance.has_imsic and min_imsic_phys != std.math.maxInt(u64)) {
        instance.imsic_base_phys = min_imsic_phys;

        var cpu_it = instance.cpus.iterator();
        while (cpu_it.next()) |cpu| {
            if (cpu.imsic_phys != 0) {
                cpu.msi_hart_index = instance.computeMsiHartIndex(cpu.imsic_phys);
            }
        }
    }

    if (instance.aplic_base != 0) {
        instance.aplicInit();
    }

    try intc.registerRoot(instance.asIntc());

    discovered = true;
}

inline fn dtDiscover(dt: void) !void {
    if (discovered) return;
    _ = dt;
}

// --- //

const IMSIC_FILE_SIZE: usize = 0x1000;
const APLIC_MIN_MMIO_SIZE: usize = 0x4000;
const APLIC_DEFAULT_MMIO_SIZE: usize = 0x8000;

/// Offset in each IMSIC interrupt file page for Little-Endian MSI writes.
const IMSIC_SETEIPNUM_LE: usize = 0x0000;

/// S-mode AIA CSR encodings (numeric to avoid requiring explicit +ssaia target flags).
const CSR_SIE = "0x104";
const CSR_SISELECT = "0x150";
const CSR_SIREG = "0x151";
const CSR_STOPEI = "0x15c";

/// Supervisor External Interrupt Enable bit in `sie` (bit 9).
const SIE_SEIE: u64 = 1 << 9;

/// IMSIC indirect register selectors (via `siselect` / `sireg`).
const IMSIC_EIDELIVERY: u64 = 0x70;
const IMSIC_EITHRESHOLD: u64 = 0x72;
const IMSIC_EIP0: u64 = 0x80;
const IMSIC_EIE0: u64 = 0xC0;

/// IPIs use logical IDs 0..15 and map to IMSIC EIIDs 1..16.
const MAX_IPI_ID: u32 = 15;
const IPI_COUNT: usize = 16;

/// Wired APLIC interrupts (1..1023) map to IMSIC EIIDs (APLIC_EIID_BASE + source_id).
const APLIC_EIID_BASE: u32 = 16;
const MAX_APLIC_SOURCES: u32 = 1023;
const MAX_IMSIC_ID: u32 = 2047;
const DEFAULT_PRIORITY: u8 = 0xA0;

// APLIC MMIO register offsets (spec §4.5)
const APLIC_DOMAINCFG: usize = 0x0000;
const APLIC_SOURCECFG_BASE: usize = 0x0000; // + 4 * i (i = 1..1023)
const APLIC_SMSIADDRCFG: usize = 0x1BC8;
const APLIC_SMSIADDRCFGH: usize = 0x1BCC;
const APLIC_SETIPNUM: usize = 0x1CDC;
const APLIC_CLRIPNUM: usize = 0x1DDC;
const APLIC_SETIENUM: usize = 0x1EDC;
const APLIC_CLRIENUM: usize = 0x1FDC;
const APLIC_TARGET_BASE: usize = 0x3000; // + 4 * i (i = 1..1023)
const APLIC_IDC_BASE: usize = 0x4000;
const APLIC_IDC_STRIDE: usize = 0x20;

// APLIC IDC offsets (Direct Delivery Mode, when no IMSIC is present)
const APLIC_IDC_IDELIVERY: usize = 0x00;
const APLIC_IDC_IFORC: usize = 0x04;
const APLIC_IDC_ITHRESHOLD: usize = 0x08;
const APLIC_IDC_TOPI: usize = 0x18;
const APLIC_IDC_CLAIMEIR: usize = 0x1C;

const AplicDomainCfg = packed struct(u32) {
    be: bool = false,
    _reserved0: u1 = 0,
    /// false (0) = Direct delivery via IDCs; true (1) = MSI delivery to IMSICs.
    dm: bool = false,
    _reserved1: u4 = 0,
    g: bool = false,
    ie: bool = false,
    _reserved2: u15 = 0,
    read_only_80: u8 = 0,
};

const AplicSourceMode = enum(u3) {
    inactive = 0,
    detached = 1,
    edge_rising = 4,
    edge_falling = 5,
    level_high = 6,
    level_low = 7,
};

const AplicSourceCfg = packed struct(u32) {
    sm: AplicSourceMode = .inactive,
    _reserved0: u7 = 0,
    delegate: bool = false,
    _reserved1: u21 = 0,
};

const AplicTargetMsi = packed struct(u32) {
    eiid: u11 = 0,
    _reserved: u1 = 0,
    guest_index: u6 = 0,
    hart_index: u14 = 0,
};

const AplicTargetDirect = packed struct(u32) {
    iprio: u8 = DEFAULT_PRIORITY,
    _reserved: u10 = 0,
    hart_index: u14 = 0,
};

const AplicSmsiAddrCfgH = packed struct(u32) {
    base_ppn_high: u12 = 0,
    lhxw: u4 = 0,
    lhxs: u3 = 0,
    _reserved0: u1 = 0,
    hhxw: u3 = 0,
    _reserved1: u1 = 0,
    hhxs: u5 = 0,
    _reserved2: u2 = 0,
    locked: bool = false,
};

const AplicClaimEir = packed struct(u32) {
    priority: u8 = 0,
    _reserved0: u8 = 0,
    source_id: u10 = 0,
    _reserved1: u6 = 0,
};

const CpuState = struct {
    hart_id: u64 = 0,
    imsic_phys: u64 = 0,
    imsic_base: usize = 0,
    msi_hart_index: u14 = 0,
    idc_index: u14 = 0,
    online: bool = false,
    local_irqs: [IPI_COUNT]?VirtIrq.Handle = @splat(null),
};

const SourceMeta = packed struct(u32) {
    mode: AplicSourceMode = .level_high,
    enabled: bool = false,
    priority: u8 = DEFAULT_PRIORITY,
    _pad: u6 = 0,
    target_hart_index: u14 = 0,
};

comptime {
    std.debug.assert(@sizeOf(CpuState) <= 1024);
}

// --- //

const Self = @This();
const CpuList = UnrolledList(CpuState, null);

aplic_base: usize = 0,
max_source_id: u32 = 0,
num_idc: u32 = 0,

has_imsic: bool = false,
imsic_base_phys: u64 = 0,
imsic_num_ids: u32 = 255,
hart_index_bits: u5 = 0,
group_index_bits: u5 = 0,
group_index_shift: u6 = 24,

cpus: CpuList = .{},

shared_irqs: [MAX_APLIC_SOURCES + 1]?VirtIrq.Handle = @splat(null),
source_meta: [MAX_APLIC_SOURCES + 1]SourceMeta = @splat(.{}),
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

inline fn aplicRead32(self: *const Self, offset: usize) u32 {
    return mmioRead32(self.aplic_base, offset);
}

inline fn aplicWrite32(self: *const Self, offset: usize, value: u32) void {
    mmioWrite32(self.aplic_base, offset, value);
}

inline fn csrWrite(comptime csr: []const u8, val: u64) void {
    asm volatile ("csrw " ++ csr ++ ", %[val]"
        :
        : [val] "r" (val),
        : .{ .memory = true });
}

inline fn csrSet(comptime csr: []const u8, mask: u64) void {
    asm volatile ("csrrs zero, " ++ csr ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}

inline fn csrClear(comptime csr: []const u8, mask: u64) void {
    asm volatile ("csrrc zero, " ++ csr ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}

inline fn imsicClaimStopei() u64 {
    return asm volatile ("csrrw %[ret], " ++ CSR_STOPEI ++ ", zero"
        : [ret] "=r" (-> u64),
        :
        : .{ .memory = true });
}

inline fn imsicWriteReg(selector: u64, val: u64) void {
    csrWrite(CSR_SISELECT, selector);
    csrWrite(CSR_SIREG, val);
}

inline fn imsicSetEnable(eiid: u32, enabled: bool) void {
    if (eiid == 0 or eiid > MAX_IMSIC_ID) return;
    const even_idx: u64 = (@as(u64, eiid) / 64) * 2;
    const bit: u6 = @intCast(eiid % 64);
    const mask: u64 = @as(u64, 1) << bit;

    csrWrite(CSR_SISELECT, IMSIC_EIE0 + even_idx);
    if (enabled) {
        csrSet(CSR_SIREG, mask);
    } else {
        csrClear(CSR_SIREG, mask);
    }
}

inline fn currentCpuId() u32 {
    return @intCast(kernel.cpu.CpuContext.current().?.processor_id);
}

fn computeMsiHartIndex(self: *const Self, imsic_phys: u64) u14 {
    if (self.hart_index_bits == 0 and self.group_index_bits == 0) {
        return @truncate((imsic_phys -| self.imsic_base_phys) >> 12);
    }

    const hart_mask: u64 = (@as(u64, 1) << self.hart_index_bits) - 1;
    const group_mask: u64 = (@as(u64, 1) << self.group_index_bits) - 1;

    const h: u64 = (imsic_phys >> 12) & hart_mask;
    const g: u64 = (imsic_phys >> self.group_index_shift) & group_mask;

    return @truncate((g << self.hart_index_bits) | h);
}

// --- //

fn aplicInit(self: *Self) void {
    self.aplicWrite32(APLIC_DOMAINCFG, 0);

    if (self.has_imsic and self.imsic_base_phys != 0) {
        const cur_cfgh: AplicSmsiAddrCfgH = @bitCast(self.aplicRead32(APLIC_SMSIADDRCFGH));
        if (!cur_cfgh.locked) {
            const base_ppn: u64 = self.imsic_base_phys >> 12;
            const hhxs: u5 = if (self.group_index_shift >= 24)
                @intCast(self.group_index_shift - 24)
            else
                0;

            self.aplicWrite32(APLIC_SMSIADDRCFG, @truncate(base_ppn));
            self.aplicWrite32(APLIC_SMSIADDRCFGH, @bitCast(AplicSmsiAddrCfgH{
                .base_ppn_high = @truncate(base_ppn >> 32),
                .lhxw = @truncate(self.hart_index_bits),
                .lhxs = 0,
                .hhxw = @truncate(self.group_index_bits),
                .hhxs = hhxs,
                .locked = false,
            }));
        }
    }

    const default_target_idx: u14 = if (self.cpus.get(0)) |c0|
        (if (self.has_imsic) c0.msi_hart_index else c0.idc_index)
    else
        0;

    var id: u32 = 1;
    while (id <= self.max_source_id) : (id += 1) {
        self.aplicWrite32(APLIC_CLRIENUM, id);
        self.aplicWrite32(APLIC_CLRIPNUM, id);
        self.aplicWrite32(APLIC_SOURCECFG_BASE + id * 4, @bitCast(AplicSourceCfg{
            .sm = .inactive,
        }));
        self.source_meta[id] = .{
            .mode = .level_high,
            .enabled = false,
            .priority = DEFAULT_PRIORITY,
            .target_hart_index = default_target_idx,
        };
    }

    self.aplicWrite32(APLIC_DOMAINCFG, @bitCast(AplicDomainCfg{
        .be = false,
        .dm = self.has_imsic,
        .ie = true,
    }));

    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

fn aplicWriteSourceConfigAndTarget(self: *Self, source_id: u32) void {
    const meta = self.source_meta[source_id];

    self.aplicWrite32(APLIC_SOURCECFG_BASE + source_id * 4, @bitCast(AplicSourceCfg{
        .sm = meta.mode,
    }));

    if (self.has_imsic) {
        const target_msi: AplicTargetMsi = .{
            .eiid = @intCast(APLIC_EIID_BASE + source_id),
            .guest_index = 0,
            .hart_index = meta.target_hart_index,
        };
        self.aplicWrite32(APLIC_TARGET_BASE + source_id * 4, @bitCast(target_msi));
    } else {
        const safe_prio: u8 = @max(1, @min(meta.priority, 0xFE));
        const target_direct: AplicTargetDirect = .{
            .iprio = safe_prio,
            .hart_index = meta.target_hart_index,
        };
        self.aplicWrite32(APLIC_TARGET_BASE + source_id * 4, @bitCast(target_direct));
    }
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

    const cpu_state = self.cpus.getPtr(cpu_id) orelse return .bad_request;

    if (self.has_imsic) {
        if (cpu_state.imsic_base == 0) return .bad_request;

        imsicWriteReg(IMSIC_EIDELIVERY, 0);

        imsicWriteReg(IMSIC_EITHRESHOLD, 0);

        const max_id = @min(self.imsic_num_ids, MAX_IMSIC_ID);
        const reg_pairs: u64 = (max_id + 64) / 64;

        var pair: u64 = 0;
        while (pair < reg_pairs) : (pair += 1) {
            const even_idx = pair * 2;
            imsicWriteReg(IMSIC_EIP0 + even_idx, 0);
            const enable_mask: u64 = if (pair == 0) ~@as(u64, 1) else std.math.maxInt(u64);
            imsicWriteReg(IMSIC_EIE0 + even_idx, enable_mask);
        }

        imsicWriteReg(IMSIC_EIDELIVERY, 1);
    } else if (self.aplic_base != 0) {
        const idc_base = self.aplic_base + APLIC_IDC_BASE + @as(usize, cpu_state.idc_index) * APLIC_IDC_STRIDE;
        mmioWrite32(idc_base, APLIC_IDC_IFORC, 0);
        mmioWrite32(idc_base, APLIC_IDC_ITHRESHOLD, 0);
        mmioWrite32(idc_base, APLIC_IDC_IDELIVERY, 1);
    } else {
        return .bad_request;
    }

    csrSet(CSR_SIE, SIE_SEIE);
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    @atomicStore(bool, &cpu_state.online, true, .release);

    return .success;
}

fn vDeinitGlobal(context: *anyopaque) callconv(basalt.system.call_conv) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.aplic_base != 0) {
        self.aplicWrite32(APLIC_DOMAINCFG, 0);
    }
    if (self.has_imsic) {
        imsicWriteReg(IMSIC_EIDELIVERY, 0);
    }
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

inline fn isIpiRequest(self: *const Self, request: intc.Domain.Request) bool {
    if (request.hardware_irq > MAX_IPI_ID) return false;
    if (request.hardware_irq == 0 or self.aplic_base == 0) return true;
    return request.trigger_mode == .message;
}

fn vRegister(context: *anyopaque, request: intc.Domain.Request, virq: VirtIrq.Handle) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));
    const cpu_id = currentCpuId();
    const cpu_state = self.cpus.getPtr(cpu_id) orelse return .bad_request;

    const saved = self.irqs_lock.acquire(.write, 0);
    defer self.irqs_lock.release(.write, saved);

    if (self.isIpiRequest(request)) {
        if (!self.has_imsic) return .bad_request;
        const ipi_id: u32 = @intCast(request.hardware_irq);
        const slot = &cpu_state.local_irqs[ipi_id];
        if (slot.* != null) return .already_registered;
        slot.* = virq;
        return .success;
    }

    if (self.aplic_base == 0 or request.hardware_irq == 0 or request.hardware_irq > self.max_source_id) {
        return .bad_request;
    }

    const source_id: u32 = @intCast(request.hardware_irq);
    const slot = &self.shared_irqs[source_id];
    if (slot.* != null) return .already_registered;

    slot.* = virq;

    self.source_meta[source_id].target_hart_index = if (self.has_imsic)
        cpu_state.msi_hart_index
    else
        cpu_state.idc_index;

    self.aplicWriteSourceConfigAndTarget(source_id);

    return .success;
}

fn vAcknowledge(context: *anyopaque) callconv(basalt.system.call_conv) intc.Domain.AckRes {
    const self: *Self = @ptrCast(@alignCast(context));
    const cpu_id = currentCpuId();

    if (self.has_imsic) {
        const stopei = imsicClaimStopei();
        if (stopei == 0) {
            return .{ .code = .spurious };
        }

        const eiid: u32 = @truncate(stopei >> 16);

        if (eiid <= IPI_COUNT) {
            const ipi_id = eiid - 1;
            const cpu_state = self.cpus.getPtr(cpu_id) orelse return .{ .code = .unregistered };
            const handle = cpu_state.local_irqs[ipi_id] orelse return .{ .code = .unregistered };
            return .{
                .code = .success,
                .virtirq = handle,
                .token = eiid,
            };
        }

        const source_id = eiid - APLIC_EIID_BASE;
        if (source_id == 0 or source_id > self.max_source_id) {
            return .{ .code = .unregistered };
        }

        const handle = self.shared_irqs[source_id] orelse {
            if (self.aplic_base != 0) self.aplicWrite32(APLIC_CLRIENUM, source_id);
            return .{ .code = .unregistered };
        };

        const mode = self.source_meta[source_id].mode;
        if (mode == .level_high or mode == .level_low) {
            self.aplicWrite32(APLIC_CLRIENUM, source_id);
        }

        return .{
            .code = .success,
            .virtirq = handle,
            .token = eiid,
        };
    }

    if (self.aplic_base == 0) return .{ .code = .spurious };
    const cpu_state = self.cpus.getPtr(cpu_id) orelse return .{ .code = .spurious };
    const idc_base = self.aplic_base + APLIC_IDC_BASE + @as(usize, cpu_state.idc_index) * APLIC_IDC_STRIDE;

    const raw = mmioRead32(idc_base, APLIC_IDC_CLAIMEIR);
    const claim: AplicClaimEir = @bitCast(raw);
    const source_id: u32 = claim.source_id;

    if (source_id == 0) {
        return .{ .code = .spurious };
    }
    if (source_id > self.max_source_id) {
        return .{ .code = .unregistered };
    }

    const handle = self.shared_irqs[source_id] orelse {
        self.aplicWrite32(APLIC_CLRIENUM, source_id);
        return .{ .code = .unregistered };
    };

    const mode = self.source_meta[source_id].mode;
    if (mode == .level_high or mode == .level_low) {
        self.aplicWrite32(APLIC_CLRIENUM, source_id);
    }

    return .{
        .code = .success,
        .virtirq = handle,
        .token = APLIC_EIID_BASE + source_id,
    };
}

fn vPriorityDrop(context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    _ = context;
    _ = hw_irq;

    if (token == 0 or token > MAX_IMSIC_ID) return .bad_request;
    return .success;
}

fn vDeactivate(context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));
    _ = hw_irq;

    if (token == 0 or token > MAX_IMSIC_ID) return .bad_request;
    const eiid: u32 = @truncate(token);

    if (eiid <= IPI_COUNT) {
        return .success;
    }

    const source_id = eiid - APLIC_EIID_BASE;
    if (source_id == 0 or source_id > self.max_source_id or self.aplic_base == 0) {
        return .bad_request;
    }

    const meta = self.source_meta[source_id];
    if ((meta.mode == .level_high or meta.mode == .level_low) and meta.enabled) {
        self.aplicWrite32(APLIC_SETIENUM, source_id);
    }

    return .success;
}

fn vSetEnabled(context: *anyopaque, hw_irq: u64, enabled: bool) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq <= MAX_IPI_ID) {
        const ipi_id: u32 = @intCast(hw_irq);
        if (self.aplic_base == 0 or hw_irq == 0 or self.shared_irqs[ipi_id] == null) {
            if (!self.has_imsic) return .bad_request;
            imsicSetEnable(ipi_id + 1, enabled);
            return .success;
        }
    }

    if (self.aplic_base == 0 or hw_irq == 0 or hw_irq > self.max_source_id) {
        return .bad_request;
    }

    const source_id: u32 = @intCast(hw_irq);
    self.source_meta[source_id].enabled = enabled;
    self.aplicWrite32(if (enabled) APLIC_SETIENUM else APLIC_CLRIENUM, source_id);
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });

    return .success;
}

fn vSetPriority(context: *anyopaque, hw_irq: u64, priority: u8) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq <= MAX_IPI_ID) {
        const ipi_id: u32 = @intCast(hw_irq);
        if (self.aplic_base == 0 or hw_irq == 0 or self.shared_irqs[ipi_id] == null) {
            return .success;
        }
    }

    if (self.aplic_base == 0 or hw_irq == 0 or hw_irq > self.max_source_id) {
        return .bad_request;
    }

    const source_id: u32 = @intCast(hw_irq);
    self.source_meta[source_id].priority = @max(1, @min(priority, 0xFE));

    if (!self.has_imsic) {
        self.aplicWriteSourceConfigAndTarget(source_id);
    }

    return .success;
}

fn vSetTriggerMode(context: *anyopaque, hw_irq: u64, trigger_mode: VirtIrq.TriggerMode) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (hw_irq <= MAX_IPI_ID) {
        const ipi_id: u32 = @intCast(hw_irq);
        if (self.aplic_base == 0 or hw_irq == 0 or self.shared_irqs[ipi_id] == null) {
            return switch (trigger_mode) {
                .edge_rising, .edge_falling, .message => .success,
                else => .bad_request,
            };
        }
    }

    if (self.aplic_base == 0 or hw_irq == 0 or hw_irq > self.max_source_id) {
        return .bad_request;
    }

    const source_id: u32 = @intCast(hw_irq);
    const sm: AplicSourceMode = switch (trigger_mode) {
        .edge_rising => .edge_rising,
        .edge_falling => .edge_falling,
        .level_high => .level_high,
        .level_low => .level_low,
        .message => .detached,
    };

    self.source_meta[source_id].mode = sm;
    self.aplicWriteSourceConfigAndTarget(source_id);

    if (self.source_meta[source_id].enabled) {
        self.aplicWrite32(APLIC_SETIENUM, source_id);
    }

    return .success;
}

fn vSetTarget(context: *anyopaque, hw_irq: u64, cpu_mask: u64) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (self.aplic_base == 0 or hw_irq == 0 or hw_irq > self.max_source_id or cpu_mask == 0) {
        return .bad_request;
    }

    const source_id: u32 = @intCast(hw_irq);
    var mask = cpu_mask;

    while (mask != 0) {
        const cpu_idx: u6 = @intCast(@ctz(mask));
        mask &= ~(@as(u64, 1) << cpu_idx);

        if (self.cpus.getPtr(cpu_idx)) |cpu_state| {
            self.source_meta[source_id].target_hart_index = if (self.has_imsic)
                cpu_state.msi_hart_index
            else
                cpu_state.idc_index;

            self.aplicWriteSourceConfigAndTarget(source_id);
            if (self.source_meta[source_id].enabled) {
                self.aplicWrite32(APLIC_SETIENUM, source_id);
            }
            return .success;
        }
    }

    return .bad_request;
}

fn vSendIpi(context: *anyopaque, hw_irq: u64, target: intc.Domain.IpiTarget) callconv(basalt.system.call_conv) intc.Domain.ResultCode {
    const self: *Self = @ptrCast(@alignCast(context));

    if (!self.has_imsic or hw_irq > MAX_IPI_ID) return .bad_request;

    const eiid: u32 = @as(u32, @intCast(hw_irq)) + 1;
    const self_cpu_id = currentCpuId();

    asm volatile ("fence rw, ow" ::: .{ .memory = true });

    switch (target.filter) {
        .self => {
            const cpu = self.cpus.getPtr(self_cpu_id) orelse return .bad_request;
            if (cpu.imsic_base == 0) return .bad_request;
            mmioWrite32(cpu.imsic_base, IMSIC_SETEIPNUM_LE, eiid);
        },
        .all_but_self => {
            var idx: usize = 0;
            var it = self.cpus.iterator();
            while (it.next()) |cpu| : (idx += 1) {
                if (idx == self_cpu_id or cpu.imsic_base == 0) continue;
                if (!@atomicLoad(bool, &cpu.online, .acquire)) continue;
                mmioWrite32(cpu.imsic_base, IMSIC_SETEIPNUM_LE, eiid);
            }
        },
        .mask => {
            var mask = target.cpu_mask;
            var sent_any = false;

            while (mask != 0) {
                const cpu_idx: u6 = @intCast(@ctz(mask));
                mask &= ~(@as(u64, 1) << cpu_idx);

                const cpu = self.cpus.getPtr(cpu_idx) orelse continue;
                if (cpu.imsic_base == 0) continue;

                mmioWrite32(cpu.imsic_base, IMSIC_SETEIPNUM_LE, eiid);
                sent_any = true;
            }

            if (!sent_any) return .bad_request;
        },
    }

    return .success;
}
