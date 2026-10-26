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
extern const call_system_end: u8;
extern const extend_frame_end: u8;
extern const trap_push_start: u8;
extern const trap_push_end: u8;

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
    scratch_a0: u64,
    scratch_t1: u64,
    scratch_t2: u64,
    in_handler: u64,
};

comptime {
    std.debug.assert(@offsetOf(TrapAnchor, "cpu_context") == 0);
    std.debug.assert(@offsetOf(TrapAnchor, "kernel_stack_top") == 8);
    std.debug.assert(@offsetOf(TrapAnchor, "scratch_a0") == 16);
    std.debug.assert(@offsetOf(TrapAnchor, "scratch_t1") == 24);
    std.debug.assert(@offsetOf(TrapAnchor, "scratch_t2") == 32);
    std.debug.assert(@offsetOf(TrapAnchor, "in_handler") == 40);
}

const ResumeMode = union(enum) {
    via_ret,
    via_sret: arch.registers.Sstatus,
};

inline fn captureFrame(frame: *ReducedFrame, resume_mode: ResumeMode) void {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        context.in_kernel = false;
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

fn idleWaitForTask() noreturn {
    const ic = InterruptsContext.current();
    ic.trap_anchor.in_handler = 0;
    const scratch_top = @intFromPtr(&ic.scratch_frame.reduced_frame) + @sizeOf(ReducedFrame);

    asm volatile ("mv sp, %[sp]"
        :
        : [sp] "r" (scratch_top),
        : .{ .memory = true });

    _ = set(.enabled);
    arch.cpu.halt();
}

fn restoreCurrent(old_frame: *ReducedFrame, old_mode: ResumeMode) noreturn {
    const sched_context = sched.SchedContext.current();

    const interrupt_data = if (sched_context.current_task) |*task_ref| blk: {
        sched_context.in_kernel = false;
        const task: *sched.Task = task_ref.payload();
        break :blk task.interrupt_data;
    } else if (sched_context.in_kernel) blk: {
        break :blk InterruptData{
            .frame_state = .{ .reduced_frame = old_frame },
            .resume_mode = old_mode,
        };
    } else {
        idleWaitForTask();
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

// --- //

inline fn resolveFaultView(fault_va: u64) *mem.virt.View {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        const task: *sched.Task = task_ref.payload();
        const process = task.process.payload();
        const proc_view: *mem.virt.View = process.view.payload();

        if (proc_view.space.payload().half.contains(fault_va, fault_va +| 1)) {
            return proc_view;
        }
    }
    return mem.virt.kernel_view.payload();
}

inline fn faultFromResult(result: mem.virt.Space.FaultResult) sched.Task.Fault {
    return switch (result) {
        .guard_violation => .stack_overflow,
        .unmapped => .unmapped_memory,
        .access_violation => .access_violation,
        .out_of_memory => .out_of_memory,
        .resolved => unreachable,
    };
}

fn faultCurrentTask(code: sched.Task.Fault, fault_va: u64, pc: u64, is_nested: bool) void {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        const task: *sched.Task = task_ref.payload();
        log.err(
            "task fault ({s}, nested={}) at 0x{x} (PC=0x{x})",
            .{ @tagName(code), is_nested, fault_va, pc },
        );
        task.fault(code);
    } else {
        std.debug.panic(
            "fatal kernel fault ({s}, nested={}) at 0x{x} (PC=0x{x}) with no active task",
            .{ @tagName(code), is_nested, fault_va, pc },
        );
    }
}

inline fn isInFramePush(pc: u64) bool {
    const cs_start = @intFromPtr(&call_system);
    const cs_end = @intFromPtr(&call_system_end);
    if (pc >= cs_start and pc < cs_end) return true;

    const tp_start = @intFromPtr(&trap_push_start);
    const tp_end = @intFromPtr(&trap_push_end);
    return (pc >= tp_start and pc < tp_end);
}

inline fn isInExtendFrame(pc: u64) bool {
    const ext_start = @intFromPtr(&extend_frame);
    const ext_end = @intFromPtr(&extend_frame_end);
    return (pc >= ext_start and pc < ext_end);
}

// --- //

export fn internal_entry(frame: *ReducedFrame) callconv(.{ .riscv64_lp64 = .{} }) void {
    captureFrame(frame, .via_ret);

    if (InterruptsContext.current().takePendingFrameFault()) |pf| {
        faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
        restoreCurrent(frame, .via_ret);
    }
}

export fn internal_exit(old_frame: *ReducedFrame) callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    restoreCurrent(old_frame, .via_ret);
}

export fn trap_top_level(frame: *ReducedFrame, sstatus_raw: u64, scause: u64) callconv(.{ .riscv64_lp64 = .{} }) noreturn {
    const sstatus: arch.registers.Sstatus = @bitCast(sstatus_raw);
    const is_interrupt = (scause >> 63) != 0;
    const code = scause & ~(@as(u64, 1) << 63);

    captureFrame(frame, .{ .via_sret = sstatus });

    if (is_interrupt) {
        if (InterruptsContext.current().takePendingFrameFault()) |pf| {
            faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
        }
        irqHandler(code);
    } else {
        if (InterruptsContext.current().takePendingFrameFault()) |pf| {
            faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
            restoreCurrent(frame, .{ .via_sret = sstatus });
        }
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
            faultCurrentTask(.illegal_syscall, 0, frame.program_counter, false);
        },
        12, 13, 15 => { // instruction / load / store page fault
            const stval = arch.registers.csrRead("stval");
            if (arch.paging.syncHighHalfIfNeeded(stval)) return;

            const view = resolveFaultView(stval);
            const result = view.handlePageFault(stval);

            if (result != .resolved) {
                faultCurrentTask(faultFromResult(result), stval, frame.program_counter, false);
            }
        },
        3 => { // EBREAK
            const rframe = currentReducedFrame(frame);

            const pc = rframe.program_counter;
            const instruction = @as(*const u16, @ptrFromInt(pc)).*;
            const is_32_bit = (instruction & 0b11) == 0b11;
            const instruction_length: u64 = if (is_32_bit) 4 else 2;

            log.debug("breakpoint at 0x{x}", .{pc});
            rframe.program_counter += instruction_length;
        },
        else => {
            log.err("unexpected synchronous trap (cause={}) at PC=0x{x}", .{ code, frame.program_counter });
            faultCurrentTask(.unexpected_exception, 0, frame.program_counter, false);
        },
    }
}

fn irqHandler(code: u64) void {
    switch (code) {
        1, 9 => { // supervisor software / external interrupt
            drivers.intc.handle() catch |err| {
                log.warn("unhandled interrupt: {s}", .{@errorName(err)});
            };
        },
        5 => {
            drivers.timer.onInterrupt();
        },
        else => {
            log.err("unexpected interrupt (cause={})", .{code});
            arch.cpu.halt();
        },
    }
}

export fn trap_nested(nested_frame: *NestedFrame) callconv(.{ .riscv64_lp64 = .{} }) void {
    const scause = nested_frame.scause;
    const stval = nested_frame.stval;
    const is_interrupt = (scause >> 63) != 0;
    const code = scause & ~(@as(u64, 1) << 63);

    if (is_interrupt) {
        log.err("unexpected nested interrupt (cause={}) at SEPC=0x{x}", .{ code, nested_frame.sepc });
        arch.cpu.halt();
    }

    switch (code) {
        12, 13, 15 => {
            if (arch.paging.syncHighHalfIfNeeded(stval)) return;

            const view = resolveFaultView(stval);
            const result = view.handlePageFault(stval);

            if (result == .resolved) return;

            const fault_code = faultFromResult(result);
            const ic = InterruptsContext.current();

            if (isInFramePush(nested_frame.sepc)) {
                ic.pending_frame_fault = .{ .code = fault_code, .va = stval };
                nested_frame.xregs[8] = @intFromPtr(&ic.scratch_frame.reduced_frame);
                return;
            }

            if (isInExtendFrame(nested_frame.sepc)) {
                const old_reduced: *const ReducedFrame = @ptrFromInt(
                    nested_frame.xregs[8] + @offsetOf(ExtendedFrame, "reduced_frame"),
                );
                ic.scratch_frame.reduced_frame = old_reduced.*;
                ic.pending_frame_fault = .{ .code = fault_code, .va = stval };
                nested_frame.xregs[8] = @intFromPtr(&ic.scratch_frame);
                return;
            }

            faultCurrentTask(fault_code, stval, nested_frame.sepc, true);
            restoreCurrent(&ic.scratch_frame.reduced_frame, .via_ret);
        },
        else => {
            log.err("unexpected nested synchronous trap (cause={}) at SEPC=0x{x}", .{ code, nested_frame.sepc });
            arch.cpu.halt();
        },
    }
}

// --- //

pub fn init() !void {
    kernel.syscall.kit.call_system = &call_system;
}

pub fn cpuInit(cpu_context: *kernel.cpu.CpuContext) void {
    cpu_context.interrupts_context.trap_anchor.cpu_context = @intFromPtr(cpu_context);
    arch.registers.csrWrite("sscratch", @intFromPtr(&cpu_context.interrupts_context.trap_anchor));
    arch.cpu.setPerCpu(@intFromPtr(cpu_context));

    arch.registers.csrWrite("stvec", @intFromPtr(&trap_vector));

    var sstatus = arch.registers.Sstatus.load();
    sstatus.fs = .initial;
    sstatus.store();
}

pub const PendingFrameFault = struct {
    code: sched.Task.Fault,
    va: u64,
};

pub const InterruptsContext = struct {
    trap_anchor: TrapAnchor = undefined,
    pending_frame_fault: ?PendingFrameFault = null,
    scratch_frame: ExtendedFrame align(16) = undefined,

    pub fn init(self: *InterruptsContext) !void {
        const stack_size = 512 * 1024;
        const pages_count = stack_size / mem.paging.page_size;
        const kernel_stack_top = (mem.hhdm_offset + try mem.phys.allocContiguous(pages_count)) + stack_size;

        self.trap_anchor = .{
            .cpu_context = 0,
            .kernel_stack_top = kernel_stack_top,
            .scratch_a0 = 0,
            .scratch_t1 = 0,
            .scratch_t2 = 0,
            .in_handler = 0,
        };
        self.pending_frame_fault = null;
    }

    pub inline fn takePendingFrameFault(self: *InterruptsContext) ?PendingFrameFault {
        const pf = self.pending_frame_fault;
        self.pending_frame_fault = null;
        return pf;
    }

    pub fn current() *InterruptsContext {
        return &kernel.cpu.CpuContext.current().?.interrupts_context;
    }

    pub fn updateHhdm(self: *InterruptsContext) void {
        self.trap_anchor.kernel_stack_top = @intFromPtr(mem.updatePtr(anyopaque, @ptrFromInt(self.trap_anchor.kernel_stack_top)));
        if (self.trap_anchor.cpu_context != 0) {
            self.trap_anchor.cpu_context = @intFromPtr(mem.updatePtr(anyopaque, @ptrFromInt(self.trap_anchor.cpu_context)));
        }

        if (kernel.cpu.CpuContext.current()) |ctx| {
            if (&ctx.interrupts_context == self) {
                const new_ctx = mem.updatePtr(kernel.cpu.CpuContext, ctx);
                self.trap_anchor.cpu_context = @intFromPtr(new_ctx);
                arch.registers.csrWrite("sscratch", @intFromPtr(&self.trap_anchor));
                arch.cpu.setPerCpu(@intFromPtr(new_ctx));
            }
        }
    }
};

// --- //

pub const NestedFrame = extern struct {
    xregs: [30]u64, // ra, gp, tp, t0-2, s0-1, a0-7, s2-11, t3-6
    sepc: u64,
    sstatus: u64,
    scause: u64,
    stval: u64,
};

comptime {
    std.debug.assert(@sizeOf(NestedFrame) == 272);
    std.debug.assert(@offsetOf(NestedFrame, "sepc") == 240);
    std.debug.assert(@offsetOf(NestedFrame, "sstatus") == 248);
    std.debug.assert(@offsetOf(NestedFrame, "scause") == 256);
    std.debug.assert(@offsetOf(NestedFrame, "stval") == 264);
}

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
                if (InterruptsContext.current().takePendingFrameFault()) |pf| {
                    faultCurrentTask(pf.code, pf.va, extended.reduced_frame.program_counter, true);
                }
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
