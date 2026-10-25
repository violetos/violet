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

// --- dependencies -- //

const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const paging = mem.paging;
const phys = mem.phys;
const utils = mem.utils;
const virt = mem.virt;

// --- mem/virt/OwnedObject.zig --- //

const OwnedObject = @This();

const Map = utils.SlotMap(utils.Arc(OwnedObject));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;

pub var map: Map = .{};

pub const Error = error{
    PinnedObject,
    PinOverflow,
    WriteXorExecute,
    OutOfBounds,
};

/// Lock-free atomic Pin & Exclusive-Mutation barrier.
/// - Bits [0..62]: Active pin reference count.
/// - Bit [63] (`EXCLUSIVE_BIT`): Set during permission changes, unmapping, or destruction.
///   Any concurrent `pin()` immediately fails if `EXCLUSIVE_BIT` is set, and any
///   `beginExclusive()` immediately fails if `pin_count > 0`.
pub const PinState = struct {
    const EXCLUSIVE_BIT: u64 = 1 << 63;
    const COUNT_MASK: u64 = ~EXCLUSIVE_BIT;

    raw: std.atomic.Value(u64) = .init(0),

    pub inline fn pin(self: *PinState) !void {
        var cur = self.raw.load(.monotonic);
        while (true) {
            if (cur & EXCLUSIVE_BIT != 0) return virt.Space.Error.PinnedObject;
            if ((cur & COUNT_MASK) == COUNT_MASK) return Error.PinOverflow;

            if (self.raw.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                cur = actual;
                continue;
            }
            return;
        }
    }

    pub inline fn unpin(self: *PinState) void {
        const prev = self.raw.fetchSub(1, .release);
        std.debug.assert((prev & COUNT_MASK) > 0);
    }

    pub inline fn isPinned(self: *const PinState) bool {
        return (self.raw.load(.acquire) & COUNT_MASK) != 0;
    }

    pub inline fn count(self: *const PinState) usize {
        return @intCast(self.raw.load(.acquire) & COUNT_MASK);
    }

    pub inline fn beginExclusive(self: *PinState) !void {
        if (self.raw.cmpxchgStrong(0, EXCLUSIVE_BIT, .acq_rel, .acquire) != null) {
            return virt.Space.Error.PinnedObject;
        }
    }

    pub inline fn endExclusive(self: *PinState) void {
        self.raw.store(0, .release);
    }
};

length: usize,
mem_type: paging.MemType,
permissions: paging.Permissions,
/// False for MMIO, HHDM, and kernel static sections so `SlotMap_deinit` does not free them to `phys`.
owns_physical: bool = true,
lock: utils.RwLock = .{},
physical_mapping: PhysicalMapping,

pin_state: PinState = .{},
shared_count: std.atomic.Value(usize) = .init(0),

// --- //

pub inline fn pin(self: *OwnedObject) !void {
    try self.pin_state.pin();
}

pub inline fn unpin(self: *OwnedObject) void {
    self.pin_state.unpin();
}

pub inline fn isPinned(self: *const OwnedObject) bool {
    return self.pin_state.isPinned();
}

pub inline fn pinCount(self: *const OwnedObject) usize {
    return self.pin_state.count();
}

pub fn setPermissions(self: *OwnedObject, new_perms: paging.Permissions) !void {
    if (new_perms.writable and new_perms.executable) return virt.Space.Error.WriteXorExecute;

    try self.pin_state.beginExclusive();
    defer self.pin_state.endExclusive();

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    self.permissions = new_perms;
}

pub fn decommitPage(self: *OwnedObject, page_index: usize) !void {
    if (self.isPinned()) return virt.Space.Error.PinnedObject;

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    if (self.isPinned()) return virt.Space.Error.PinnedObject;

    switch (self.physical_mapping) {
        .non_contiguous => |*list| {
            const slot = list.getPtr(page_index) orelse return Error.OutOfBounds;
            const pa = slot.*;
            if (pa != 0) {
                slot.* = 0;
                if (self.owns_physical) phys.freePage(pa);
            }
        },
        .contiguous => return virt.Space.Error.InvalidArgs,
    }
}

// --- Lifecycle --- //

pub fn SlotMap_deinit(self: *OwnedObject) void {
    std.debug.assert(!self.isPinned());
    std.debug.assert(self.shared_count.load(.acquire) == 0);

    switch (self.physical_mapping) {
        .non_contiguous => |*list| {
            if (self.owns_physical) {
                var page_it = list.iterator();
                while (page_it.next()) |pa| {
                    const page_addr = pa.*;
                    if (page_addr == 0) continue;
                    phys.freePage(page_addr);
                }
            }
            list.deinit();
        },
        .contiguous => |pa| {
            if (!self.owns_physical or pa == std.math.maxInt(u64)) return;
            phys.freeContiguous(pa, self.length);
        },
    }
}

pub fn destroy(self: *OwnedObject) void {
    _ = self;
}

pub fn SlotMap_updateHhdm(self: *OwnedObject) void {
    switch (self.physical_mapping) {
        .non_contiguous => |*list| {
            list.updateHhdm();
        },
        .contiguous => {},
    }
}

// --- //

pub const PhysicalMapping = union(enum) {
    /// Use `owns_physical = false` (or `MAX_INT`) when the physical range must not be freed to `phys`.
    contiguous: u64,
    non_contiguous: utils.UnrolledList(u64, null),
};
