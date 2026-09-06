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

const log = std.log.scoped(.ints);

// --- imports --- //

const kernel = @import("root");

const arch = kernel.arch;
const drivers = kernel.drivers;
const sched = kernel.sched;
const mem = kernel.mem;

// --- asm --- //

extern const trap_vector: u8 linksection(".text");

extern fn call_system(code: basalt.system.call.Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) callconv(.{ .riscv64_lp64 = .{} }) basalt.system.call.FullResult;

extern fn restore_reduced_via_sret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn;
extern fn restore_extended_via_sret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn;
extern fn restore_reduced_via_ret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn;
extern fn restore_extended_via_ret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn;

extern fn extend_frame(frame: *ReducedFrame) callconv(.{ .riscv64_lp64 = .{} }) *ExtendedFrame;

// --- arch/riscv64/interrupts.zig --- //

pub const TrapAnchor = extern struct {
    cpu_context: u64,
    kernel_stack_top: u64,
    scratch_t1: u64,
    scratch_t2: u64,
};

comptime {
    std.debug.assert(@offsetOf(TrapAnchor, "cpu_context") == 0);
    std.debug.assert(@offsetOf(TrapAnchor, "kernel_stack_top") == 8);
    std.debug.assert(@offsetOf(TrapAnchor, "scratch_t1") == 16);
    std.debug.assert(@offsetOf(TrapAnchor, "scratch_t2") == 24);
}

const ResumeMode = union(enum) {
    via_ret,
    via_sret: arch.registers.Sstatus,
};

inline fn captureFrame(frame: *ReducedFrame, resume_mode: ResumeMode) void {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        const task: *sched.Task = task_ref.payload();
        task.interrupt_data.frame_state = .{ .reduced_frame = frame };
        task.interrupt_data.resume_mode = resume_mode;
    }
}

inline fn currentReducedFrame(fallback: *ReducedFrame) *ReducedFrame {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        return task_ref.payload().interrupt_data.frame_state.reduced();
    }
    return fallback;
}

fn restoreCurrent(old_frame: *ReducedFrame, old_mode: ResumeMode) noreturn {
    const interrupt_data = blk: {
        const sched_context = sched.SchedContext.current();
        if (sched_context.current_task) |*task_ref| {
            break :blk task_ref.payload().interrupt_data;
        } else {
            break :blk InterruptData{
                .frame_state = .{ .reduced_frame = old_frame },
                .resume_mode = old_mode,
            };
        }
    };

    const kernel_stack_top = InterruptsContext.current().trap_anchor.kernel_stack_top;

    switch (interrupt_data.resume_mode) {
        .via_ret => switch (interrupt_data.frame_state) {
            .reduced_frame => |frame| restore_reduced_via_ret(frame, kernel_stack_top),
            .extended_frame => |frame| restore_extended_via_ret(frame, kernel_stack_top),
        },
        .via_sret => |sstatus| {
            sstatus.store();
            switch (interrupt_data.frame_state) {
                .reduced_frame => |frame| restore_reduced_via_sret(frame, kernel_stack_top),
                .extended_frame => |frame| restore_extended_via_sret(frame, kernel_stack_top),
            }
        },
    }
}

export fn internal_entry(frame: *ReducedFrame) callconv(.{ .riscv64_lp64 = .{} }) void {
    captureFrame(frame, .via_ret);
}

export fn internal_exit(old_frame: *ReducedFrame) callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    restoreCurrent(old_frame, .via_ret);
}

export fn trap_top_level(frame: *ReducedFrame, sstatus_raw: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    const sstatus: arch.registers.Sstatus = @bitCast(sstatus_raw);
    captureFrame(frame, .{ .via_sret = sstatus });

    const scause = arch.registers.csrRead("scause");
    const is_interrupt = (scause >> 63) != 0;
    const code = scause & ~(@as(u64, 1) << 63);

    if (is_interrupt) {
        irqHandler(code);
    } else {
        syncHandler(code, frame);
    }

    restoreCurrent(frame, .{ .via_sret = sstatus });
}

fn syncHandler(code: u64, frame: *ReducedFrame) void {
    switch (code) {
        8 => {
            frame.program_counter += 4;
            kernel.syscall.internal_call_system(frame);
        },
        9 => {
            log.err("unexpected ecall trapped from a privileged (S-mode) task", .{});
            arch.cpu.halt();
        },
        12, 13, 15 => { // instruction/load/store page fault
            const stval = arch.registers.csrRead("stval");

            log.err("unresolved page fault (cause={}) at 0x{x}", .{ code, stval });
            arch.cpu.halt();
        },
        3 => { // EBREAK
            const rframe = currentReducedFrame(frame);
            log.debug("breakpoint at 0x{x}", .{rframe.program_counter});
            rframe.program_counter += 4;
        },
        else => {
            log.err("unexpected synchronous trap (cause={})", .{code});
            arch.cpu.halt();
        },
    }
}

fn irqHandler(code: u64) void {
    switch (code) {
        1, 5, 9 => { // supervisor software / timer / external interrupt
            const ctrl = drivers.intc.active_controller orelse {
                log.err("interrupt trapped with no interrupt controller registered", .{});
                arch.cpu.halt();
            };

            if (ctrl.acknowledge()) |irq_id| {
                ctrl.dispatch(irq_id);
            } else {
                log.warn("spurious interrupt", .{});
            }
        },
        else => {
            log.err("unexpected interrupt (cause={})", .{code});
            arch.cpu.halt();
        },
    }
}

export fn trap_nested(scause: u64, stval: u64) callconv(.{ .riscv64_lp64 = .{} }) void {
    const is_interrupt = (scause >> 63) != 0;
    const code = scause & ~(@as(u64, 1) << 63);

    if (is_interrupt) {
        log.err("unexpected nested interrupt (cause={})", .{code});
        arch.cpu.halt();
    }

    switch (code) {
        12, 13, 15 => {
            log.err("unresolved nested page fault (cause={}) at 0x{x}", .{ code, stval });
            arch.cpu.halt();
        },
        else => {
            log.err("unexpected nested synchronous trap (cause={})", .{code});
            arch.cpu.halt();
        },
    }
}

// --- //

pub fn init() !void {
    kernel.syscall.kit.call_system = &call_system;
}

pub fn cpuInit(cpu_context: *kernel.cpu.CpuContext) void {
    arch.registers.csrWrite("sscratch", @intFromPtr(&cpu_context.interrupts_context.trap_anchor));
    arch.cpu.setPerCpu(@intFromPtr(cpu_context));

    arch.registers.csrWrite("stvec", @intFromPtr(&trap_vector));

    var sstatus = arch.registers.Sstatus.load();
    sstatus.fs = .initial;
    sstatus.store();
}

pub const InterruptsContext = struct {
    trap_anchor: TrapAnchor = undefined,

    pub fn init(self: *InterruptsContext) !void {
        const stack_size = 512 * 1024;
        const pages_count = stack_size / mem.paging.page_size;
        const kernel_stack_top = (mem.hhdm_offset + try mem.phys.allocContiguous(pages_count)) + stack_size;

        self.trap_anchor = .{
            .cpu_context = 0,
            .kernel_stack_top = kernel_stack_top,
            .scratch_t1 = 0,
            .scratch_t2 = 0,
        };
    }

    pub fn current() *InterruptsContext {
        return &kernel.cpu.CpuContext.current().?.interrupts_context;
    }

    pub fn updateHhdm(self: *InterruptsContext) void {
        self.trap_anchor.kernel_stack_top = @intFromPtr(mem.updatePtr(anyopaque, @ptrFromInt(self.trap_anchor.kernel_stack_top)));

        if (kernel.cpu.CpuContext.current()) |ctx| {
            if (&ctx.interrupts_context == self) {
                arch.registers.csrWrite("sscratch", @intFromPtr(&self.trap_anchor));
                arch.cpu.setPerCpu(@intFromPtr(ctx));
            }
        }
    }
};

// --- //

pub const ReducedFrame = extern struct {
    xregs: [30]u64, // ra, gp, tp, t0-2, s0-1, a0-7, s2-11, t3-6 (x2/sp excluded, dedicated field)
    program_counter: u64, // sepc, consumed only by the via_sret path
    stack_pointer: u64, // x2, saved before being repurposed to carve the frame

    pub fn setArg(self: *ReducedFrame, comptime index: usize, value: u64) void {
        self.xregs[8 + index] = value; // a0 starts at xregs[8]
    }

    pub fn getArg(self: *ReducedFrame, comptime index: usize) u64 {
        return self.xregs[8 + index];
    }
};

comptime {
    std.debug.assert(@sizeOf(ReducedFrame) == 256);
    std.debug.assert(@offsetOf(ReducedFrame, "program_counter") == 240);
    std.debug.assert(@offsetOf(ReducedFrame, "stack_pointer") == 248);
}

pub const ExtendedFrame = extern struct {
    fregs: [32]u64, // f0..f31
    fcsr: u64,
    _reserved: u64 = 0, // alignment padding
    reduced_frame: ReducedFrame,
};

comptime {
    std.debug.assert(@sizeOf(ExtendedFrame) == 528);
    std.debug.assert(@offsetOf(ExtendedFrame, "fcsr") == 256);
    std.debug.assert(@offsetOf(ExtendedFrame, "reduced_frame") == 272);
}

const FrameState = union(enum) {
    reduced_frame: *ReducedFrame,
    extended_frame: *ExtendedFrame,

    pub inline fn reduced(self: *FrameState) *ReducedFrame {
        return switch (self.*) {
            .reduced_frame => |f| f,
            .extended_frame => |f| &f.reduced_frame,
        };
    }

    pub inline fn ensureExtended(self: *FrameState) *ExtendedFrame {
        return switch (self.*) {
            .reduced_frame => |f| blk: {
                const extended = extend_frame(f);
                self.* = .{ .extended_frame = extended };
                break :blk extended;
            },
            .extended_frame => |f| f,
        };
    }
};

pub const InterruptData = struct {
    frame_state: FrameState,
    resume_mode: ResumeMode,

    pub fn init(data: *InterruptData, privileged: bool) !void {
        _ = data;
        _ = privileged;
    }

    pub fn deinit(data: *InterruptData) void {
        _ = data;
    }
};

// --- //

pub const InterruptState = enum(u1) { disabled = 0, enabled = 1 };

pub inline fn set(new: InterruptState) InterruptState {
    const old: u64 = switch (new) {
        .disabled => asm volatile ("csrrc %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (@as(u64, 0x2)),
        ),
        .enabled => asm volatile ("csrrs %[old], sstatus, %[mask]"
            : [old] "=r" (-> u64),
            : [mask] "r" (@as(u64, 0x2)),
        ),
    };
    return if ((old & 0x2) != 0) .enabled else .disabled;
}
