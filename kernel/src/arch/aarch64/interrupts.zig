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

extern const exception_vector_table: [2048]u8 align(0x800) linksection(".text");
extern const call_system_end: u8;
extern const extend_frame_end: u8;
extern const exception_handlers_start: u8;
extern const exception_handlers_end: u8;

extern fn call_system(code: basalt.system.call.Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) callconv(.{ .aarch64_aapcs = .{} }) basalt.system.call.FullResult;

extern fn restore_reduced_via_eret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_eret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_reduced_via_ret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_ret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;

extern fn extend_frame(frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) *ExtendedFrame;

// --- arch/aarch64/interrupts.zig --- //

const ResumeMode = union(enum) {
    via_ret,
    via_eret: arch.registers.SPSR,
};

inline fn captureFrame(frame: *ReducedFrame, resume_mode: ResumeMode) void {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        context.in_kernel = false;
        const task: *sched.Task = task_ref.payload();

        task.interrupt_data = .{
            .frame_state = .{ .reduced_frame = frame },
            .resume_mode = resume_mode,
        };
    }
}

inline fn currentReducedFrame(fallback: *ReducedFrame) *ReducedFrame {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
        const task: *sched.Task = task_ref.payload();
        return task.interrupt_data.frame_state.reduced();
    }
    return fallback;
}

fn idleWaitForTask() noreturn {
    const ic = InterruptsContext.current();
    const scratch_top = @intFromPtr(&ic.scratch_frame.reduced_frame) + @sizeOf(ReducedFrame);

    asm volatile (
        \\ mov sp, %[ksp]
        \\ msr sp_el0, %[usp]
        \\ msr spsel, #0
        :
        : [ksp] "r" (ic.kernel_stack_top),
          [usp] "r" (scratch_top),
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

    const kernel_stack_top = InterruptsContext.current().kernel_stack_top;

    switch (interrupt_data.resume_mode) {
        .via_ret => switch (interrupt_data.frame_state) {
            .reduced_frame => |frame| restore_reduced_via_ret(frame, kernel_stack_top),
            .extended_frame => |frame| restore_extended_via_ret(frame, kernel_stack_top),
        },
        .via_eret => |spsr| {
            spsr.store();

            switch (interrupt_data.frame_state) {
                .reduced_frame => |frame| restore_reduced_via_eret(frame, kernel_stack_top),
                .extended_frame => |frame| restore_extended_via_eret(frame, kernel_stack_top),
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

    const eh_start = @intFromPtr(&exception_handlers_start);
    const eh_end = @intFromPtr(&exception_handlers_end);
    return (pc >= eh_start and pc < eh_end);
}

inline fn isInExtendFrame(pc: u64) bool {
    const ext_start = @intFromPtr(&extend_frame);
    const ext_end = @intFromPtr(&extend_frame_end);
    return (pc >= ext_start and pc < ext_end);
}

// --- //

export fn internal_entry(frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) void {
    captureFrame(frame, .via_ret);

    if (InterruptsContext.current().takePendingFrameFault()) |pf| {
        faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
        restoreCurrent(frame, .via_ret);
    }
}

export fn internal_exit(old_frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    restoreCurrent(old_frame, .via_ret);
}

fn syncHandler(frame: *ReducedFrame, saved_spsr: arch.registers.SPSR) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    captureFrame(frame, .{ .via_eret = saved_spsr });

    if (InterruptsContext.current().takePendingFrameFault()) |pf| {
        faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
        restoreCurrent(frame, .{ .via_eret = saved_spsr });
    }

    const esr = arch.registers.ESR.load();

    switch (esr.ec) {
        .svc_inst_aarch64 => {
            const context = sched.SchedContext.current();
            const privileged = if (context.current_task) |*task| task.payload().process.payload().isPrivileged() else true;
            if (privileged) {
                log.err("unexpected svc trapped from a privileged (EL1t) task", .{});
                faultCurrentTask(.illegal_syscall, 0, frame.program_counter, false);
                restoreCurrent(frame, .{ .via_eret = saved_spsr });
            }

            kernel.syscall.internal_call_system(frame);
        },

        .data_abort_lower_el, .data_abort_same_el, .inst_abort_lower_el, .inst_abort_same_el => {
            const far = arch.registers.loadFarEl1();
            const view = resolveFaultView(far);
            const result = view.handlePageFault(far);

            if (result != .resolved) {
                faultCurrentTask(faultFromResult(result), far, frame.program_counter, false);
            }
        },

        .brk_aarch64 => {
            const iss = esr.iss.brk_aarch64;
            const rframe = currentReducedFrame(frame);
            log.debug("breakpoint (comment={}) at 0x{x}", .{ iss.comment, rframe.program_counter });
            rframe.program_counter += 4;
        },

        else => {
            log.err("unexpected synchronous exception at PC=0x{x}", .{frame.program_counter});
            esr.dump();
            faultCurrentTask(.unexpected_exception, 0, frame.program_counter, false);
        },
    }

    restoreCurrent(frame, .{ .via_eret = saved_spsr });
}

fn irqHandler(frame: *ReducedFrame, saved_spsr: arch.registers.SPSR) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    captureFrame(frame, .{ .via_eret = saved_spsr });

    if (InterruptsContext.current().takePendingFrameFault()) |pf| {
        faultCurrentTask(pf.code, pf.va, frame.program_counter, true);
    }

    drivers.intc.handle() catch |err| {
        log.warn("unhandled interrupt: {s}", .{@errorName(err)});
    };

    restoreCurrent(frame, .{ .via_eret = saved_spsr });
}

fn unexpectedException(_: *ReducedFrame, saved_spsr: arch.registers.SPSR) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    _ = saved_spsr;

    log.err("unexpected exception (fiq/serror)", .{});
    arch.registers.ESR.load().dump();
    arch.cpu.halt();
}

fn nestedSyncHandler(nested_frame: *NestedFrame) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr: arch.registers.ESR = @bitCast(nested_frame.esr);
    const far = nested_frame.far;

    switch (esr.ec) {
        .data_abort_same_el, .data_abort_lower_el, .inst_abort_same_el, .inst_abort_lower_el => {
            const view = resolveFaultView(far);
            const result = view.handlePageFault(far);

            if (result == .resolved) return;

            const fault_code = faultFromResult(result);
            const ic = InterruptsContext.current();

            if (isInFramePush(nested_frame.elr)) {
                const scratch_reduced = &ic.scratch_frame.reduced_frame;
                ic.pending_frame_fault = .{ .code = fault_code, .va = far };
                nested_frame.xregs[0] = @intFromPtr(scratch_reduced);
                arch.registers.storeSpEl0(@intFromPtr(scratch_reduced));
                return;
            }

            if (isInExtendFrame(nested_frame.elr)) {
                const old_reduced: *const ReducedFrame = @ptrFromInt(
                    nested_frame.xregs[0] + @offsetOf(ExtendedFrame, "reduced_frame"),
                );
                ic.scratch_frame.reduced_frame = old_reduced.*;
                ic.pending_frame_fault = .{ .code = fault_code, .va = far };
                nested_frame.xregs[0] = @intFromPtr(&ic.scratch_frame);
                return;
            }

            faultCurrentTask(fault_code, far, nested_frame.elr, true);
            restoreCurrent(&ic.scratch_frame.reduced_frame, .via_ret);
        },
        else => {
            log.err("unexpected nested synchronous exception at ELR=0x{x}", .{nested_frame.elr});
            esr.dump();
            arch.cpu.halt();
        },
    }
}

fn unexpectedNestedException(nested_frame: *NestedFrame) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr: arch.registers.ESR = @bitCast(nested_frame.esr);
    log.err("unexpected nested exception (irq/fiq/serror) at ELR=0x{x}", .{nested_frame.elr});
    esr.dump();
    arch.cpu.halt();
}

// --- //

export const el1t_sync = syncHandler;
export const el1t_irq = irqHandler;
export const el1t_fiq = unexpectedException;
export const el1t_serror = unexpectedException;

export const el1h_sync = nestedSyncHandler;
export const el1h_irq = unexpectedNestedException;
export const el1h_fiq = unexpectedNestedException;
export const el1h_serror = unexpectedNestedException;

export const el0_sync = syncHandler;
export const el0_irq = irqHandler;
export const el0_fiq = unexpectedException;
export const el0_serror = unexpectedException;

comptime {
    _ = el1t_sync;
    _ = el1t_irq;
    _ = el1t_fiq;
    _ = el1t_serror;

    _ = el1h_sync;
    _ = el1h_irq;
    _ = el1h_fiq;
    _ = el1h_serror;

    _ = el0_sync;
    _ = el0_irq;
    _ = el0_fiq;
    _ = el0_serror;
}

// --- //

pub fn init() !void {
    kernel.syscall.kit.call_system = &call_system;
}

pub fn cpuInit(cpu_context: *kernel.cpu.CpuContext) void {
    arch.cpu.setPerCpu(@intFromPtr(cpu_context));

    arch.registers.storeVbarEl1(@intFromPtr(&exception_vector_table));
    arch.registers.storeSpEl1(cpu_context.interrupts_context.kernel_stack_top);

    asm volatile (
        \\ mov x0, #(3 << 20)
        \\ msr cpacr_el1, x0
        \\ mrs x0, CurrentEL
        \\ lsr x0, x0, #2
        \\ cmp x0, #2
        \\ b.ne 1f
        \\ msr cptr_el2, xzr
        \\ 1:
        \\ isb
        ::: .{ .x0 = true, .memory = true });
}

pub const PendingFrameFault = struct {
    code: sched.Task.Fault,
    va: u64,
};

pub const InterruptsContext = struct {
    kernel_stack_top: u64,
    pending_frame_fault: ?PendingFrameFault = null,
    scratch_frame: ExtendedFrame align(16) = undefined,

    pub fn init(self: *InterruptsContext) !void {
        const stack_size = 512 * 1024; // 512 KiB
        const pages_count = stack_size / mem.paging.page_size;
        self.kernel_stack_top = (mem.hhdm_offset + try mem.phys.allocContiguous(pages_count)) + stack_size;
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
        self.kernel_stack_top = @intFromPtr(mem.updatePtr(anyopaque, @ptrFromInt(self.kernel_stack_top)));

        if (kernel.cpu.CpuContext.current()) |ctx| {
            if (&ctx.interrupts_context == self) {
                arch.registers.storeSpEl1(self.kernel_stack_top);
                arch.cpu.setPerCpu(@intFromPtr(mem.updatePtr(kernel.cpu.CpuContext, ctx)));
            }
        }
    }
};

// --- //

pub const NestedFrame = extern struct {
    xregs: [30]u64, // x0..x29
    link_register: u64, // x30
    elr: u64, // elr_el1
    spsr: u64, // spsr_el1
    esr: u64, // esr_el1
    far: u64, // far_el1
    _reserved: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(NestedFrame) == 288);
    std.debug.assert(@offsetOf(NestedFrame, "link_register") == 240);
    std.debug.assert(@offsetOf(NestedFrame, "elr") == 248);
    std.debug.assert(@offsetOf(NestedFrame, "spsr") == 256);
    std.debug.assert(@offsetOf(NestedFrame, "esr") == 264);
    std.debug.assert(@offsetOf(NestedFrame, "far") == 272);
}

pub const ReducedFrame = extern struct {
    xregs: [30]u64, // x0..x29
    link_register: u64, // x30
    program_counter: u64, // elr OR return_address
    spsr: u64,
    tpidr_el0: u64,
    stack_pointer: u64, // sp_el0
    _reserved: u64 = 0, // alignment padding

    pub fn setArg(self: *ReducedFrame, comptime index: usize, value: u64) void {
        self.xregs[index] = value;
    }

    pub fn getArg(self: *ReducedFrame, comptime index: usize) u64 {
        return self.xregs[index];
    }
};

comptime {
    std.debug.assert(@sizeOf(ReducedFrame) == 288);
    std.debug.assert(@offsetOf(ReducedFrame, "link_register") == 240);
    std.debug.assert(@offsetOf(ReducedFrame, "program_counter") == 248);
    std.debug.assert(@offsetOf(ReducedFrame, "spsr") == 256);
    std.debug.assert(@offsetOf(ReducedFrame, "tpidr_el0") == 264);
    std.debug.assert(@offsetOf(ReducedFrame, "stack_pointer") == 272);
}

pub const ExtendedFrame = extern struct {
    qregs: [32]u128, // q0..q31
    fpcr: u64,
    fpsr: u64,
    reduced_frame: ReducedFrame,
};

comptime {
    std.debug.assert(@sizeOf(ExtendedFrame) == 816);
    std.debug.assert(@offsetOf(ExtendedFrame, "fpcr") == 512);
    std.debug.assert(@offsetOf(ExtendedFrame, "fpsr") == 520);
    std.debug.assert(@offsetOf(ExtendedFrame, "reduced_frame") == 528);
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
    const old_daif = asm volatile ("mrs %[ret], daif"
        : [ret] "=r" (-> u64),
    );
    const was_enabled: InterruptState = if ((old_daif & (1 << 7)) == 0) .enabled else .disabled;

    switch (new) {
        .disabled => asm volatile ("msr daifset, #0b0011" ::: .{ .memory = true }),
        .enabled => asm volatile ("msr daifclr, #0b0011" ::: .{ .memory = true }),
    }
    asm volatile ("isb" ::: .{ .memory = true });

    return was_enabled;
}
