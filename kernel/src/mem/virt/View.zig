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
const utils = mem.utils;
const virt = mem.virt;
const Space = virt.Space;
const OwnedObject = virt.OwnedObject;

// --- mem/virt/View.zig --- //

const View = @This();

const Map = utils.SlotMap(utils.Arc(View));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

pub var map: Map = .{};

id: Id = .null,
space: Space.Ref,
closed: std.atomic.Value(bool) = .init(false),

pub fn create(space_ref: Space.Ref) !New {
    var sr = space_ref;
    errdefer sr.release();

    const id, const ref = try map.insert(.{
        .space = sr,
    });
    ref.payload().id = id;
    return .{ id, ref };
}

pub fn createSubView(self: *View) !New {
    if (self.closed.load(.acquire)) return Space.Error.ViewClosed;

    const id, const ref = try map.insert(.{
        .space = self.space.clone(),
    });
    ref.payload().id = id;
    return .{ id, ref };
}

pub fn SlotMap_deinit(self: *View) void {
    self.closed.store(true, .release);
    self.space.payload().removeAllForView(self.id, true) catch {};
    self.space.release();
}

pub fn SlotMap_updateHhdm(self: *View) void {
    self.space.updateHhdm();
}

pub fn clear(self: *View) !void {
    if (self.closed.load(.acquire)) return Space.Error.ViewClosed;
    try self.space.payload().removeAllForView(self.id, false);
}

pub fn alloc(
    self: *View,
    size: u64,
    target: Space.RegionTarget,
    with_guards: bool,
    min_va: u64,
) !u64 {
    if (self.closed.load(.acquire)) {
        Space.releaseTarget(target);
        return Space.Error.ViewClosed;
    }
    return self.space.payload().allocForView(self.id, size, target, with_guards, min_va);
}

pub fn mapAt(
    self: *View,
    base_va: u64,
    end_va: u64,
    target: Space.RegionTarget,
    with_guards: bool,
) !void {
    if (self.closed.load(.acquire)) {
        Space.releaseTarget(target);
        return Space.Error.ViewClosed;
    }
    return self.space.payload().mapAtForView(self.id, base_va, end_va, target, with_guards);
}

pub fn remove(self: *View, base_va: u64) !void {
    if (self.closed.load(.acquire)) return Space.Error.ViewClosed;
    return self.space.payload().removeForView(self.id, base_va);
}

pub fn protect(self: *View, base_va: u64, new_perms: paging.Permissions) !void {
    if (self.closed.load(.acquire)) return Space.Error.ViewClosed;
    return self.space.payload().protectForView(self.id, base_va, new_perms);
}

pub fn getOwned(self: *View, va: u64) ?Space.RegionSnapshot {
    return self.space.payload().getForView(self.id, va);
}

pub fn mmio(self: *View, base: u64, size: u64) !u64 {
    if (size == 0) return Space.Error.InvalidRange;

    const base_aligned = std.mem.alignBackward(u64, base, paging.page_size);
    const offset = base - base_aligned;

    const total_size = std.math.add(u64, size, offset) catch return Space.Error.InvalidRange;
    const aligned_size = std.mem.alignForward(u64, total_size, paging.page_size);

    _, const ref = try OwnedObject.map.insert(.{
        .length = aligned_size / paging.page_size,
        .mem_type = .device,
        .permissions = .{
            .executable = false,
            .global = true,
            .user = false,
            .writable = true,
        },
        .owns_physical = false,
        .physical_mapping = .{ .contiguous = base_aligned },
    });

    const va_base = try self.alloc(aligned_size, .{ .owned = ref }, false, 0);
    return va_base + offset;
}

pub fn pinRange(
    self: *View,
    va: u64,
    size: u64,
    required_perms: paging.Permissions,
) !PinnedRange {
    if (self.closed.load(.acquire)) return Space.Error.ViewClosed;
    try self.space.payload().pinRangeForView(self.id, va, size, required_perms);
    return .{
        .view_id = self.id,
        .space = self.space.clone(),
        .base_va = va,
        .size = size,
    };
}

pub fn unpinRange(self: *View, va: u64, size: u64) void {
    self.space.payload().unpinRangeForView(self.id, va, size);
}

pub const PinnedRange = struct {
    view_id: Id,
    space: Space.Ref,
    base_va: u64,
    size: u64,
    active: bool = true,

    pub fn unpin(self: *PinnedRange) void {
        if (!self.active) return;
        self.active = false;
        self.space.payload().unpinRangeForView(self.view_id, self.base_va, self.size);
        self.space.release();
    }
};

pub fn handlePageFault(self: *View, fault_va: u64) Space.FaultResult {
    if (self.closed.load(.acquire)) return .access_violation;
    return self.space.payload().handlePageFaultForView(self.id, fault_va);
}
