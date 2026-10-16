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

// --- drivers/intc/Domain.zig --- //

const Domain = @This();
const Map = SlotMap(Arc(Domain));
var map: Map = .{};

pub const Handle = Map.Handle;
pub const Ref = Map.PtrRef;
pub const New = Map.New;

pub fn new(domain: Domain) !New {
    return map.insert(domain);
}

pub fn get(handle: Handle) ?Ref {
    return map.get(handle);
}

// --- //

context: *anyopaque,
vtable: *const VTable,

pub const VTable = extern struct {
    init_local: *allowzero const fn (context: *anyopaque) callconv(basalt.system.call_conv) u64 = @ptrFromInt(0),
    deinit_global: *allowzero const fn (context: *anyopaque) callconv(basalt.system.call_conv) void = @ptrFromInt(0),
};

pub fn initLocal(self: *Domain) !void {
    if (@intFromPtr(self.vtable.init_local) == 0) return;
    const res = self.vtable.init_local(self.context);
    if (res != 0) return error.InternalFailure;
}

pub fn deinitGlobal(self: *Domain) void {
    if (@intFromPtr(self.vtable.deinit_global) == 0) return;
    self.vtable.deinit_global(self.context);
}
