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

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const cpu = arch.cpu;

const interrupts = arch.interrupts;
const InterruptState = interrupts.InterruptState;

const mem = kernel.mem;
const phys = mem.phys;

const PAGE_SIZE = mem.paging.page_size;

// --- mem/utils.zig --- //

pub const LockMode = enum { read, write };

pub const LockState = packed struct(u32) {
    readers: u30 = 0,
    writer_gate: bool = false,
    writer_active: bool = false,
};

/// WARNING: This RwLock is non-recursive. Attempting to acquire it twice will deadlock.
pub const RwLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    const MAX_READERS = std.math.maxInt(u30);
    const WRITER_BIT = @as(u32, 1) << 31;

    pub fn tryAcquire(self: *@This(), comptime mode: LockMode) ?InterruptState {
        const prev_int = interrupts.set(.disabled);
        const raw_current = self.state.load(.monotonic);
        const current: LockState = @bitCast(raw_current);

        if (mode == .read) {
            if (!current.writer_active and !current.writer_gate) {
                if (current.readers == MAX_READERS) {
                    @branchHint(.cold);
                    @panic("RwLock: limit of readers reached in tryAcquire!");
                }

                var next = current;
                next.readers += 1;

                if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    return prev_int;
                }
            }
        } else {
            if (current.readers == 0 and !current.writer_active) {
                var next = current;
                next.writer_active = true;
                next.writer_gate = current.writer_gate;

                if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    return prev_int;
                }
            }
        }

        _ = interrupts.set(prev_int);
        return null;
    }

    pub fn acquire(self: *@This(), comptime mode: LockMode, comptime polite_spins: u16) InterruptState {
        const prev_int = interrupts.set(.disabled);
        var spins: u16 = 0;

        const _polite_spins: u16 = if (polite_spins == 0) 128 else @min(@max(polite_spins, 64), 512);

        while (true) {
            const raw_current = self.state.load(.monotonic);
            const current: LockState = @bitCast(raw_current);

            if (mode == .read) {
                if (current.writer_active or current.writer_gate) {
                    @branchHint(.unlikely);

                    cpu.pause();
                    continue;
                }

                if (current.readers == MAX_READERS) {
                    @branchHint(.cold);
                    @panic("RwLock: DEADLOCK limit of readers reached!");
                }

                var next = current;
                next.readers += 1;

                if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    @branchHint(.likely);
                    return prev_int;
                }

                if (spins < _polite_spins) {
                    cpu.pause();
                } else {
                    var i: u8 = 0;
                    const backoff_limit = @as(u8, 1) << @min(spins - _polite_spins, 6);
                    while (i < backoff_limit) : (i += 1) {
                        cpu.pause();
                    }
                }
            } else {
                if (current.writer_active or current.readers > 0) {
                    @branchHint(.unlikely);

                    if (!current.writer_gate and spins >= _polite_spins) {
                        var next = current;
                        next.writer_gate = true;
                        _ = self.state.cmpxchgWeak(raw_current, @bitCast(next), .monotonic, .monotonic);
                    }

                    if (spins < _polite_spins) {
                        cpu.pause();
                    } else {
                        var i: u8 = 0;
                        const backoff_limit = @as(u8, 1) << @min(spins - _polite_spins, 6);
                        while (i < backoff_limit) : (i += 1) {
                            cpu.pause();
                        }
                    }

                    spins +|= 1;
                    continue;
                }

                var next = current;
                next.writer_active = true;
                next.writer_gate = false;

                if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                    @branchHint(.likely);
                    return prev_int;
                }
            }
        }
    }

    pub fn release(self: *@This(), comptime mode: LockMode, saved: InterruptState) void {
        if (mode == .read) {
            const raw_prev = self.state.fetchSub(1, .release);
            const prev: LockState = @bitCast(raw_prev);

            if (prev.readers == 0) {
                @branchHint(.cold);
                @panic("RwLock: release(.read) called on an unlocked lock!");
            }

            if (prev.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: release(.read) called on an exclusive lock!");
            }
        } else {
            const raw_prev = self.state.fetchAnd(~WRITER_BIT, .release);
            const prev: LockState = @bitCast(raw_prev);

            if (!prev.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: release(.write) called but lock was not exclusive!");
            }
        }

        _ = interrupts.set(saved);
    }

    pub fn tryUpgrade(self: *@This()) bool {
        const raw_current = self.state.load(.monotonic);
        const current: LockState = @bitCast(raw_current);

        if (current.readers == 0 or current.writer_active) {
            @branchHint(.cold);
            @panic("RwLock: tryUpgrade called without a valid read lock!");
        }

        if (current.writer_gate) return false;

        if (current.readers == 1) {
            var next = current;
            next.readers = 0;
            next.writer_active = true;

            if (self.state.cmpxchgStrong(raw_current, @bitCast(next), .acquire, .monotonic) == null) {
                return true;
            }
        }

        return false;
    }

    pub fn downgrade(self: *@This()) void {
        while (true) {
            const raw_current = self.state.load(.monotonic);
            const current: LockState = @bitCast(raw_current);

            if (!current.writer_active) {
                @branchHint(.cold);
                @panic("RwLock: downgrade called but lock is not exclusive!");
            }

            var next = current;
            next.writer_active = false;
            next.readers = 1;

            if (self.state.cmpxchgWeak(raw_current, @bitCast(next), .release, .monotonic) == null) {
                @branchHint(.likely);
                break;
            }
        }
    }
};

pub fn NodeList(comptime Item: type, comptime node_size: ?usize) type {
    const NODE_SIZE = std.mem.alignForward(usize, @max(node_size orelse PAGE_SIZE, 1), PAGE_SIZE);
    const NODE_PAGECOUNT = NODE_SIZE / PAGE_SIZE;

    if (@sizeOf(Item) == 0) @compileError("Item cannot be zero-sized");
    if (@sizeOf(Item) > 4 * 1024) @compileError("Item cannot exceed 4 KiB");

    return struct {
        const NodePtr = std.atomic.Value(?*Node);
        const EntryPtr = std.atomic.Value(?[*]Item);

        const ENTRIES_PER_NODE = NODE_SIZE / @sizeOf(EntryPtr) - 1;
        const ITEMS_PER_ENTRY = PAGE_SIZE / @sizeOf(Item);

        const Node = struct {
            next_node: NodePtr,
            entries: [ENTRIES_PER_NODE]EntryPtr,

            pub fn create() !*Node {
                const node_pa = try phys.allocContiguous(NODE_PAGECOUNT);
                const node = mem.toHhdm(Node, node_pa);
                node.next_node = .init(null);

                @memset(&node.entries, .init(null));

                return node;
            }

            pub fn destroy(self: *Node) void {
                var next_node: ?*Node = self;
                while (next_node) |node| {
                    next_node = node.next_node.load(.monotonic);

                    for (&node.entries) |*entry_ptr| {
                        if (entry_ptr.load(.monotonic)) |entry| {
                            phys.freePage(mem.fromHhdm(Item, @ptrCast(entry)));
                        }
                    }

                    const node_pa = mem.fromHhdm(Node, node);
                    phys.freeContiguous(node_pa, NODE_PAGECOUNT);
                }
            }
        };

        first_node: NodePtr = .init(null),

        pub fn deinit(self: *@This()) void {
            if (self.first_node.load(.monotonic)) |first_node| {
                first_node.destroy();
            }
        }

        pub fn get(self: *@This(), index: usize) !*Item {
            const entry_global_index = index / ITEMS_PER_ENTRY;
            const item_index = index % ITEMS_PER_ENTRY;
            const node_index = entry_global_index / ENTRIES_PER_NODE;
            const entry_index = entry_global_index % ENTRIES_PER_NODE;

            var node_ptr: *NodePtr = &self.first_node;
            var node: *Node = undefined;
            var current_node_index: usize = 0;
            while (true) {
                if (node_ptr.load(.acquire)) |n| {
                    node = n;
                    node_ptr = &n.next_node;
                } else {
                    const new_node = try Node.create();

                    if (node_ptr.cmpxchgStrong(null, new_node, .acq_rel, .monotonic) == null) {
                        node = new_node;
                        node_ptr = &new_node.next_node;
                    } else {
                        new_node.destroy();
                        continue;
                    }
                }

                if (current_node_index == node_index) break;
                current_node_index += 1;
            }

            const entry_ptr = &node.entries[entry_index];
            const entry = blk: {
                while (true) {
                    if (entry_ptr.load(.acquire)) |e| {
                        break :blk e;
                    } else {
                        const new_entry_pa = try phys.allocPage();
                        const new_entry: [*]Item = @ptrCast(mem.toHhdm(Item, new_entry_pa));

                        @memset(mem.toHhdm([PAGE_SIZE]u8, new_entry_pa), 0);

                        if (entry_ptr.cmpxchgStrong(null, new_entry, .acq_rel, .monotonic) == null) {
                            break :blk new_entry;
                        } else {
                            phys.freePage(new_entry_pa);
                            continue;
                        }
                    }
                }
            };

            return &entry[item_index];
        }

        pub fn tryGet(self: *@This(), index: usize) ?*Item {
            const entry_global_index = index / ITEMS_PER_ENTRY;
            const item_index = index % ITEMS_PER_ENTRY;
            const node_index = entry_global_index / ENTRIES_PER_NODE;
            const entry_index = entry_global_index % ENTRIES_PER_NODE;

            var node = self.first_node.load(.acquire) orelse return null;
            var current_node_index: usize = 0;
            while (current_node_index != node_index) : (current_node_index += 1) {
                node = node.next_node.load(.acquire) orelse return null;
            }

            const entry = node.entries[entry_index].load(.acquire) orelse return null;
            return &entry[item_index];
        }

        pub fn updateHhdm(self: *@This()) void {
            var next_ptr = &self.first_node;
            var next_node = self.first_node.load(.monotonic);
            while (next_node) |node| {
                for (&node.entries) |*entry| {
                    if (entry.load(.monotonic)) |entry_ptr| {
                        entry.store(mem.updatePtrs(Item, entry_ptr), .monotonic);
                    }
                }

                next_ptr.store(mem.updatePtr(Node, node), .monotonic);

                next_ptr = &node.next_node;
                next_node = node.next_node.load(.monotonic);
            }
        }

        comptime {
            if (@sizeOf(EntryPtr) != 8) @compileError("NodeList.EntryPtr should be 8 B");
            if (@sizeOf(NodePtr) != 8) @compileError("NodeList.NodePtr should be 8 B");
            if (@sizeOf(Node) != NODE_SIZE) @compileError(std.fmt.comptimePrint("NodeList.Node should be {} KiB", .{NODE_SIZE / 1024}));
        }
    };
}

pub fn SlotMap(comptime Item: type) type {
    const is_arc = @hasDecl(Item, "__SlotMap__Arc");

    return struct {
        const Self = @This();

        pub const ArcRef = struct {
            map: *Self,
            item: *Item,
            index: u32,
            released: bool = false,

            pub fn release(self: *ArcRef) void {
                std.debug.assert(!self.released);
                self.released = true;
                self.map.releaseRef(self.index);
            }

            pub fn payload(self: *const ArcRef) *Item.Payload {
                std.debug.assert(!self.released);
                return &self.item.value;
            }

            pub fn clone(self: *const ArcRef) ArcRef {
                std.debug.assert(!self.released);
                _ = tryAcquire(&self.item.refcount);
                return self.*;
            }

            pub fn updateHhdm(self: *ArcRef) void {
                mem.updateRef(Self, &self.map);
                mem.updateRef(Item, &self.item);
            }
        };

        const Slot = struct {
            generation: std.atomic.Value(u32),
            next_free: std.atomic.Value(u32),
            item: Item,
        };

        const SlotList = NodeList(Slot, null);

        pub const Handle = packed struct(u64) {
            generation: u32,
            index: u32,
        };

        const FreeHead = packed struct(u64) {
            index: u32,
            tag: u32,
        };

        const SENTINEL: u32 = std.math.maxInt(u32);

        slots: SlotList = .{},
        len: std.atomic.Value(u32) = .init(0),
        free_head: std.atomic.Value(u64) = .init(@bitCast(FreeHead{ .index = SENTINEL, .tag = 0 })),

        pub fn deinit(self: *Self) void {
            self.slots.deinit();
        }

        pub fn insert(self: *Self, item: if (is_arc) Item.Payload else Item) !struct { Handle, if (is_arc) ArcRef else *Item } {
            var head: FreeHead = @bitCast(self.free_head.load(.acquire));

            while (head.index != SENTINEL) {
                const slot = self.slots.tryGet(head.index) orelse unreachable;
                const new_head: FreeHead = .{ .index = slot.next_free.load(.monotonic), .tag = head.tag +% 1 };

                if (self.free_head.cmpxchgWeak(@bitCast(head), @bitCast(new_head), .acq_rel, .acquire)) |actual| {
                    head = @bitCast(actual);
                    continue;
                }

                const freed_gen = slot.generation.load(.monotonic);
                std.debug.assert(freed_gen % 2 == 0);
                const used_gen = freed_gen +% 1;

                if (comptime is_arc) {
                    slot.item.value = item;
                    slot.item.refcount.store(1, .release);
                } else {
                    slot.item = item;
                }

                slot.generation.store(used_gen, .release);
                return .{
                    .{ .generation = used_gen, .index = head.index },
                    if (comptime is_arc) ArcRef{ .map = self, .index = head.index, .item = &slot.item } else &slot.item,
                };
            }

            const index = self.len.fetchAdd(1, .monotonic);
            const slot = try self.slots.get(index);
            if (comptime is_arc) {
                slot.item = .init(item);
            } else {
                slot.item = item;
            }
            slot.generation = .init(1);
            return .{
                .{ .generation = 1, .index = index },
                if (comptime is_arc) ArcRef{ .map = self, .index = index, .item = &slot.item } else &slot.item,
            };
        }

        fn pushFree(self: *Self, index: u32) void {
            const slot = self.slots.tryGet(index) orelse unreachable;
            var head: FreeHead = @bitCast(self.free_head.load(.acquire));
            while (true) {
                slot.next_free.store(head.index, .monotonic);
                const new_head: FreeHead = .{ .index = index, .tag = head.tag +% 1 };
                if (self.free_head.cmpxchgWeak(@bitCast(head), @bitCast(new_head), .release, .acquire)) |actual| {
                    head = @bitCast(actual);
                    continue;
                }
                return;
            }
        }

        fn enqueueFree(self: *Self, handle: Handle) void {
            const slot = self.slots.tryGet(handle.index) orelse return;
            const freed_gen = handle.generation +% 1;
            if (slot.generation.cmpxchgStrong(handle.generation, freed_gen, .release, .monotonic) != null) {
                return;
            }
            self.pushFree(handle.index);
        }

        fn releaseRef(self: *Self, index: u32) void {
            const slot = self.slots.tryGet(index) orelse return;

            const prev = slot.item.refcount.fetchSub(1, .release);
            if (prev == 1) {
                _ = slot.item.refcount.load(.acquire);

                const type_info = comptime @typeInfo(Item.Payload);
                if (type_info == .@"struct" or type_info == .@"union" or type_info == .@"enum" or type_info == .@"opaque") {
                    if (comptime @hasDecl(Item.Payload, "SlotMap_deinit")) {
                        slot.item.value.SlotMap_deinit();
                    }
                }

                _ = slot.generation.fetchAdd(1, .release);
                self.pushFree(index);
            }
        }

        inline fn tryAcquire(counter: *std.atomic.Value(u32)) bool {
            var cur = counter.load(.monotonic);
            while (true) {
                if (cur == 0) return false;
                if (counter.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                    cur = actual;
                    continue;
                }
                return true;
            }
        }

        pub fn get(self: *Self, handle: Handle) if (is_arc) ?ArcRef else ?*Item {
            if (handle.generation % 2 == 0) return null;

            const slot = self.slots.tryGet(handle.index) orelse return null;

            if (comptime is_arc) {
                if (!tryAcquire(&slot.item.refcount)) return null;

                if (slot.generation.load(.acquire) != handle.generation) {
                    self.releaseRef(handle.index);
                    return null;
                }

                return ArcRef{ .map = self, .index = handle.index, .item = &slot.item };
            } else {
                if (slot.generation.load(.acquire) != handle.generation) return null;
                return &slot.item;
            }
        }

        pub fn remove(self: *Self, handle: Handle) void {
            if (comptime is_arc) {
                @compileError("ArcRef.release() should be called");
            } else {
                self.enqueueFree(handle);
            }
        }

        pub fn updateHhdm(self: *Self) void {
            const ActualItem = if (is_arc) Item.Payload else Item;

            if (comptime @hasDecl(ActualItem, "SlotMap_updateHhdm")) {
                const max_index = self.len.load(.monotonic);
                for (0..max_index) |i| {
                    if (self.slots.tryGet(i)) |slot| {
                        if (slot.generation.load(.monotonic) % 2 != 0) {
                            if (comptime is_arc) {
                                slot.item.value.SlotMap_updateHhdm();
                            } else {
                                slot.item.SlotMap_updateHhdm();
                            }
                        }
                    }
                }
            }

            self.slots.updateHhdm();
        }
    };
}

pub fn Arc(comptime T: type) type {
    return struct {
        pub const __SlotMap__Arc = {};
        pub const Payload = T;

        refcount: std.atomic.Value(u32),
        value: T,

        pub fn init(val: T) @This() {
            return .{
                .refcount = .init(1),
                .value = val,
            };
        }
    };
}

/// Should be protected with a RwLock.
pub fn UnrolledList(comptime Item: type, comptime node_size: ?usize) type {
    const NODE_SIZE = std.mem.alignForward(usize, @max(node_size orelse PAGE_SIZE, 1), PAGE_SIZE);
    const NODE_PAGECOUNT = NODE_SIZE / PAGE_SIZE;

    if (@sizeOf(Item) == 0) @compileError("Item cannot be zero-sized");
    if (@sizeOf(Item) > 1 * 1024) @compileError("Item cannot exceed 1 KiB");

    return struct {
        const Self = @This();

        const NodePtr = ?*Node;
        const HEADER_SIZE = @sizeOf(NodePtr);
        const ITEMS_PER_NODE = (NODE_SIZE - HEADER_SIZE) / @sizeOf(Item);

        const Node = struct {
            next: NodePtr,
            items: [ITEMS_PER_NODE]Item,

            pub fn create() !*Node {
                const node_pa = try phys.allocContiguous(NODE_PAGECOUNT);
                const node = mem.toHhdm(Node, node_pa);
                node.next = null;
                return node;
            }

            pub fn destroy(self: *Node) void {
                const node_pa = mem.fromHhdm(Node, self);
                phys.freeContiguous(node_pa, NODE_PAGECOUNT);
            }
        };

        first_node: NodePtr = null,
        last_node: NodePtr = null,
        len: usize = 0,

        pub fn deinit(self: *Self) void {
            var current = self.first_node;
            while (current) |node| {
                const next = node.next;
                node.destroy();
                current = next;
            }
            self.first_node = null;
            self.last_node = null;
            self.len = 0;
        }

        pub fn append(self: *Self, item: Item) !usize {
            var target_node: *Node = undefined;

            const item_index = self.len % ITEMS_PER_NODE;

            if (self.last_node) |last| {
                if (item_index == 0 and self.len > 0) {
                    const new_node = try Node.create();
                    last.next = new_node;
                    self.last_node = new_node;
                    target_node = new_node;
                } else {
                    target_node = last;
                }
            } else {
                const new_node = try Node.create();
                self.first_node = new_node;
                self.last_node = new_node;
                target_node = new_node;
            }

            target_node.items[item_index] = item;

            const inserted_index = self.len;
            self.len += 1;

            return inserted_index;
        }

        pub fn getPtr(self: *Self, index: usize) ?*Item {
            if (index >= self.len) return null;

            const node_index = index / ITEMS_PER_NODE;
            const item_index = index % ITEMS_PER_NODE;

            var current = self.first_node;
            var current_node_index: usize = 0;

            while (current) |node| {
                if (current_node_index == node_index) {
                    return &node.items[item_index];
                }
                current = node.next;
                current_node_index += 1;
            }

            return null;
        }

        pub fn get(self: *Self, index: usize) ?Item {
            const ptr = self.getPtr(index) orelse return null;
            return ptr.*;
        }

        pub const Iterator = struct {
            current_node: NodePtr,
            current_item_index: usize,
            items_left: usize,

            pub fn next(self: *Iterator) ?*Item {
                if (self.items_left == 0) return null;

                const node = self.current_node orelse return null;
                const ptr = &node.items[self.current_item_index];

                self.current_item_index += 1;
                self.items_left -= 1;

                if (self.current_item_index == ITEMS_PER_NODE) {
                    self.current_node = node.next;
                    self.current_item_index = 0;
                }

                return ptr;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{
                .current_node = self.first_node,
                .current_item_index = 0,
                .items_left = self.len,
            };
        }

        pub fn updateHhdm(self: *Self) void {
            var next_node = self.first_node;
            while (next_node) |node| {
                next_node = node.next;
                if (node.next) |*next| {
                    mem.updateRef(Node, next);
                }
            }

            if (self.first_node) |*first_node| mem.updateRef(Node, first_node);
            if (self.last_node) |*last_node| mem.updateRef(Node, last_node);
        }
    };
}
