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

const arch = kernel.arch;

const mem = kernel.mem;
const utils = mem.utils;

const sched = kernel.sched;

const Process = sched.Process;
const Future = sched.Future;

// --- sched/Task.zig --- //

const Task = @This();
const Map = utils.SlotMap(utils.Arc(Task));
var map: Map = .{};
pub const Id = Map.Handle;
pub const Ref = Map.ArcRef;
pub const New = Map.New;

// --- //

process: Process.Ref,
setting: basalt.system.task.Settings,
last_resume: u64 = 0,

state: std.atomic.Value(State) = .init(.pending),

interrupt_data: arch.interrupts.InterruptData,

lock: mem.utils.RwLock = .{},

/// Protected by Process.lock
task_last: ?Task.Ref = null,
/// Protected by Process.lock
task_next: ?Task.Ref = null,

// --- //

pub fn SlotMap_deinit(self: *Task) void {
    self.process.release();
}

// --- //

const default_stack_size: u64 = 2 * 1024 * 1024; // 2 MiB

pub fn create(options: Options) !New {
    var proc_ref = options.process;
    errdefer proc_ref.release();

    const process: *Process = proc_ref.payload();
    const privileged = process.isPrivileged();
    const proc_view: *mem.virt.View = process.view.payload();

    const stack_pages = default_stack_size / mem.paging.page_size;

    var page_list: utils.UnrolledList(u64, null) = .{};
    errdefer page_list.deinit();
    for (0..stack_pages) |_| {
        _ = try page_list.append(0);
    }

    _, var stack_obj = try mem.virt.OwnedObject.map.insert(.{
        .length = stack_pages,
        .mem_type = .writeback,
        .permissions = .{
            .writable = true,
            .executable = false,
            .user = !privileged,
            .global = privileged,
        },
        .owns_physical = true,
        .physical_mapping = .{ .non_contiguous = page_list },
    });
    defer stack_obj.release();

    var interrupt_data: arch.interrupts.InterruptData = undefined;
    var stack_base: u64 = 0;

    if (privileged) {
        stack_base = try proc_view.alloc(default_stack_size, .{ .owned = stack_obj.clone() }, true, 0);

        const stack_top = stack_base + default_stack_size;
        const frame_va = stack_top - @sizeOf(arch.interrupts.ReducedFrame);
        const frame_ptr: *arch.interrupts.ReducedFrame = @ptrFromInt(frame_va);

        interrupt_data = .fromInitialData(frame_ptr, frame_va, stack_top, options.entry_point, true, options.arg, options.tls);
    } else {
        _, const shared_ref = try mem.virt.SharedObject.create(stack_obj.clone(), .{
            .writable = true,
            .executable = false,
            .user = false,
            .global = false,
        });

        const kview: *mem.virt.View = mem.virt.kernel_view.payload();
        const temp_kva = try kview.alloc(default_stack_size, .{ .shared = shared_ref }, false, 0);
        defer kview.remove(temp_kva) catch unreachable;

        stack_base = try proc_view.alloc(default_stack_size, .{ .owned = stack_obj.clone() }, true, 0);

        const stack_top = stack_base + default_stack_size;
        const user_frame_va = stack_top - @sizeOf(arch.interrupts.ReducedFrame);
        const kernel_frame_va = (temp_kva + default_stack_size) - @sizeOf(arch.interrupts.ReducedFrame);
        const kernel_frame_ptr: *arch.interrupts.ReducedFrame = @ptrFromInt(kernel_frame_va);

        interrupt_data = .fromInitialData(kernel_frame_ptr, user_frame_va, stack_top, options.entry_point, false, options.arg, options.tls);
    }
    errdefer proc_view.remove(stack_base) catch {};

    const id, const task_ref = try map.insert(Task{
        .process = proc_ref,
        .interrupt_data = interrupt_data,
        .setting = options.setting,
    });
    errdefer _ = map.remove(id);

    {
        const int_state = process.lock.acquire(.write, 0);
        defer process.lock.release(.write, int_state);

        const task_ptr: *Task = task_ref.payload();
        if (process.task_head) |head| {
            head.payload().task_last = task_ref.clone();
            task_ptr.task_next = head;
        }
        process.task_head = task_ref.clone();
    }

    return .{ id, task_ref };
}

pub fn get(id: Task.Id) ?Task.Ref {
    return map.get(id);
}

pub fn fault(self: *Task, code: Fault) void {
    _ = self;
    _ = code;

    const ctx = sched.SchedContext.current();
    ctx.current_task.?.release();
    ctx.current_task = null;
}

pub fn terminate(self: *Task) void {
    _ = self;
}

// --- //

pub const Options = struct {
    process: Process.Ref,
    setting: basalt.system.task.Settings,
    entry_point: u64,
    arg: u64,
    tls: u64,
};

pub const State = enum(u8) {
    pending,
    running,
    suspended,
    terminated,
};

pub const Fault = enum {
    stack_overflow,
    unmapped_memory,
    access_violation,
    out_of_memory,
    illegal_syscall,
    unexpected_exception,
};
