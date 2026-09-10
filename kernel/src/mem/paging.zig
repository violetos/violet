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
const build_options = @import("build_options");

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;

const mem = kernel.mem;
const paging = mem.paging;
const phys = mem.phys;

// --- mem/paging.zig --- //

pub const Error = error{
    /// The range is empty or overflows the canonical address space.
    OutOfBounds,
    /// `virtual_address` is not aligned to the unit of `level`.
    Misaligned,
    /// A field required by the requested state transition is absent,
    /// or a field incompatible with the target state is provided.
    MissingFields,
    /// The requested state transition is not allowed.
    InvalidStateTransition,
};

pub const MemType = enum {
    writeback,
    write_combining,
    device,
};

pub const Permissions = struct {
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    global: bool = false,
};

pub const State = enum {
    unmapped,
    uncommitted,
    committed,
    guard,
};

pub const Attributes = struct {
    permissions: Permissions,
    mem_type: MemType,
};

pub const Leaf = struct {
    physical_address: u64,
    attributes: Attributes,
};

pub const Entry = union(enum) {
    unmapped,
    uncommitted: Attributes,
    guard,
    table: u64,
    leaf: Leaf,
};

pub const Level = u8;

pub const page_size: u64 = build_options.page_size * 1024;
pub const page_levels: u8 = build_options.page_levels;

pub const entries_per_table: u64 = page_size / @sizeOf(u64);
pub const bits_per_level: u64 = std.math.log2_int(u64, entries_per_table);
pub const offset_bits: u64 = std.math.log2_int(u64, page_size);

pub const va_bits: u6 = @intCast(paging.offset_bits + (paging.page_levels * paging.bits_per_level));

comptime {
    if (va_bits > 48) @compileError("doesn't support VA greather than 48 bits.");

    std.debug.assert(std.math.isPowerOfTwo(entries_per_table));
    std.debug.assert(offset_bits + (page_levels - 1) * bits_per_level < 64);
}

inline fn levelShift(level: Level) u6 {
    return @intCast(offset_bits + @as(u64, level) * bits_per_level);
}

pub inline fn levelSize(level: Level) u64 {
    return @as(u64, 1) << levelShift(level);
}

inline fn levelIndex(va: u64, level: Level) usize {
    return @intCast((va >> levelShift(level)) & (entries_per_table - 1));
}

inline fn tableSlice(table_pa: u64) []u64 {
    return mem.toHhdm([entries_per_table]u64, table_pa)[0..];
}

inline fn physPagesFor(level: Level) u64 {
    return levelSize(level) / page_size;
}

pub const Query = struct {
    virtual_address: u64,
    physical_address: ?u64 = null,
    batch_size: ?usize = null,

    state: ?State = null,
    permissions: ?Permissions = null,
    mem_type: ?MemType = null,
    level: ?Level = null,
};

pub const PageTable = struct {
    root_pa: u64,

    pub fn init(root_pa: ?u64) !@This() {
        if (root_pa) |pa| {
            return .{ .root_pa = pa };
        }

        const pa = try phys.allocPage();
        @memset(tableSlice(pa), 0);
        return .{ .root_pa = pa };
    }

    pub fn deinit(self: *@This()) void {
        _ = teardown(self.root_pa, page_levels - 1);
    }

    pub fn submit(self: *@This(), query: *Query) !void {
        const level_hint: Level = query.level orelse 0;
        const unit_size = levelSize(level_hint);
        const count = query.batch_size orelse 1;

        if (count == 0) return Error.OutOfBounds;
        if (query.virtual_address % unit_size != 0) return Error.Misaligned;

        const total_size = std.math.mul(u64, unit_size, count) catch return Error.OutOfBounds;
        const end_va = std.math.add(u64, query.virtual_address, total_size) catch return Error.OutOfBounds;
        if (!arch.paging.isCanonical(query.virtual_address) or !arch.paging.isCanonical(end_va -| 1))
            return Error.OutOfBounds;

        const is_write = query.state != null or query.permissions != null or
            query.mem_type != null or query.physical_address != null;

        var acc_state: ?State = null;
        var acc_perms: ?Permissions = null;
        var acc_mem_type: ?MemType = null;
        var acc_level: ?Level = null;
        var acc_phys: ?u64 = null;
        var first_state = true;
        var first_perms = true;
        var first_mem_type = true;
        var first_level = true;
        var first_phys = true;

        const flush_all_threshold = 33;
        var flush_buf: [flush_all_threshold]FlushScope = undefined;
        var flush_len: usize = 0;
        var flush_all = false;

        var va = query.virtual_address;
        var remaining = total_size;

        while (remaining > 0) {
            const off = va - query.virtual_address;
            var step: u64 = undefined;
            var seen: Entry = undefined;
            var seen_level: Level = undefined;

            if (is_write) {
                const target_pa: ?u64 = if (query.physical_address) |base| base + off else null;
                var target_level = chooseLevel(va, remaining, target_pa, level_hint);
                var result = try walk(self, va, target_level, .write);

                var target_state = query.state orelse currentStateOf(result.entry);

                while (result.entry == .table and target_state == .committed and target_pa == null) {
                    std.debug.assert(target_level > 0);
                    target_level -= 1;
                    result = try walk(self, va, target_level, .write);
                    target_state = query.state orelse currentStateOf(result.entry);
                }

                const new_entry = try nextEntry(query, result.level, result.entry, target_pa);

                var old_had_global = false;
                switch (result.entry) {
                    .table => |child_pa| old_had_global = teardown(child_pa, result.level - 1),
                    .leaf => |old_leaf| {
                        old_had_global = old_leaf.attributes.permissions.global;
                        const reused = switch (new_entry) {
                            .leaf => |new_leaf| new_leaf.physical_address == old_leaf.physical_address,
                            else => false,
                        };
                        if (!reused) {
                            invalidateLeaf(result.table_pa, result.index, result.level, old_leaf, va);
                        }
                    },
                    else => {},
                }

                tableSlice(result.table_pa)[result.index] = arch.paging.encode(result.level, new_entry);

                if (needsFlush(result.entry, new_entry)) {
                    const new_global = switch (new_entry) {
                        .leaf => |l| l.attributes.permissions.global,
                        else => false,
                    };
                    if (flush_len < flush_all_threshold) {
                        flush_buf[flush_len] = .{ .address = .{
                            .va = va,
                            .level = result.level,
                            .global = old_had_global or new_global,
                        } };
                        flush_len += 1;
                    } else {
                        flush_all = true;
                    }
                }

                seen = new_entry;
                seen_level = result.level;
                step = levelSize(result.level);
            } else {
                const result = try walk(self, va, level_hint, .read);
                seen = result.entry;
                seen_level = result.level;
                const leaf_size = levelSize(result.level);
                step = @min(remaining, leaf_size - (va % leaf_size));
            }

            accumulate(Level, &acc_level, &first_level, seen_level);
            switch (seen) {
                .unmapped => {
                    accumulate(State, &acc_state, &first_state, .unmapped);
                    poison(u64, &acc_phys, &first_phys);
                    poison(Permissions, &acc_perms, &first_perms);
                    poison(MemType, &acc_mem_type, &first_mem_type);
                },
                .guard => {
                    accumulate(State, &acc_state, &first_state, .guard);
                    poison(u64, &acc_phys, &first_phys);
                    poison(Permissions, &acc_perms, &first_perms);
                    poison(MemType, &acc_mem_type, &first_mem_type);
                },
                .uncommitted => |attrs| {
                    accumulate(State, &acc_state, &first_state, .uncommitted);
                    accumulate(Permissions, &acc_perms, &first_perms, attrs.permissions);
                    accumulate(MemType, &acc_mem_type, &first_mem_type, attrs.mem_type);
                    poison(u64, &acc_phys, &first_phys);
                },
                .leaf => |leaf| {
                    accumulate(State, &acc_state, &first_state, .committed);
                    accumulate(Permissions, &acc_perms, &first_perms, leaf.attributes.permissions);
                    accumulate(MemType, &acc_mem_type, &first_mem_type, leaf.attributes.mem_type);
                    accumulate(u64, &acc_phys, &first_phys, leaf.physical_address - off);
                },
                .table => unreachable,
            }

            va += step;
            remaining -= step;
        }

        if (is_write) {
            if (flush_all) {
                arch.paging.flush(.all);
            } else {
                for (flush_buf[0..flush_len]) |scope| arch.paging.flush(scope);
            }
        }

        query.state = acc_state;
        query.permissions = acc_perms;
        query.mem_type = acc_mem_type;
        query.level = acc_level;
        query.physical_address = acc_phys;
    }
};

const WalkMode = enum { read, write };

const WalkResult = struct {
    level: Level,
    table_pa: u64,
    index: usize,
    entry: Entry,
};

fn walk(self: *PageTable, va: u64, target_level: Level, mode: WalkMode) !WalkResult {
    std.debug.assert(target_level < page_levels);

    var table_pa = self.root_pa;
    var level: Level = page_levels - 1;

    while (true) {
        const idx = levelIndex(va, level);
        const raw = tableSlice(table_pa)[idx];
        const entry = arch.paging.decode(level, raw);

        if (level == target_level and !(mode == .read and entry == .table)) {
            return .{ .level = level, .table_pa = table_pa, .index = idx, .entry = entry };
        }

        switch (entry) {
            .table => |child_pa| {
                std.debug.assert(level > 0);
                table_pa = child_pa;
                level -= 1;
            },
            else => switch (mode) {
                .read => return .{ .level = level, .table_pa = table_pa, .index = idx, .entry = entry },
                .write => {
                    table_pa = switch (entry) {
                        .leaf, .guard, .uncommitted => try demote(va, table_pa, idx, level, entry),
                        .unmapped => try createChildTable(table_pa, idx, level),
                        .table => unreachable,
                    };
                    level -= 1;
                },
            },
        }
    }
}

fn chooseLevel(va: u64, remaining: u64, phys_addr: ?u64, hint: Level) Level {
    var level: Level = page_levels - 1;
    while (level > 0) : (level -= 1) {
        if (!arch.paging.canMapAt(level)) continue;
        if (va % levelSize(level) != 0) continue;
        if (remaining < levelSize(level)) continue;
        if (phys_addr) |pa| {
            if (pa % levelSize(level) != 0) continue;
        }
        if (phys_addr != null and level > hint) continue;
        return level;
    }
    return 0;
}

inline fn createChildTable(parent_pa: u64, idx: usize, parent_level: Level) !u64 {
    std.debug.assert(parent_level > 0);

    const child_pa = try phys.allocPage();
    @memset(tableSlice(child_pa), 0);

    arch.cpu.syncStores();
    tableSlice(parent_pa)[idx] = arch.paging.encode(parent_level, .{ .table = child_pa });
    return child_pa;
}

inline fn invalidateLeaf(table_pa: u64, idx: usize, level: Level, leaf: Leaf, va: u64) void {
    tableSlice(table_pa)[idx] = arch.paging.encode(level, .unmapped);
    const base_va = va & ~(levelSize(level) - 1);
    arch.paging.flush(.{ .address = .{
        .va = base_va,
        .level = level,
        .global = leaf.attributes.permissions.global,
    } });
}

inline fn demote(va: u64, parent_pa: u64, idx: usize, level: Level, entry: Entry) !u64 {
    std.debug.assert(level > 0);

    if (entry == .leaf) invalidateLeaf(parent_pa, idx, level, entry.leaf, va);

    const child_level = level - 1;
    const child_pa = try phys.allocPage();
    const child = tableSlice(child_pa);
    const sub_size = levelSize(child_level);

    for (0..entries_per_table) |i| {
        const child_entry: Entry = switch (entry) {
            .leaf => |leaf| .{ .leaf = .{
                .physical_address = leaf.physical_address + i * sub_size,
                .attributes = leaf.attributes,
            } },
            .uncommitted => |attrs| .{ .uncommitted = attrs },
            .guard => .guard,
            else => unreachable,
        };
        child[i] = arch.paging.encode(child_level, child_entry);
    }

    arch.cpu.syncStores();
    tableSlice(parent_pa)[idx] = arch.paging.encode(level, .{ .table = child_pa });

    return child_pa;
}

fn teardown(table_pa: u64, level: Level) bool {
    var had_global = false;
    for (tableSlice(table_pa)) |raw| {
        switch (arch.paging.decode(level, raw)) {
            .table => |child_pa| {
                std.debug.assert(level > 0);
                if (teardown(child_pa, level - 1)) had_global = true;
            },
            .leaf => |leaf| {
                if (leaf.attributes.permissions.global) had_global = true;
            },
            .unmapped, .uncommitted, .guard => {},
        }
    }
    phys.freePage(table_pa);
    return had_global;
}

inline fn currentStateOf(entry: Entry) State {
    return switch (entry) {
        .unmapped => .unmapped,
        .uncommitted => .uncommitted,
        .guard => .guard,
        .leaf, .table => .committed,
    };
}

inline fn isTransitionAllowed(from: State, to: State) bool {
    if (from == to) return true;

    if (from == .guard and to != .unmapped) return false;
    if (to == .guard and from != .unmapped) return false;

    return true;
}

fn nextEntry(query: *const Query, level: Level, current: Entry, target_pa: ?u64) !Entry {
    const from = currentStateOf(current);
    const to = query.state orelse from;

    if (!isTransitionAllowed(from, to)) return Error.InvalidStateTransition;

    const existing_attrs: ?Attributes = switch (current) {
        .uncommitted => |a| a,
        .leaf => |l| l.attributes,
        else => null,
    };

    return switch (to) {
        .unmapped, .guard => blk: {
            if (query.permissions != null or query.mem_type != null or query.physical_address != null)
                return Error.MissingFields;
            break :blk if (to == .unmapped) Entry.unmapped else Entry.guard;
        },
        .uncommitted => blk: {
            if (query.physical_address != null) return Error.MissingFields;
            const perms = query.permissions orelse (existing_attrs orelse return Error.MissingFields).permissions;
            const mtype = query.mem_type orelse (existing_attrs orelse return Error.MissingFields).mem_type;
            break :blk .{ .uncommitted = .{ .permissions = perms, .mem_type = mtype } };
        },
        .committed => blk: {
            if (level > 0) std.debug.assert(arch.paging.canMapAt(level));

            const perms = query.permissions orelse (existing_attrs orelse return Error.MissingFields).permissions;
            const mtype = query.mem_type orelse (existing_attrs orelse return Error.MissingFields).mem_type;

            const pa = target_pa orelse switch (current) {
                .leaf => |l| l.physical_address,
                else => try phys.allocContiguous(physPagesFor(level)),
            };

            break :blk .{ .leaf = .{
                .physical_address = pa,
                .attributes = .{ .permissions = perms, .mem_type = mtype },
            } };
        },
    };
}

inline fn needsFlush(old: Entry, new: Entry) bool {
    const old_present = switch (old) {
        .leaf, .table => true,
        else => false,
    };
    const new_present = switch (new) {
        .leaf => true,
        else => false,
    };
    return old_present or new_present;
}

inline fn accumulate(comptime T: type, acc: *?T, is_first: *bool, value: T) void {
    if (is_first.*) {
        acc.* = value;
        is_first.* = false;
        return;
    }
    if (acc.*) |current| {
        if (!std.meta.eql(current, value)) acc.* = null;
    }
}

inline fn poison(comptime T: type, acc: *?T, is_first: *bool) void {
    is_first.* = false;
    acc.* = null;
}

// --- arch/<archi>/paging.zig --- //

pub const FlushScope = union(enum) {
    all,
    address: struct {
        va: u64,
        level: Level,
        global: bool = false,
    },
};

// --- //

comptime {
    switch (build_options.page_size) {
        4, 16, 64 => {},
        else => @compileError("Invalid page_size"),
    }

    switch (build_options.page_levels) {
        3, 4, 5 => {},
        else => @compileError("Invalid page_levels"),
    }
}
