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

const basalt = @import("basalt");
const std = @import("std");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const paging = mem.paging;
const phys = mem.phys;
const utils = mem.utils;
const virt = mem.virt;

// --- mem/virt/SharedObject.zig --- //

const SharedObject = @This();

const Map = utils.SlotMap(utils.Arc(SharedObject));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;

pub var map: Map = .{};

id: Id,
object: virt.OwnedObject.Ref,
permissions: paging.Permissions,

// Protected by OwnedObject.lock.
next_shared: ?Ref = null,
last_shared: ?Ref = null,

pub fn destroy(self: *SharedObject) void {
    var obj_ref = self.object;
    defer obj_ref.release();

    const owned_object: *virt.OwnedObject = obj_ref.payload();

    const int_state = owned_object.lock.acquire(.write, 0);
    defer owned_object.lock.release(.write, int_state);

    if (self.next_shared) |*next| {
        const next_shared: *virt.SharedObject = next.payload();
        next_shared.last_shared.?.release(); // self
        next_shared.last_shared = self.last_shared;
    }

    if (self.last_shared) |*last| {
        const last_shared: *virt.SharedObject = last.payload();
        last_shared.next_shared.?.release(); // self
        last_shared.next_shared = self.next_shared;
    } else {
        owned_object.shared_head.?.release(); // self
        owned_object.shared_head = self.next_shared;
    }

    self.last_shared = null;
    self.next_shared = null;
}
