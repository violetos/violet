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

const drivers = kernel.drivers;
const intc = drivers.intc;
const Domain = intc.Domain;

const sched = kernel.sched;
const Future = sched.Future;

// --- drivers/intc/VirtIrq.zig --- //

const VirtIrq = @This();
const Map = SlotMap(Arc(VirtIrq));
var map: Map = .{};

pub const Handle = Map.Handle;
pub const Ref = Map.PtrRef;
pub const New = Map.New;

pub fn new(virt_irq: VirtIrq) !New {
    return map.insert(virt_irq);
}

pub fn get(handle: Handle) ?Ref {
    return map.get(handle);
}

// --- //

domain: Domain.Ref,
hw_irq: u64,
kind: Kind,

content: Content,

nested_in: ?VirtIrq.Ref = null,
pending_children: std.atomic.Value(u32) = .init(0),
state: std.atomic.Value(State) = .init(.inactive),
token: std.atomic.Value(u64) = .init(0),

// --- //

pub fn priorityDrop(self: *VirtIrq) !void {
    if (self.state.load(.acquire) != .pending) return Domain.Error.InvalidState;

    const token = self.token.load(.acquire);
    try self.domain.payload().priorityDrop(self.hw_irq, token);

    if (self.state.cmpxchgStrong(.pending, .dropped, .release, .monotonic) != null) {
        return Domain.Error.InvalidState;
    }
}

pub fn deactivate(self: *VirtIrq) !void {
    if (self.state.load(.acquire) != .dropped) return Domain.Error.InvalidState;

    const token = self.token.load(.acquire);

    const parent_ptr = self.nested_in;

    if (self.state.cmpxchgStrong(.dropped, .inactive, .release, .monotonic) != null) {
        return Domain.Error.InvalidState;
    }

    try self.domain.payload().deactivate(self.hw_irq, token);

    if (parent_ptr) |p_ptr| {
        completeParentChain(p_ptr);
    }
}

pub fn completeParentChain(first_parent: VirtIrq.Ref) void {
    var current_opt: ?VirtIrq.Ref = first_parent;

    while (current_opt) |parent_ref| {
        const parent: *VirtIrq = parent_ref.payload();

        if (parent.pending_children.fetchSub(1, .acq_rel) != 1) {
            break;
        }

        const token = parent.token.load(.acquire);

        const next_parent = parent.nested_in;
        parent.nested_in = null;

        parent.state.store(.inactive, .release);
        parent.domain.payload().deactivate(parent.hw_irq, token) catch |err| {
            std.log.err("intc: parent deactivate failed on hw_irq {}: {any}", .{ parent.hw_irq, err });
        };

        var to_release = parent_ref;
        to_release.release();

        current_opt = next_parent;
    }
}

// --- //

pub const Content = extern union {
    domain: Domain.Handle,
    handler: extern struct {
        context: *anyopaque,
        /// If this field is null, this is implicitly the same as
        /// using a TopHalfFn that always returns false.
        top_half: ?VirtIrq.TopHalfFn,
        future: Future.Id,
    },
};

pub const TriggerMode = enum(u8) {
    edge_rising = 0,
    edge_falling = 1,
    level_high = 2,
    level_low = 3,
    message = 4,
};

pub const Kind = enum(u8) {
    domain = 0,
    handler = 1,
    _,
};

pub const State = enum(u64) {
    inactive = 0,
    pending = 1,
    dropped = 2,
};

/// `true` means that the interruption has been masked/ended directly from source.
///
/// `false` means that the interruption will retrigger
/// if not masked by the interruption controller directly.
///
/// WARNING: this function MUST return in constant time.
pub const TopHalfFn = *const fn (context: *anyopaque) callconv(basalt.system.call_conv) bool;
