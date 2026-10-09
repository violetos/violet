// Copyright (c) 2024-2025 The violetOS authors
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

const arch = kernel.arch;

// --- syscall/root.zig --- //

pub var kit: basalt.system.call.KernelIndirectionTable = undefined;

pub fn init() !void {
    @memset(&registers, 0);
    register(.null, &null_syscall);
    basalt.system.call.kit = &kit;
}

fn null_syscall(frame: *arch.interrupts.ReducedFrame) !void {
    success(frame, .{});
}

// --- //

pub const SyscallFn = *const fn (*arch.interrupts.ReducedFrame) anyerror!void;
var registers: [basalt.system.call.MAX_CODE]u64 = undefined;

pub fn register(code: basalt.system.call.Code, syscall_fn: SyscallFn) void {
    registers[@backingInt(code)] = @intFromPtr(syscall_fn);
}

// --- //

pub inline fn success(frame: *arch.interrupts.ReducedFrame, values: basalt.system.call.ResultVals) void {
    frame.setArg(0, @bitCast(basalt.system.call.ResultArgs{
        .is_success = true,
        .value = .{ .success = .{
            .val0 = values.val0,
            .val1 = values.val1,
        } },
    }));

    frame.setArg(1, values.val2);
}

pub inline fn fail(frame: *arch.interrupts.ReducedFrame, code: basalt.system.call.Code) !void {
    frame.setArg(0, @bitCast(basalt.system.call.ResultArgs{
        .is_success = false,
        .value = .{ .err = .{
            .error_code = code,
        } },
    }));

    frame.setArg(1, 0);

    return error._;
}

// --- //

pub export fn internal_call_system(frame: *arch.interrupts.ReducedFrame) callconv(basalt.system.call_conv) void {
    const code = frame.getArg(0);

    if (code < registers.len) {
        const syscall_fn_val = registers[@intCast(code)];
        if (syscall_fn_val != 0) {
            const syscall_fn: SyscallFn = @ptrFromInt(syscall_fn_val);

            frame.setArg(0, @bitCast(basalt.system.call.ResultArgs{
                .is_success = false,
                .value = .{ .err = .{
                    .error_code = .internal_failure,
                } },
            }));

            frame.setArg(1, 0);

            return syscall_fn(frame) catch {};
        }
    }

    frame.setArg(0, @bitCast(basalt.system.call.ResultArgs{
        .is_success = false,
        .value = .{ .err = .{
            .error_code = .unknown_code,
        } },
    }));

    frame.setArg(1, 0);
}
