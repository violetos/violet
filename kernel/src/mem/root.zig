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

// --- exports --- //

pub const virt = @import("virt/root.zig");

pub const paging = @import("paging.zig");
pub const phys = @import("phys.zig");
pub const utils = @import("utils.zig");

// --- mem/root.zig --- //

pub var zero_page_pa: u64 = undefined;

pub var old_hhdm: u64 = undefined;
pub var hhdm_offset: u64 = undefined;

pub inline fn toHhdm(comptime T: type, pa: u64) *T {
    return @alignCast(@as(*T, @ptrFromInt(hhdm_offset + pa)));
}

pub inline fn fromHhdm(comptime T: type, ptr: *T) u64 {
    return @intFromPtr(ptr) - hhdm_offset;
}

pub inline fn updateRef(comptime T: type, ref: **T) void {
    const raw_old: u64 = @intFromPtr(ref.*);
    const pa = raw_old - old_hhdm;
    ref.* = toHhdm(T, pa);
}

pub inline fn updatePtr(comptime T: type, ptr: *T) *T {
    const raw_old: u64 = @intFromPtr(ptr);
    const pa = raw_old - old_hhdm;
    return toHhdm(T, pa);
}

pub inline fn updatePtrs(comptime T: type, ptrs: [*]T) [*]T {
    return @ptrCast(updatePtr(T, @ptrCast(ptrs)));
}

comptime {
    _ = paging;
    _ = phys;
    _ = utils;
    _ = virt;
}
