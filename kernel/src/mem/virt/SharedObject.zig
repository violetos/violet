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

const OwnedObject = virt.OwnedObject;
const PinState = OwnedObject.PinState;

// --- mem/virt/SharedObject.zig --- //

const SharedObject = @This();

const Map = utils.SlotMap(utils.Arc(SharedObject));

pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

pub var map: Map = .{};

id: Id = .null,
object: OwnedObject.Ref,
permissions: paging.Permissions,
max_permissions: paging.Permissions,
pin_state: PinState = .{},

/// Creates a new `SharedObject` handle over `owned_ref` (consumes `owned_ref`) with attenuated permissions.
pub fn create(owned_ref: OwnedObject.Ref, permissions: paging.Permissions) !New {
    var obj_ref = owned_ref;
    errdefer obj_ref.release();

    if (permissions.writable and permissions.executable) {
        return virt.Space.Error.WriteXorExecute;
    }

    const owned = obj_ref.payload();
    const base_perms = owned.permissions;

    // A shared capability can never escalate permissions beyond its backing OwnedObject.
    if ((permissions.writable and !base_perms.writable) or
        (permissions.executable and !base_perms.executable))
    {
        return virt.Space.Error.PermissionDenied;
    }

    _ = owned.shared_count.fetchAdd(1, .acquire);
    errdefer _ = owned.shared_count.fetchSub(1, .release);

    const id, const ref = try map.insert(.{
        .object = obj_ref,
        .permissions = permissions,
        .max_permissions = permissions,
    });
    ref.payload().id = id;
    return .{ id, ref };
}

pub inline fn pin(self: *SharedObject) !void {
    try self.pin_state.pin();
    errdefer self.pin_state.unpin();
    try self.object.payload().pin();
}

pub inline fn unpin(self: *SharedObject) void {
    self.object.payload().unpin();
    self.pin_state.unpin();
}

pub inline fn isPinned(self: *const SharedObject) bool {
    return self.pin_state.isPinned() or self.object.payload().isPinned();
}

/// Updates permissions on this `SharedObject` within `max_permissions`. Fails if pinned.
pub fn setPermissions(self: *SharedObject, new_perms: paging.Permissions) !void {
    if (new_perms.writable and new_perms.executable) return virt.Space.Error.WriteXorExecute;
    if ((new_perms.writable and !self.max_permissions.writable) or
        (new_perms.executable and !self.max_permissions.executable) or
        (new_perms.user and !self.max_permissions.user))
    {
        return virt.Space.Error.PermissionDenied;
    }
    if (self.object.payload().isPinned()) return virt.Space.Error.PinnedObject;

    try self.pin_state.beginExclusive();
    defer self.pin_state.endExclusive();

    self.permissions = new_perms;
}

pub fn SlotMap_deinit(self: *SharedObject) void {
    std.debug.assert(!self.pin_state.isPinned());
    const owned = self.object.payload();
    _ = owned.shared_count.fetchSub(1, .release);
    self.object.release();
}

pub fn destroy(self: *SharedObject) void {
    _ = self;
}

pub fn SlotMap_updateHhdm(self: *SharedObject) void {
    self.object.updateHhdm();
}
