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
const builtin = @import("builtin");

// --- imports --- //

const basalt = @import("basalt");

// --- system/call.zig --- //

pub const MAX_CODE = @intFromEnum(Code.timer_sequential) + 1; // keep in sync with the biggest syscall code.
pub const Code = enum(u64) {
    null = 0x00,

    mem_map = 0x10,
    mem_unmap = 0x11,

    handler_set = 0x20,
    handler_exit = 0x21,

    process_terminate = 0x30,

    task_terminate = 0x40,
    task_yield = 0x41,

    future_create = 0x51,
    future_resolve = 0x52,
    future_await = 0x53,

    prism_create = 0x60,
    prism_destroy = 0x61,
    prism_consume = 0x62,
    prism_bind = 0x63,

    facet_create = 0x71,
    facet_drop = 0x72,
    facet_invoke = 0x73,

    timer_single = 0x80,
    timer_sequential = 0x81,
};

pub const Error = error{
    UnknownCode,
    InternalFailure,
};

pub const ErrorCode = enum(u16) {
    unknown_code = 0,
    internal_failure = 1,

    pub fn toError(self: @This()) Error {
        switch (self) {
            .unknown_code => return Error.UnknownCode,
            .internal_failure => return Error.InternalFailure,
        }
    }
};

pub const ResultArgs = packed struct(u64) {
    is_success: bool, // bit 0
    _reserved: u15 = 0, // bit 1-16
    value: packed union {
        err: packed struct(u48) {
            error_code: ErrorCode = .unknown_code, // bit 16-31
            _reserved: u32 = 0, // bit 32-63
        },
        success: packed struct(u48) {
            val0: u16 = 0, // bit 16-31
            val1: u32 = 0, // bit 32-63
        },
    },
};

pub const FullResult = extern struct {
    args: ResultArgs,
    val2: u64,
};

pub const ResultVals = struct {
    val0: u16 = 0,
    val1: u32 = 0,
    val2: u64 = 0,
};

// --- //

pub const KernelIndirectionTable = extern struct {
    call_system: *const fn (code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) callconv(basalt.system.call_conv) FullResult,
};

pub var kit: *const KernelIndirectionTable =
    if (basalt.system.is_module) undefined else unreachable;

// --- //

inline fn userland_fn(code: Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) FullResult {
    var code_val: u64 = @intFromEnum(code);
    var arg1_val: u64 = arg1;

    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile (
                \\ svc #0
                : [code] "+{x0}" (code_val),
                  [arg1] "+{x1}" (arg1_val),
                : [arg2] "{x2}" (arg2),
                  [arg3] "{x3}" (arg3),
                  [arg4] "{x4}" (arg4),
                  [arg5] "{x5}" (arg5),
                  [arg6] "{x6}" (arg6),
                  [arg7] "{x7}" (arg7),
                : .{
                  .memory = true,
                  .nzcv = true,
                });

            return .{
                .args = @bitCast(code_val),
                .val2 = arg1_val,
            };
        },
        .riscv64 => {
            asm volatile (
                \\ ecall
                : [code] "+{a0}" (code_val),
                  [arg1] "+{a1}" (arg1_val),
                : [arg2] "{a2}" (arg2),
                  [arg3] "{a3}" (arg3),
                  [arg4] "{a4}" (arg4),
                  [arg5] "{a5}" (arg5),
                  [arg6] "{a6}" (arg6),
                  [arg7] "{a7}" (arg7),
                : .{
                  .memory = true,
                });

            return .{
                .args = @bitCast(code_val),
                .val2 = arg1_val,
            };
        },
        .x86_64 => {
            asm volatile (
                \\ syscall
                : [code] "+{rax}" (code_val),
                  [arg1] "+{rdi}" (arg1_val),
                : [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{r10}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                  [arg7] "{r12}" (arg7),
                : .{
                  .memory = true,
                  .cc = true,
                  .rcx = true,
                  .r11 = true,
                });

            return .{
                .args = @bitCast(code_val),
                .val2 = arg1_val,
            };
        },
        else => unreachable,
    }

    return .{
        .args = code_val,
        .val2 = arg1_val,
    };
}

pub fn syscall(code: Code, args: anytype) Error!ResultVals {
    const builded_args = comptime buildArgs(args);
    const full_result: FullResult = if (basalt.system.is_module)
        @call(.auto, kit.call_system, .{code} ++ builded_args)
    else
        @call(.auto, userland_fn, .{code} ++ builded_args);

    if (!full_result.args.is_success) {
        return full_result.args.value.err.error_code.toError();
    }

    return .{
        .val0 = full_result.args.value.success.val0,
        .val1 = full_result.args.value.success.val1,
        .val2 = full_result.val2,
    };
}

// --- //

inline fn isArgName(name: []const u8) bool {
    if (name.len != 4) return false;
    if (!std.mem.eql(u8, name[0..3], "arg")) return false;
    return name[3] >= '1' and name[3] <= '7';
}

inline fn argIndex(name: []const u8) usize {
    return @as(usize, name[3] - '1');
}

inline fn validateArgsType(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            if (s.is_tuple) {
                if (s.fields.len > 7) {
                    @compileError("syscall tuple: at most 7 fields allowed");
                }
            } else {
                if (s.layout != .@"extern" and s.layout != .@"packed") {
                    @compileError("syscall struct must be 'packed' or 'extern'");
                }
                inline for (s.fields) |f| {
                    if (!isArgName(f.name)) {
                        @compileError("syscall invalid field '" ++ f.name ++ "': only arg1..arg7 are allowed");
                    }
                    if (@sizeOf(f.type) > 8) {
                        @compileError("syscall field '" ++ f.name ++ "' exceeds 8 bytes");
                    }
                }
            }
        },
        .int => |i| {
            if (i.bits > 64) @compileError("syscall integer too large (> 64 bits)");
        },
        else => @compileError("syscall unsupported args type: " ++ @typeName(T)),
    }
}

inline fn toU64(value: anytype) u64 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int => |i| blk: {
            const U = std.meta.Int(.unsigned, i.bits);
            break :blk @as(u64, @as(U, @bitCast(value)));
        },
        .bool => @intFromBool(value),
        .pointer => @intFromPtr(value),
        .float => |f| blk: {
            const U = std.meta.Int(.unsigned, f.bits);
            break :blk @as(u64, @as(U, @bitCast(value)));
        },
        else => blk: {
            const size = @sizeOf(T);
            var buf: [8]u8 = @splat(0);
            @memcpy(buf[0..size], std.mem.asBytes(&value));
            break :blk std.mem.readInt(u64, &buf, .little);
        },
    };
}

fn buildArgs(args: anytype) struct { u64, u64, u64, u64, u64, u64, u64 } {
    const T = @TypeOf(args);
    comptime validateArgsType(T);

    var result: [7]u64 = @splat(0);
    comptime switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.is_tuple) {
                for (s.fields, 0..) |f, i| {
                    result[i] = toU64(@field(args, f.name));
                }
            } else {
                for (s.fields) |f| {
                    result[argIndex(f.name)] = toU64(@field(args, f.name));
                }
            }
        },
        .int => result[0] = toU64(args),
        else => unreachable,
    };

    return .{ result[0], result[1], result[2], result[3], result[4], result[5], result[6] };
}
