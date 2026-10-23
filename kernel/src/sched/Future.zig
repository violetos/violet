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
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;
const utils = mem.utils;
const sched = kernel.sched;

const Process = sched.Process;
const Task = sched.Task;

// --- sched/Future.zig --- //

const Future = @This();
const Map = utils.SlotMap(utils.Arc(Future));
var map: Map = .{};
pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

pub const Kind = basalt.sync.Future.Kind;
pub const State = basalt.sync.Future.State;

// --- //

kind: Kind,
consumer: Process.Id,

/// Called every time the task is consumed while "pending".
/// The kernel reads again the future state after this routine.
consume_fn: ?*const fn (self: *Future, no_suspend: bool, payload_compare: u64) void = null,

lock: mem.utils.RwLock = .{},
/// `null` means "kernel managed".
producer: ?Task.Id,
state: State = .pending,
payload: u64 = 0,
waiting_head: ?Task.Ref = null,

/// Protected by Task.lock, not Future.lock
producer_next: ?Future.Ref,
/// Protected by Task.lock, not Future.lock
producer_last: ?Future.Ref,

/// Protected by Process.lock, not Future.lock
consumer_next: ?Future.Ref,
/// Protected by Process.lock, not Future.lock
consumer_last: ?Future.Ref,

pub fn create(item: Future) !Future.New {
    return try map.insert(item);
}

pub fn get(id: Future.Id) ?Future.Ref {
    return map.get(id);
}

pub fn produce(self: *Future, state: State, payload: u64) !void {
    std.debug.assert(state != .pending);

    const saved_int = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, saved_int);

    if (self.kind != .relative and self.state != .pending) {
        return error.AlreadyProduced;
    }

    _ = payload;

    // ...
}

pub fn consume(self: *Future, no_suspend: bool, payload_compare: u64) !u64 {
    const saved_int = self.lock.acquire(.write, 0);
    defer self.lock.release(.write, saved_int);

    if (self.consume_fn) |consume_fn| {
        consume_fn(self, no_suspend, payload_compare);
    }

    switch (self.state) {
        .pending => {
            if (self.kind == .relative and payload_compare == self.payload) return payload_compare;
            return error.Pending;
        },
        .canceled => return error.Canceled,
        .resolved => switch (self.kind) {
            .single => {

                // destroy
            },
            .multi => {},
            .relative => if (self.payload < payload_compare) return error.Pending,
        },
    }

    return self.payload;
}

// --- syscalls --- //

// ...
