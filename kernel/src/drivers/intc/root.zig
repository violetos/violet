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

// --- exports -- //

pub const Domain = @import("Domain.zig");
pub const TrigIrq = @import("TrigIrq.zig");
pub const VirtIrq = @import("VirtIrq.zig");

// --- drivers/intc/root.zig --- //

var root: Domain.New = .{ .null, undefined };

pub fn isRootRegistered() bool {
    return !root.@"0".isNull();
}

pub fn getRoot() !*Domain {
    if (!isRootRegistered()) return error.NoRegisteredRoot;
    return root.@"1".payload();
}

pub fn registerRoot(root_dom: Domain) !void {
    if (isRootRegistered()) return error.AlreadyRegistered;
    root = try Domain.new(root_dom);
}

pub fn handle() !void {
    const root_dom = try getRoot();
    _ = root_dom;
}
