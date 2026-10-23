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

const mem = kernel.mem;
const utils = mem.utils;
const SlotMap = utils.SlotMap;
const Arc = utils.Arc;
const RwLock = utils.RwLock;

const drivers = kernel.drivers;
const intc = drivers.intc;
const VirtIrq = intc.VirtIrq;

// --- drivers/intc/Domain.zig --- //

const Domain = @This();
const Map = SlotMap(Arc(Domain));
var map: Map = .{};

pub const Handle = Map.Handle;
pub const Ref = Map.PtrRef;
pub const New = Map.New;

pub fn new(domain: Domain) !New {
    return map.insert(domain);
}

pub fn get(handle: Handle) ?Ref {
    return map.get(handle);
}

// --- //

parent: ?Domain.Ref,

context: *anyopaque,
vtable: *const VTable,

lock: RwLock = .{},

/// Protected by Domain.lock
virq_first: ?VirtIrq.Ref = null,
/// Protected by Domain.lock
virq_last: ?VirtIrq.Ref = null,

pub const VTable = extern struct {
    init_local: ?*const fn (context: *anyopaque) callconv(basalt.system.call_conv) ResultCode = null,
    deinit_global: ?*const fn (context: *anyopaque) callconv(basalt.system.call_conv) void = null,

    register: *const fn (context: *anyopaque, request: Request, virq: VirtIrq.Handle) callconv(basalt.system.call_conv) ResultCode,

    acknowledge: *const fn (context: *anyopaque) callconv(basalt.system.call_conv) AckRes,
    priority_drop: *const fn (context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) ResultCode,
    deactivate: *const fn (context: *anyopaque, hw_irq: u64, token: u64) callconv(basalt.system.call_conv) ResultCode,

    set_enabled: ?*const fn (context: *anyopaque, hw_irq: u64, enabled: bool) callconv(basalt.system.call_conv) ResultCode = null,
    set_priority: ?*const fn (context: *anyopaque, hw_irq: u64, priority: u8) callconv(basalt.system.call_conv) ResultCode = null,
    set_trigger_mode: ?*const fn (context: *anyopaque, hw_irq: u64, trigger_mode: VirtIrq.TriggerMode) callconv(basalt.system.call_conv) ResultCode = null,
    set_target: ?*const fn (context: *anyopaque, hw_irq: u64, cpu_mask: u64) callconv(basalt.system.call_conv) ResultCode = null,

    send_ipi: ?*const fn (context: *anyopaque, hw_irq: u64, target: IpiTarget) callconv(basalt.system.call_conv) ResultCode = null,
};

pub fn initLocal(self: *Domain) !void {
    if (self.vtable.init_local) |init_local| {
        const res = init_local(self.context);
        errdefer std.log.err("Domain.initLocal returned with error code '{}'", .{res});
        if (res != .success) return Error.DomainFailure;
    }
}

pub fn deinitGlobal(self: *Domain) void {
    if (self.vtable.deinit_global) |deinit_global| {
        deinit_global(self.context);
    }
}

pub fn register(self: *Domain, dr: Domain.Ref, request: Request) !VirtIrq.Handle {
    var dom_ref = dr;
    errdefer dom_ref.release();

    const virq_handle, var virq_ref: VirtIrq.Ref = try VirtIrq.new(.{
        .domain = dom_ref,
        .hw_irq = request.hardware_irq,
        .kind = request.kind,
        .content = request.content,
    });
    errdefer virq_ref.release();

    const res = self.vtable.register(self.context, request, virq_handle);

    switch (res) {
        .success => {},
        .already_registered => return Error.AlreadyRegisteredIrq,
        .bad_request => return Error.BadRequest,
        else => return Error.DomainFailure,
    }

    if (self.vtable.set_priority) |set_prio| {
        _ = set_prio(self.context, request.hardware_irq, request.priority);
    }

    if (self.vtable.set_trigger_mode) |set_trig| {
        _ = set_trig(self.context, request.hardware_irq, request.trigger_mode);
    }

    if (self.vtable.set_enabled) |set_en| {
        _ = set_en(self.context, request.hardware_irq, true);
    }

    // TODO doubly linked list of domain insert

    return virq_handle;
}

pub fn acknowledge(self: *Domain) !VirtIrq.Ref {
    const res = self.vtable.acknowledge(self.context);

    switch (res.code) {
        .success => {},
        .spurious => return Error.SpuriousIrq,
        .unregistered => return Error.UnregisteredIrq,
        else => return Error.DomainFailure,
    }

    var virq_ref: VirtIrq.Ref = VirtIrq.get(res.virtirq) orelse return Error.UnregisteredIrq;
    errdefer virq_ref.release();

    const virq: *VirtIrq = virq_ref.payload();

    if (virq.state.cmpxchgStrong(.inactive, .pending, .acq_rel, .monotonic)) |_| {
        // Hardware already acknowledged the IRQ (raising running priority).
        // Drop priority immediately so the CPU interface does not lock up.
        _ = self.vtable.priority_drop(self.context, virq.hw_irq, res.token);
        return Error.RetriggeredIrq;
    }

    virq.token.store(res.token, .release);

    return virq_ref;
}

pub fn priorityDrop(self: *Domain, hw_irq: u64, token: u64) !void {
    const res = self.vtable.priority_drop(self.context, hw_irq, token);
    if (res != .success) return Error.DomainFailure;
}

pub fn deactivate(self: *Domain, hw_irq: u64, token: u64) !void {
    const res = self.vtable.deactivate(self.context, hw_irq, token);
    if (res != .success) return Error.DomainFailure;
}

// --- //

pub const Request = extern struct {
    hardware_irq: u64,
    trigger_mode: VirtIrq.TriggerMode,
    kind: VirtIrq.Kind,
    /// 0 = highest
    /// 255 = lowest
    priority: u8,
    content: VirtIrq.Content,
};

pub const Error = error{
    DomainFailure,
    SpuriousIrq,
    UnregisteredIrq,
    RetriggeredIrq,
    AlreadyRegisteredIrq,
    BadRequest,
    InvalidState,
};

pub const ResultCode = enum(i64) {
    success = 0,
    spurious = 1,
    unregistered = 2,
    already_registered = 3,
    bad_request = 4,
    _,
};

pub const AckRes = extern struct {
    code: ResultCode,
    virtirq: VirtIrq.Handle = undefined,
    token: u64 = undefined,
};

pub const IpiFilter = enum(u8) {
    mask = 0,
    all_but_self = 1,
    self = 2,
};

pub const IpiTarget = extern struct {
    filter: IpiFilter,
    /// Ignored when filter is `.self` or `.all_but_self`.
    cpu_mask: u64 = 0,
};
