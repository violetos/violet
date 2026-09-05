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

length: usize,
mem_type: paging.MemType,
permissions: paging.Permissions,
lock: utils.RwLock = .{},
physical_mapping: PhysicalMapping,

shared_head: ?virt.SharedObject.Ref = null,

// --- //

pub fn SlotMap_deinit(self: *OwnedObject) void {
    std.debug.assert(self.shared_head == null);

    switch (self.physical_mapping) {
        .non_contiguous => |*list| {
            var page_it = list.iterator();
            while (page_it.next()) |pa| {
                const page_addr = pa.*;
                if (page_addr == 0) continue;

                phys.freePage(page_addr);
            }
        },
        .contiguous => |pa| {
            if (pa == std.math.maxInt(u64)) return;
            phys.freeContiguous(pa, self.length);
        },
    }
}

pub fn destroy(self: *OwnedObject) void {
    const int_state = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, int_state);

    var next = self.shared_head;
    self.shared_head = null;
    while (next) |*shared_ref| {
        defer shared_ref.release();

        var shared_obj: *virt.SharedObject = shared_ref.payload();
        next = shared_obj.next_shared;
        shared_obj.next_shared = null;
        if (shared_obj.last_shared) |*last| {
            last.release();
            shared_obj.last_shared = null;
        }
    }
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
    /// use MAX_INT to tell the .deinit() that the plage was already freed!
    contiguous: u64,
    non_contiguous: utils.UnrolledList(u64, null),
};
