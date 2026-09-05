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

// --- mem/virt/Space.zig --- //

const Space = @This();

const Map = utils.SlotMap(utils.Arc(Space));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;

pub var map: Map = .{};

pub const Error = error{
    InvalidRange,
    OutOfBounds,
    Overlaps,
    NotFound,
    OutOfMemory,
    ProtectedRegion,
    InvalidArgs,
};

pub const Half = enum {
    low,
    high,

    pub inline fn minVa(self: Half) u64 {
        return switch (self) {
            .low => 0,
            .high => kernel.arch.paging.high_half_min,
        };
    }

    pub inline fn maxVa(self: Half) u64 {
        return switch (self) {
            .low => kernel.arch.paging.low_half_max,
            .high => std.math.maxInt(u64),
        };
    }

    pub fn contains(self: Half, base_va: u64, end_va: u64) bool {
        if (end_va <= base_va) return false;
        const end_inclusive = end_va - 1;
        return base_va >= self.minVa() and end_inclusive <= self.maxVa();
    }
};

half: Half,
lock: utils.RwLock,
page_table: paging.PageTable,
first_node: ?*Node,

pub fn init(half: Half) !Space {
    return .{
        .half = half,
        .lock = .{},
        .page_table = try .init(null),
        .first_node = null,
    };
}

pub fn SlotMap_deinit(self: *Space) void {
    self.page_table.deinit();

    var current = self.first_node;
    while (current) |node| {
        const next = node.next;
        node.destroy();
        current = next;
    }
    self.first_node = null;
}

pub fn get(self: *Space, va: u64) ?*Region {
    if (va < self.half.minVa() or va > self.half.maxVa()) return null;

    const int_state = self.lock.acquire(.read, 0);
    defer self.lock.release(.read, int_state);

    var current = self.first_node;
    while (current) |node| {
        if (node.len > 0) {
            const first_va = node.regions[0].base_va;
            const last_va = node.regions[node.len - 1].end_va;

            if (va < first_va) return null;
            if (va < last_va) {
                if (node.get(va)) |reg| return reg;
                return null;
            }
        }
        current = node.next;
    }
    return null;
}

fn releaseTarget(target: RegionTarget) void {
    switch (target) {
        .owned => |ref| {
            var r = ref;
            r.release();
        },
        .shared => |ref| {
            var r = ref;
            r.release();
        },
        .guard => {},
    }
}

pub fn alloc(self: *Space, size: u64, target: RegionTarget, with_guards: bool, min_va: u64) !u64 {
    if (size == 0 or size % paging.page_size != 0) return Error.InvalidRange;
    if (with_guards and target == .guard) return Error.InvalidArgs;

    errdefer releaseTarget(target);

    const total_size = if (with_guards) size + (2 * paging.page_size) else size;

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    const base_va = self.findFreeSpaceLocked(total_size, min_va) orelse return Error.OutOfMemory;

    if (with_guards) {
        const guard1_start = base_va;
        const main_start = base_va + paging.page_size;
        const main_end = main_start + size;
        const guard2_end = main_end + paging.page_size;

        const main_kind: Region.Kind = switch (target) {
            .owned => |ref| .{ .owned = .{ .ref = ref, .has_guards = true } },
            .shared => |ref| .{ .shared = .{ .ref = ref, .has_guards = true } },
            .guard => @panic("main_kind.guard"),
        };

        const guard1 = Region{ .base_va = guard1_start, .end_va = main_start, .kind = .linked_guard };
        const main_region = Region{ .base_va = main_start, .end_va = main_end, .kind = main_kind };
        const guard2 = Region{ .base_va = main_end, .end_va = guard2_end, .kind = .linked_guard };

        _ = try self.insertLocked(guard1);
        errdefer self.removeLocked(guard1_start) catch @panic("removedLocked2");
        try guard1.submitMapping(&self.page_table);
        errdefer guard1.unmapRegion(&self.page_table) catch @panic("unmapRegion1");

        _ = try self.insertLocked(main_region);
        errdefer self.removeLocked(main_start) catch @panic("removedLocked3");
        try main_region.submitMapping(&self.page_table);
        errdefer main_region.unmapRegion(&self.page_table) catch @panic("unmapRegion2");

        _ = try self.insertLocked(guard2);
        errdefer self.removeLocked(main_end) catch @panic("removedLocked4");
        try guard2.submitMapping(&self.page_table);

        return main_start;
    } else {
        const kind: Region.Kind = switch (target) {
            .owned => |ref| .{ .owned = .{ .ref = ref, .has_guards = false } },
            .shared => |ref| .{ .shared = .{ .ref = ref, .has_guards = false } },
            .guard => .guard,
        };

        const region = Region{ .base_va = base_va, .end_va = base_va + size, .kind = kind };

        _ = try self.insertLocked(region);
        errdefer self.removeLocked(base_va) catch @panic("removedLocked1");
        try region.submitMapping(&self.page_table);

        return base_va;
    }
}

pub fn mapAt(self: *Space, region: Region) !void {
    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);
    var reg = try self.insertLocked(region);
    errdefer self.removeLocked(region.base_va) catch @panic("removedLock5");
    try reg.submitMapping(&self.page_table);
}

pub fn remove(self: *Space, base_va: u64) !void {
    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    var target_region: Region = undefined;
    var found = false;

    var current = self.first_node;
    while (current) |node| {
        if (node.len > 0 and base_va >= node.regions[0].base_va and base_va <= node.regions[node.len - 1].base_va) {
            if (node.get(base_va)) |reg| {
                if (reg.base_va == base_va) {
                    target_region = reg.*;
                    found = true;
                    break;
                }
            }
        }
        current = node.next;
    }

    if (!found) return Error.NotFound;

    const has_guards = switch (target_region.kind) {
        .linked_guard => return Error.ProtectedRegion,
        .owned => |o| o.has_guards,
        .shared => |s| s.has_guards,
        else => false,
    };

    const unmap_start = if (has_guards) target_region.base_va - paging.page_size else target_region.base_va;
    const unmap_end = if (has_guards) target_region.end_va + paging.page_size else target_region.end_va;
    const batch_size = (unmap_end - unmap_start) / paging.page_size;

    const kind_ref: union(enum) { none, owned: virt.OwnedObject.Ref, shared: virt.SharedObject.Ref } = switch (target_region.kind) {
        .linked_guard => return Error.ProtectedRegion,
        .owned => |o| .{ .owned = o.ref },
        .shared => |s| .{ .shared = s.ref },
        else => .none,
    };

    var query = paging.Query{
        .virtual_address = unmap_start,
        .physical_address = null,
        .batch_size = @intCast(batch_size),
        .state = .unmapped,
        .permissions = null,
        .mem_type = null,
        .level = null,
    };
    try self.page_table.submit(&query);

    if (has_guards) {
        self.removeLocked(target_region.base_va) catch @panic("removedLock6");
        self.removeLocked(target_region.base_va - paging.page_size) catch @panic("removedLock7");
        self.removeLocked(target_region.end_va) catch @panic("removedLock8");
    } else {
        self.removeLocked(target_region.base_va) catch @panic("removedLock9");
    }

    switch (kind_ref) {
        .owned => |ref| {
            ref.release();
        },
        .shared => |ref| {
            ref.release();
        },
        .none => {},
    }
}

fn findFreeSpaceLocked(self: *Space, size: u64, min_va: u64) ?u64 {
    if (min_va > self.half.maxVa()) return null;
    var current_va = std.mem.alignForward(u64, @max(min_va, self.half.minVa()), paging.page_size);
    if (current_va == 0 and min_va > 0) return null;

    var current = self.first_node;
    while (current) |node| {
        for (0..node.len) |i| {
            const reg = &node.regions[i];

            if (current_va + size <= reg.base_va) {
                return current_va;
            }

            const next_va = std.mem.alignForward(u64, reg.end_va, paging.page_size);
            if (next_va == 0) return null;

            if (next_va > current_va) {
                current_va = next_va;
            }
        }
        current = node.next;
    }

    if (self.half.maxVa() - current_va >= size - 1) {
        return current_va;
    }

    return null;
}

fn insertLocked(self: *Space, region: Region) !*Region {
    if (!self.half.contains(region.base_va, region.end_va)) return Error.OutOfBounds;

    if (self.first_node == null) {
        const node = try Node.create();
        node.regions[0] = region;
        node.len = 1;
        self.first_node = node;
        return &node.regions[0];
    }

    var prev: ?*Node = null;
    var current = self.first_node.?;

    while (current.next != null and region.base_va >= current.regions[current.len - 1].end_va) {
        prev = current;
        current = current.next.?;
    }

    var idx: usize = 0;
    while (idx < current.len and current.regions[idx].base_va < region.base_va) {
        idx += 1;
    }

    if (idx > 0) {
        if (current.regions[idx - 1].end_va > region.base_va) return Error.Overlaps;
    } else if (prev) |p| {
        if (p.regions[p.len - 1].end_va > region.base_va) return Error.Overlaps;
    }

    if (idx < current.len) {
        if (current.regions[idx].base_va < region.end_va) return Error.Overlaps;
    } else if (current.next) |n| {
        if (n.regions[0].base_va < region.end_va) return Error.Overlaps;
    }

    var target_node = current;
    var target_idx = idx;

    if (current.len == Node.CAPACITY) {
        const new_node = try Node.create();
        const mid = Node.CAPACITY / 2;
        const to_move = Node.CAPACITY - mid;

        @memcpy(new_node.regions[0..to_move], current.regions[mid..Node.CAPACITY]);
        new_node.len = to_move;
        current.len = mid;

        new_node.next = current.next;
        current.next = new_node;

        if (idx > mid) {
            target_node = new_node;
            target_idx = idx - mid;
        }
    }

    var i: usize = target_node.len;
    while (i > target_idx) : (i -= 1) {
        target_node.regions[i] = target_node.regions[i - 1];
    }

    target_node.regions[target_idx] = region;
    target_node.len += 1;
    return &target_node.regions[target_idx];
}

fn removeLocked(self: *Space, base_va: u64) !void {
    var prev: ?*Node = null;
    var current = self.first_node;

    while (current) |node| {
        if (node.len > 0 and base_va >= node.regions[0].base_va and base_va <= node.regions[node.len - 1].base_va) {
            for (0..node.len) |i| {
                if (node.regions[i].base_va == base_va) {
                    var j = i;
                    while (j < node.len - 1) : (j += 1) {
                        node.regions[j] = node.regions[j + 1];
                    }
                    node.len -= 1;

                    if (node.len == 0) {
                        if (prev) |p| {
                            p.next = node.next;
                        } else {
                            self.first_node = node.next;
                        }
                        node.destroy();
                    }
                    return;
                }
            }
        }
        prev = current;
        current = node.next;
    }
    return Error.NotFound;
}

const Node = struct {
    const HEADER_SIZE = @sizeOf(?*Node) + @sizeOf(usize);
    const CAPACITY = (paging.page_size - HEADER_SIZE) / @sizeOf(Region);

    next: ?*Node = null,
    len: usize = 0,
    regions: [CAPACITY]Region = undefined,

    pub fn create() !*Node {
        const pa = try phys.allocPage();
        const node = mem.toHhdm(Node, pa);
        node.next = null;
        node.len = 0;
        return node;
    }

    pub fn destroy(self: *Node) void {
        for (self.regions[0..self.len]) |*region| {
            switch (region.kind) {
                .guard, .linked_guard => {},
                .owned => |*ow| {
                    ow.ref.payload().destroy();
                    ow.ref.release();
                },
                .shared => |*sw| {
                    sw.ref.payload().destroy();
                    sw.ref.release();
                },
            }
        }

        const pa = mem.fromHhdm(Node, self);
        phys.freePage(pa);
    }

    pub fn get(self: *Node, va: u64) ?*Region {
        var left: usize = 0;
        var right: usize = self.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const reg = &self.regions[mid];

            if (va < reg.base_va) {
                right = mid;
            } else if (va >= reg.end_va) {
                left = mid + 1;
            } else {
                return reg;
            }
        }
        return null;
    }
};

pub const RegionTarget = union(enum) {
    guard,
    owned: virt.OwnedObject.Ref,
    shared: virt.SharedObject.Ref,
};

pub fn SlotMap_updateHhdm(self: *Space) void {
    var current_ptr: *?*Node = &self.first_node;
    var current = self.first_node;
    while (current) |node| {
        for (node.regions[0..node.len]) |*region| {
            switch (region.kind) {
                .guard, .linked_guard => {},
                .owned => |*ow| {
                    ow.ref.updateHhdm();
                },
                .shared => |*sw| {
                    sw.ref.updateHhdm();
                },
            }
        }

        current_ptr.* = mem.updatePtr(Node, node);

        current_ptr = &node.next;
        current = node.next;
    }
}

pub const Region = struct {
    base_va: u64,
    end_va: u64,
    kind: Kind,
    pinned: std.atomic.Value(usize) = .init(0),

    pub const Kind = union(enum) {
        guard,
        linked_guard,
        owned: struct {
            ref: virt.OwnedObject.Ref,
            has_guards: bool,
        },
        shared: struct {
            ref: virt.SharedObject.Ref,
            has_guards: bool,
        },
    };

    pub fn submitMapping(self: *const Region, page_table: *paging.PageTable) !void {
        switch (self.kind) {
            .guard, .linked_guard => {
                var query = paging.Query{
                    .virtual_address = self.base_va,
                    .physical_address = null,
                    .batch_size = @intCast((self.end_va - self.base_va) / paging.page_size),
                    .state = .guard,
                    .permissions = null,
                    .mem_type = null,
                    .level = null,
                };
                try page_table.submit(&query);
            },
            .owned => |*o| {
                const obj = o.ref.payload();
                try self.submitObjectMapping(page_table, obj, obj.permissions);
            },
            .shared => |*s| {
                var shared_obj = s.ref.payload();
                const obj = shared_obj.object.payload();
                try self.submitObjectMapping(page_table, obj, shared_obj.permissions);
            },
        }
    }

    inline fn submitObjectMapping(self: *const Region, page_table: *paging.PageTable, obj: *virt.OwnedObject, perms: paging.Permissions) !void {
        const mtype = obj.mem_type;

        const int_state = obj.lock.acquire(.read, 0);
        defer obj.lock.release(.read, int_state);

        var current_va = self.base_va;
        var batch_start_va = current_va;

        var is_uncommitted = true;
        var current_pa: ?u64 = null;
        var batch_size: usize = 0;

        switch (obj.physical_mapping) {
            .non_contiguous => |*list| {
                var page_it = list.iterator();

                while (current_va < self.end_va) : (current_va += paging.page_size) {
                    const pa_ptr = page_it.next() orelse return Error.InvalidRange;
                    const pa = pa_ptr.*;

                    const page_is_uncommitted = (pa == 0);

                    if (page_is_uncommitted) {
                        std.debug.assert(mtype != .device);
                    }

                    const can_continue = blk: {
                        if (batch_size == 0) break :blk true;
                        if (is_uncommitted != page_is_uncommitted) break :blk false;

                        if (!is_uncommitted) {
                            const expected_pa = current_pa.? + (batch_size * paging.page_size);
                            if (pa != expected_pa) break :blk false;
                        }
                        break :blk true;
                    };

                    if (!can_continue) {
                        try submitBatch(page_table, batch_start_va, current_pa, batch_size, is_uncommitted, perms, mtype);

                        batch_start_va = current_va;
                        is_uncommitted = page_is_uncommitted;
                        current_pa = if (page_is_uncommitted) null else pa;
                        batch_size = 1;
                    } else {
                        if (batch_size == 0) {
                            is_uncommitted = page_is_uncommitted;
                            current_pa = if (page_is_uncommitted) null else pa;
                        }
                        batch_size += 1;
                    }
                }
            },
            .contiguous => |pa| {
                is_uncommitted = false;
                current_pa = pa;
                batch_size = obj.length;
            },
        }

        if (batch_size > 0) {
            try submitBatch(page_table, batch_start_va, current_pa, batch_size, is_uncommitted, perms, mtype);
        }
    }

    inline fn submitBatch(page_table: *paging.PageTable, va: u64, pa: ?u64, count: usize, is_uncommitted: bool, perms: paging.Permissions, mtype: paging.MemType) !void {
        var query = paging.Query{
            .virtual_address = va,
            .physical_address = pa,
            .batch_size = count,
            .state = if (is_uncommitted) .uncommitted else .committed,
            .permissions = perms,
            .mem_type = mtype,
            .level = null,
        };
        try page_table.submit(&query);
    }

    pub fn unmapRegion(self: *const Region, page_table: *paging.PageTable) !void {
        var query = paging.Query{
            .virtual_address = self.base_va,
            .physical_address = null,
            .batch_size = @intCast((self.end_va - self.base_va) / paging.page_size),
            .state = .unmapped,
            .permissions = null,
            .mem_type = null,
            .level = null,
        };
        try page_table.submit(&query);
    }
};
