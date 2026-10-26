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

const OwnedObject = virt.OwnedObject;
const SharedObject = virt.SharedObject;
const PinState = OwnedObject.PinState;

// --- mem/virt/Space.zig --- //

const Space = @This();

const Map = utils.SlotMap(utils.Arc(Space));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

pub var map: Map = .{};

pub const Error = error{
    InvalidRange,
    OutOfBounds,
    Overlaps,
    NotFound,
    OutOfMemory,
    ProtectedRegion,
    InvalidArgs,
    PermissionDenied,
    PinnedObject,
    WriteXorExecute,
    ViewClosed,
};

pub const Half = enum {
    low,
    high,

    pub inline fn minVa(self: Half) u64 {
        return switch (self) {
            .low => 64 * 1024, // Never auto-allocate the null page
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
        const min_allowed: u64 = switch (self) {
            .low => 0,
            .high => kernel.arch.paging.high_half_min,
        };
        return base_va >= min_allowed and end_inclusive <= self.maxVa();
    }
};

half: Half,
lock: utils.RwLock,
page_table: paging.PageTable,
first_node: ?*Node,
/// Lowest potentially unallocated VA >= `half.minVa()` to avoid $O(N)$ scans from the start of the space.
free_hint_va: u64,

pub fn init(half: Half) !Space {
    return .{
        .half = half,
        .lock = .{},
        .page_table = try .init(null),
        .first_node = null,
        .free_hint_va = half.minVa(),
    };
}

pub fn SlotMap_deinit(self: *Space) void {
    if (comptime @import("builtin").cpu.arch == .riscv64) {
        if (self.half == .low) {
            kernel.arch.paging.cleanLowHalfRoot(self.page_table.root_pa);
        }
    }
    self.page_table.deinit();

    var current = self.first_node;
    while (current) |node| {
        const next = node.next;
        node.destroy();
        current = next;
    }
    self.first_node = null;
}

pub const RegionSnapshot = struct {
    base_va: u64,
    end_va: u64,
    owner: virt.View.Id,
    has_guards: bool,
    permissions: paging.Permissions,
    pinned: bool,
};

pub fn get(self: *Space, va: u64) ?RegionSnapshot {
    if (va > self.half.maxVa()) return null;

    const int_state = self.lock.acquire(.read, 0);
    defer self.lock.release(.read, int_state);

    const reg = self.findRegionLocked(va) orelse return null;
    return reg.snapshot();
}

pub fn getForView(self: *Space, owner: virt.View.Id, va: u64) ?RegionSnapshot {
    if (va > self.half.maxVa()) return null;

    const int_state = self.lock.acquire(.read, 0);
    defer self.lock.release(.read, int_state);

    const reg = self.findRegionLocked(va) orelse return null;
    if (reg.owner != owner) return null;
    return reg.snapshot();
}

pub fn releaseTarget(target: RegionTarget) void {
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

fn validateTargetAndPerms(target: RegionTarget, with_guards: bool) !paging.Permissions {
    if (with_guards and target == .guard) return Error.InvalidArgs;

    return switch (target) {
        .guard => .{
            .writable = false,
            .executable = false,
            .user = false,
            .global = false,
        },
        .owned => |ref| blk: {
            const perms = ref.payload().permissions;
            if (perms.writable and perms.executable) return Error.WriteXorExecute;
            break :blk perms;
        },
        .shared => |ref| blk: {
            const shared = ref.payload();
            const perms = shared.permissions;
            const owner_perms = shared.object.payload().permissions;
            if (perms.writable and perms.executable) return Error.WriteXorExecute;
            if ((perms.writable and !owner_perms.writable) or
                (perms.executable and !owner_perms.executable))
            {
                return Error.PermissionDenied;
            }
            break :blk perms;
        },
    };
}

pub fn allocForView(
    self: *Space,
    owner: virt.View.Id,
    size: u64,
    target: RegionTarget,
    with_guards: bool,
    min_va: u64,
) !u64 {
    errdefer releaseTarget(target);

    if (owner.isNull()) return Error.InvalidArgs;
    if (size == 0 or size % paging.page_size != 0) return Error.InvalidRange;

    const perms = try validateTargetAndPerms(target, with_guards);
    const guard_overhead: u64 = if (with_guards) 2 * paging.page_size else 0;
    const total_size = std.math.add(u64, size, guard_overhead) catch return Error.InvalidRange;

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    const reserved_base = self.findFreeSpaceLocked(total_size, min_va) orelse return Error.OutOfMemory;
    const payload_start = if (with_guards) reserved_base + paging.page_size else reserved_base;
    const payload_end = payload_start + size;

    const kind: Region.Kind = switch (target) {
        .owned => |ref| .{ .owned = .{ .ref = ref, .has_guards = with_guards } },
        .shared => |ref| .{ .shared = .{ .ref = ref, .has_guards = with_guards } },
        .guard => .guard,
    };

    const region = Region{
        .base_va = payload_start,
        .end_va = payload_end,
        .owner = owner,
        .has_guards = with_guards,
        .permissions = perms,
        .kind = kind,
    };

    const inserted = try self.insertLocked(region);
    errdefer _ = self.removeEntryLocked(payload_start);

    try inserted.submitMapping(&self.page_table);

    if (reserved_base == self.free_hint_va) {
        self.free_hint_va = inserted.reservedEnd();
    }

    return payload_start;
}

pub fn mapAtForView(
    self: *Space,
    owner: virt.View.Id,
    base_va: u64,
    end_va: u64,
    target: RegionTarget,
    with_guards: bool,
) !void {
    errdefer releaseTarget(target);

    if (owner.isNull()) return Error.InvalidArgs;
    if (end_va <= base_va) return Error.InvalidRange;
    if (base_va % paging.page_size != 0 or end_va % paging.page_size != 0) return Error.InvalidRange;

    const perms = try validateTargetAndPerms(target, with_guards);

    const kind: Region.Kind = switch (target) {
        .owned => |ref| .{ .owned = .{ .ref = ref, .has_guards = with_guards } },
        .shared => |ref| .{ .shared = .{ .ref = ref, .has_guards = with_guards } },
        .guard => .guard,
    };

    const region = Region{
        .base_va = base_va,
        .end_va = end_va,
        .owner = owner,
        .has_guards = with_guards,
        .permissions = perms,
        .kind = kind,
    };

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    const inserted = try self.insertLocked(region);
    errdefer _ = self.removeEntryLocked(base_va);

    try inserted.submitMapping(&self.page_table);
}

pub fn removeForView(self: *Space, owner: virt.View.Id, base_va: u64) !void {
    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    const reg_ptr = self.findRegionByBaseLocked(base_va) orelse return Error.NotFound;

    if (reg_ptr.owner != owner) return Error.PermissionDenied;
    if (reg_ptr.isPinned()) return Error.PinnedObject;

    try reg_ptr.pin_state.beginExclusive();

    reg_ptr.unmapRegion(&self.page_table) catch |err| {
        reg_ptr.pin_state.endExclusive();
        return err;
    };

    const reserved_start = reg_ptr.reservedStart();
    if (reserved_start < self.free_hint_va and reserved_start >= self.half.minVa()) {
        self.free_hint_va = reserved_start;
    }

    var removed = self.removeEntryLocked(base_va) orelse unreachable;
    removed.releaseResources(false);
}

pub fn protectForView(self: *Space, owner: virt.View.Id, base_va: u64, new_perms: paging.Permissions) !void {
    if (new_perms.writable and new_perms.executable) return Error.WriteXorExecute;

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    const reg_ptr = self.findRegionByBaseLocked(base_va) orelse return Error.NotFound;

    if (reg_ptr.owner != owner) return Error.PermissionDenied;
    if (reg_ptr.kind == .guard) return Error.ProtectedRegion;
    if (reg_ptr.isPinned()) return Error.PinnedObject;

    switch (reg_ptr.kind) {
        .owned => |*o| {
            const obj = o.ref.payload();
            if (obj.isPinned()) return Error.PinnedObject;
        },
        .shared => |*s| {
            const shared = s.ref.payload();
            if (shared.isPinned()) return Error.PinnedObject;
            const max_p = shared.permissions;
            if ((new_perms.writable and !max_p.writable) or
                (new_perms.executable and !max_p.executable) or
                (new_perms.user and !max_p.user))
            {
                return Error.PermissionDenied;
            }
        },
        .guard => unreachable,
    }

    try reg_ptr.pin_state.beginExclusive();
    defer reg_ptr.pin_state.endExclusive();

    const old_perms = reg_ptr.permissions;
    reg_ptr.permissions = new_perms;
    errdefer reg_ptr.permissions = old_perms;

    try reg_ptr.submitMapping(&self.page_table);
}

pub fn removeAllForView(self: *Space, owner: virt.View.Id, force: bool) !void {
    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    if (!force) {
        var scan = self.first_node;
        while (scan) |node| : (scan = node.next) {
            for (node.regions[0..node.len]) |*reg| {
                if (reg.owner == owner and reg.isPinned()) {
                    return Error.PinnedObject;
                }
            }
        }
    }

    var prev: ?*Node = null;
    var current = self.first_node;

    while (current) |node| {
        var write_idx: usize = 0;

        for (0..node.len) |read_idx| {
            var reg = &node.regions[read_idx];
            if (reg.owner == owner) {
                const r_start = reg.reservedStart();
                if (r_start < self.free_hint_va and r_start >= self.half.minVa()) {
                    self.free_hint_va = r_start;
                }

                reg.unmapRegion(&self.page_table) catch {};
                reg.releaseResources(false);
            } else {
                if (write_idx != read_idx) {
                    node.regions[write_idx] = reg.*;
                }
                write_idx += 1;
            }
        }

        node.len = write_idx;

        if (node.len == 0) {
            const next = node.next;
            if (prev) |p| {
                p.next = next;
            } else {
                self.first_node = next;
            }
            node.destroyEmpty();
            current = next;
        } else {
            node.updateBounds();
            if (prev) |p| {
                if (p.tryMergeWithNext()) {
                    current = p.next;
                    continue;
                }
            }
            prev = node;
            current = node.next;
        }
    }
}

pub fn pinRangeForView(
    self: *Space,
    owner: virt.View.Id,
    va: u64,
    size: u64,
    required_perms: paging.Permissions,
) !void {
    if (size == 0) return Error.InvalidRange;
    const start_va = std.mem.alignBackward(u64, va, paging.page_size);
    const end_raw = std.math.add(u64, va, size) catch return Error.InvalidRange;
    const end_va = std.mem.alignForward(u64, end_raw, paging.page_size);

    const int_state = self.lock.acquire(.read, 0);
    defer self.lock.release(.read, int_state);

    var cursor = start_va;
    while (cursor < end_va) {
        const reg = self.findRegionLocked(cursor) orelse return Error.NotFound;
        if (reg.owner != owner) return Error.PermissionDenied;
        if (reg.kind == .guard) return Error.ProtectedRegion;
        if (!reg.satisfiesPermissions(required_perms)) return Error.PermissionDenied;
        cursor = reg.end_va;
    }

    cursor = start_va;
    errdefer self.unpinRangeUpToLocked(start_va, cursor);

    while (cursor < end_va) {
        const reg = self.findRegionLocked(cursor).?;
        try reg.pin();
        cursor = reg.end_va;
    }
}

pub fn unpinRangeForView(self: *Space, owner: virt.View.Id, va: u64, size: u64) void {
    if (size == 0) return;
    const start_va = std.mem.alignBackward(u64, va, paging.page_size);
    const end_raw = std.math.add(u64, va, size) catch return;
    const end_va = std.mem.alignForward(u64, end_raw, paging.page_size);

    const int_state = self.lock.acquire(.read, 0);
    defer self.lock.release(.read, int_state);

    var cursor = start_va;
    while (cursor < end_va) {
        const reg = self.findRegionLocked(cursor) orelse break;
        if (reg.owner == owner) {
            reg.unpin();
        }
        cursor = reg.end_va;
    }
}

fn unpinRangeUpToLocked(self: *Space, start_va: u64, stop_va: u64) void {
    var cursor = start_va;
    while (cursor < stop_va) {
        const reg = self.findRegionLocked(cursor) orelse break;
        reg.unpin();
        cursor = reg.end_va;
    }
}

fn findRegionLocked(self: *const Space, va: u64) ?*Region {
    var current = self.first_node;
    while (current) |node| : (current = node.next) {
        if (node.len == 0) continue;
        if (va < node.min_va) return null;
        if (va < node.max_va) {
            return node.getPayload(va);
        }
    }
    return null;
}

fn findRegionByBaseLocked(self: *const Space, base_va: u64) ?*Region {
    var current = self.first_node;
    while (current) |node| : (current = node.next) {
        if (node.len == 0) continue;
        if (base_va < node.min_va) return null;
        if (base_va < node.max_va) {
            if (node.getPayload(base_va)) |reg| {
                if (reg.base_va == base_va) return reg;
            }
            return null;
        }
    }
    return null;
}

fn findFreeSpaceLocked(self: *Space, total_size: u64, min_va: u64) ?u64 {
    if (min_va > self.half.maxVa()) return null;

    const baseline = @max(min_va, self.half.minVa());
    const start_hint = if (baseline <= self.free_hint_va) self.free_hint_va else baseline;
    var current_va = std.mem.alignForward(u64, start_hint, paging.page_size);
    if (current_va < baseline) return null; // Overflow during alignment

    var current = self.first_node;
    while (current) |node| : (current = node.next) {
        if (node.len == 0 or node.max_va <= current_va) continue;

        const start_idx = node.lowerBoundEnd(current_va);
        for (start_idx..node.len) |i| {
            const reg = &node.regions[i];
            const reg_start = reg.reservedStart();
            const reg_end = reg.reservedEnd();

            const candidate_end = std.math.add(u64, current_va, total_size) catch return null;
            if (candidate_end <= reg_start) {
                return current_va;
            }

            if (reg_end > current_va) {
                current_va = std.mem.alignForward(u64, reg_end, paging.page_size);
                if (current_va < reg_end) return null; // Wrapped around u64::MAX
            }
        }
    }

    const final_end = std.math.add(u64, current_va, total_size - 1) catch return null;
    if (final_end <= self.half.maxVa()) {
        return current_va;
    }

    return null;
}

fn insertLocked(self: *Space, region: Region) !*Region {
    const r_start = region.reservedStart();
    const r_end = region.reservedEnd();

    if (r_start > region.base_va or r_end < region.end_va) return Error.OutOfBounds;
    if (!self.half.contains(r_start, r_end)) return Error.OutOfBounds;

    if (self.first_node == null) {
        const node = try Node.create();
        node.regions[0] = region;
        node.len = 1;
        node.updateBounds();
        self.first_node = node;
        return &node.regions[0];
    }

    var prev: ?*Node = null;
    var current = self.first_node.?;

    while (current.next != null and r_start >= current.max_va) {
        prev = current;
        current = current.next.?;
    }

    const idx = current.lowerBoundStart(r_start);

    if (idx > 0) {
        if (current.regions[idx - 1].reservedEnd() > r_start) return Error.Overlaps;
    } else if (prev) |p| {
        if (p.regions[p.len - 1].reservedEnd() > r_start) return Error.Overlaps;
    }

    if (idx < current.len) {
        if (current.regions[idx].reservedStart() < r_end) return Error.Overlaps;
    } else if (current.next) |n| {
        if (n.regions[0].reservedStart() < r_end) return Error.Overlaps;
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

        current.updateBounds();
        new_node.updateBounds();

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
    target_node.updateBounds();

    return &target_node.regions[target_idx];
}

fn removeEntryLocked(self: *Space, base_va: u64) ?Region {
    var prev: ?*Node = null;
    var current = self.first_node;

    while (current) |node| {
        if (node.len > 0 and base_va >= node.min_va and base_va < node.max_va) {
            if (node.findIndexByBase(base_va)) |i| {
                const removed = node.regions[i];

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
                    node.destroyEmpty();
                } else {
                    node.updateBounds();
                    _ = node.tryMergeWithNext();
                    if (prev) |p| {
                        _ = p.tryMergeWithNext();
                    }
                }
                return removed;
            }
            return null;
        }
        prev = current;
        current = node.next;
    }
    return null;
}

pub const FaultResult = enum {
    /// The page was `.uncommitted` and has now been backed by a zeroed physical page and committed.
    resolved,
    /// The fault hit a `.guard` page (e.g. stack overflow).
    guard_violation,
    /// The address is not mapped in the page table.
    unmapped,
    /// The page is already `.committed` (permission violation) or belongs to another `View`.
    access_violation,
    /// Physical memory exhausted while attempting to commit the page.
    out_of_memory,
};

pub fn handlePageFaultForView(self: *Space, _: virt.View.Id, fault_va: u64) FaultResult {
    if (!kernel.arch.paging.isCanonical(fault_va)) return .unmapped;

    const page_va = std.mem.alignBackward(u64, fault_va, paging.page_size);
    if (!self.half.contains(page_va, page_va + paging.page_size)) return .unmapped;

    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    var query = paging.Query{
        .virtual_address = page_va,
        .batch_size = 1,
        .level = 0,
    };
    self.page_table.submit(&query) catch return .unmapped;

    const state = query.state orelse return .unmapped;
    switch (state) {
        .guard => return .guard_violation,
        .unmapped => return .unmapped,
        .committed => return .access_violation,
        .uncommitted => {},
    }

    if (query.level == 0) {
        if (query.permissions) |perms| {
            if (!perms.writable and !perms.executable) return .access_violation;
        }
    }

    const reg = self.findRegionLocked(page_va) orelse return .unmapped;
    if (reg.kind == .guard) return .guard_violation;
    if (!reg.permissions.writable and !reg.permissions.executable) return .access_violation;

    const obj: *OwnedObject = switch (reg.kind) {
        .owned => |*o| o.ref.payload(),
        .shared => |*s| s.ref.payload().object.payload(),
        .guard => unreachable,
    };

    var target_pa: u64 = 0;
    {
        const obj_int = obj.lock.acquire(.write, 0);
        defer obj.lock.release(.write, obj_int);

        switch (obj.physical_mapping) {
            .non_contiguous => |*list| {
                const page_idx: usize = @intCast((page_va - reg.base_va) / paging.page_size);
                const pa_slot = list.getPtr(page_idx) orelse return .unmapped;

                if (pa_slot.* == 0) {
                    const new_pa = phys.allocPage() catch return .out_of_memory;
                    @memset(mem.toHhdm([paging.page_size]u8, new_pa), 0);
                    pa_slot.* = new_pa;
                }
                target_pa = pa_slot.*;
            },
            .contiguous => |base_pa| {
                target_pa = base_pa + (page_va - reg.base_va);
            },
        }
    }

    var commit_query = paging.Query{
        .virtual_address = page_va,
        .physical_address = target_pa,
        .batch_size = 1,
        .state = .committed,
        .level = 0,
    };
    self.page_table.submit(&commit_query) catch return .out_of_memory;

    return .resolved;
}

const Node = struct {
    const HEADER_SIZE = @sizeOf(?*Node) + @sizeOf(usize) + (@sizeOf(u64) * 2);
    const CAPACITY = (paging.page_size - HEADER_SIZE) / @sizeOf(Region);

    next: ?*Node = null,
    len: usize = 0,
    min_va: u64 = 0,
    max_va: u64 = 0,
    regions: [CAPACITY]Region = undefined,

    pub fn create() !*Node {
        const pa = try phys.allocPage();
        const node = mem.toHhdm(Node, pa);
        node.next = null;
        node.len = 0;
        node.min_va = 0;
        node.max_va = 0;
        return node;
    }

    pub inline fn updateBounds(self: *Node) void {
        if (self.len == 0) {
            self.min_va = 0;
            self.max_va = 0;
        } else {
            self.min_va = self.regions[0].reservedStart();
            self.max_va = self.regions[self.len - 1].reservedEnd();
        }
    }

    pub fn tryMergeWithNext(self: *Node) bool {
        const next = self.next orelse return false;
        if (self.len + next.len > CAPACITY / 2) return false;

        @memcpy(self.regions[self.len .. self.len + next.len], next.regions[0..next.len]);
        self.len += next.len;
        self.next = next.next;
        self.updateBounds();
        next.destroyEmpty();
        return true;
    }

    pub fn destroyEmpty(self: *Node) void {
        std.debug.assert(self.len == 0);
        const pa = mem.fromHhdm(Node, self);
        phys.freePage(pa);
    }

    pub fn destroy(self: *Node) void {
        for (self.regions[0..self.len]) |*region| {
            region.releaseResources(true);
        }
        self.len = 0;
        self.destroyEmpty();
    }

    pub fn getPayload(self: *Node, va: u64) ?*Region {
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

    pub fn findIndexByBase(self: *const Node, base_va: u64) ?usize {
        var left: usize = 0;
        var right: usize = self.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const reg_base = self.regions[mid].base_va;

            if (base_va < reg_base) {
                right = mid;
            } else if (base_va > reg_base) {
                left = mid + 1;
            } else {
                return mid;
            }
        }
        return null;
    }

    /// First index `i` where `regions[i].reservedStart() >= target_start`.
    pub fn lowerBoundStart(self: *const Node, target_start: u64) usize {
        var left: usize = 0;
        var right: usize = self.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.regions[mid].reservedStart() < target_start) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }

    /// First index `i` where `regions[i].reservedEnd() > target_va`.
    pub fn lowerBoundEnd(self: *const Node, target_va: u64) usize {
        var left: usize = 0;
        var right: usize = self.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.regions[mid].reservedEnd() <= target_va) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }
};

pub const RegionTarget = union(enum) {
    guard,
    owned: OwnedObject.Ref,
    shared: SharedObject.Ref,
};

pub fn SlotMap_updateHhdm(self: *Space) void {
    var current_ptr: *?*Node = &self.first_node;
    var current = self.first_node;
    while (current) |node| {
        const next_old = node.next;

        for (node.regions[0..node.len]) |*region| {
            switch (region.kind) {
                .guard => {},
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
        current = next_old;
    }
}

pub const Region = struct {
    base_va: u64,
    end_va: u64,
    owner: virt.View.Id,
    has_guards: bool = false,
    permissions: paging.Permissions,
    kind: Kind,
    pin_state: PinState = .{},

    pub const Kind = union(enum) {
        guard,
        owned: struct {
            ref: OwnedObject.Ref,
            has_guards: bool,
        },
        shared: struct {
            ref: SharedObject.Ref,
            has_guards: bool,
        },
    };

    pub inline fn reservedStart(self: *const Region) u64 {
        return if (self.has_guards) self.base_va - paging.page_size else self.base_va;
    }

    pub inline fn reservedEnd(self: *const Region) u64 {
        return if (self.has_guards) self.end_va + paging.page_size else self.end_va;
    }

    pub inline fn isPinned(self: *const Region) bool {
        if (self.pin_state.isPinned()) return true;
        return switch (self.kind) {
            .guard => false,
            .owned => |*o| o.ref.payload().isPinned(),
            .shared => |*s| s.ref.payload().isPinned(),
        };
    }

    pub inline fn pin(self: *Region) !void {
        try self.pin_state.pin();
        errdefer self.pin_state.unpin();

        switch (self.kind) {
            .guard => return Error.ProtectedRegion,
            .owned => |*o| try o.ref.payload().pin(),
            .shared => |*s| try s.ref.payload().pin(),
        }
    }

    pub inline fn unpin(self: *Region) void {
        switch (self.kind) {
            .guard => {},
            .owned => |*o| o.ref.payload().unpin(),
            .shared => |*s| s.ref.payload().unpin(),
        }
        self.pin_state.unpin();
    }

    pub inline fn satisfiesPermissions(self: *const Region, req: paging.Permissions) bool {
        if (req.writable and !self.permissions.writable) return false;
        if (req.executable and !self.permissions.executable) return false;
        if (req.user and !self.permissions.user) return false;
        return true;
    }

    pub inline fn snapshot(self: *const Region) RegionSnapshot {
        return .{
            .base_va = self.base_va,
            .end_va = self.end_va,
            .owner = self.owner,
            .has_guards = self.has_guards,
            .permissions = self.permissions,
            .pinned = self.isPinned(),
        };
    }

    pub fn releaseResources(self: *Region, destroy_objects: bool) void {
        switch (self.kind) {
            .guard => {},
            .owned => |*ow| {
                if (destroy_objects) ow.ref.payload().destroy();
                ow.ref.release();
            },
            .shared => |*sw| {
                if (destroy_objects) sw.ref.payload().destroy();
                sw.ref.release();
            },
        }
    }

    pub fn submitMapping(self: *const Region, page_table: *paging.PageTable) !void {
        if (self.has_guards) {
            var guard_low = paging.Query{
                .virtual_address = self.base_va - paging.page_size,
                .physical_address = null,
                .batch_size = 1,
                .state = .guard,
                .permissions = null,
                .mem_type = null,
                .level = null,
            };
            try page_table.submit(&guard_low);
        }
        errdefer if (self.has_guards) {
            var rollback_low = paging.Query{
                .virtual_address = self.base_va - paging.page_size,
                .physical_address = null,
                .batch_size = 1,
                .state = .unmapped,
                .permissions = null,
                .mem_type = null,
                .level = null,
            };
            page_table.submit(&rollback_low) catch {};
        };

        switch (self.kind) {
            .guard => {
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
                try self.submitObjectMapping(page_table, obj, self.permissions);
            },
            .shared => |*s| {
                const shared_obj = s.ref.payload();
                const obj = shared_obj.object.payload();
                try self.submitObjectMapping(page_table, obj, self.permissions);
            },
        }
        errdefer {
            var rollback_main = paging.Query{
                .virtual_address = self.base_va,
                .physical_address = null,
                .batch_size = @intCast((self.end_va - self.base_va) / paging.page_size),
                .state = .unmapped,
                .permissions = null,
                .mem_type = null,
                .level = null,
            };
            page_table.submit(&rollback_main) catch {};
        }

        if (self.has_guards) {
            var guard_high = paging.Query{
                .virtual_address = self.end_va,
                .physical_address = null,
                .batch_size = 1,
                .state = .guard,
                .permissions = null,
                .mem_type = null,
                .level = null,
            };
            try page_table.submit(&guard_high);
        }
    }

    inline fn submitObjectMapping(
        self: *const Region,
        page_table: *paging.PageTable,
        obj: *OwnedObject,
        perms: paging.Permissions,
    ) !void {
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
                batch_size = (self.end_va - self.base_va) / paging.page_size;
            },
        }

        if (batch_size > 0) {
            try submitBatch(page_table, batch_start_va, current_pa, batch_size, is_uncommitted, perms, mtype);
        }
    }

    inline fn submitBatch(
        page_table: *paging.PageTable,
        va: u64,
        pa: ?u64,
        count: usize,
        is_uncommitted: bool,
        perms: paging.Permissions,
        mtype: paging.MemType,
    ) !void {
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
        const start = self.reservedStart();
        const end = self.reservedEnd();
        var query = paging.Query{
            .virtual_address = start,
            .physical_address = null,
            .batch_size = @intCast((end - start) / paging.page_size),
            .state = .unmapped,
            .permissions = null,
            .mem_type = null,
            .level = null,
        };
        try page_table.submit(&query);
    }
};
