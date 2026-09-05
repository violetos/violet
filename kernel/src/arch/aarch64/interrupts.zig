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

extern fn call_system(code: basalt.system.call.Code, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64) callconv(.{ .aarch64_aapcs = .{} }) basalt.system.call.FullResult;

extern fn restore_reduced_via_eret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_eret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_reduced_via_ret(frame: *ReducedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;
extern fn restore_extended_via_ret(frame: *ExtendedFrame, kernel_stack_reset: u64) callconv(.{ .aarch64_aapcs = .{} }) noreturn;

extern fn extend_frame(frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) *ExtendedFrame;

// --- arch/aarch64/interrupts.zig --- //

const ResumeMode = union(enum) {
    via_ret,
    via_eret: arch.registers.SPSR_EL1,
};

inline fn captureFrame(frame: *ReducedFrame, resume_mode: ResumeMode) void {
    const context = sched.SchedContext.current();
    if (context.current_task) |*task_ref| {
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

fn restoreCurrent(old_frame: *ReducedFrame, old_mode: ResumeMode) noreturn {
    const interrupt_data = blk: {
        const sched_context = sched.SchedContext.current();

        if (sched_context.current_task) |*task_ref| {
            const task: *sched.Task = task_ref.payload();
            break :blk task.interrupt_data;
        } else {
            break :blk InterruptData{
                .frame_state = .{ .reduced_frame = old_frame },
                .resume_mode = old_mode,
            };
        }
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

export fn internal_entry(frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) void {
    captureFrame(frame, .via_ret);
}

export fn internal_exit(old_frame: *ReducedFrame) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    restoreCurrent(old_frame, .via_ret);
}

fn syncHandler(frame: *ReducedFrame, saved_spsr: arch.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    captureFrame(frame, .{ .via_eret = saved_spsr });

    const esr = arch.registers.ESR_EL1.load();

    switch (esr.ec) {
        .svc_inst_aarch64 => {
            const context = sched.SchedContext.current();
            const privileged = if (context.current_task) |*task| task.payload().process.payload().isPrivileged() else true;
            if (privileged) {
                log.err("unexpected svc trapped from a privileged (EL1t) task", .{});
                arch.cpu.halt();
            }

            kernel.syscall.internal_call_system(frame);
        },

        .data_abort_lower_el, .data_abort_same_el, .inst_abort_lower_el, .inst_abort_same_el => {
            const far = arch.registers.loadFarEl1();
            const iss = esr.iss.data_abort;

            switch (iss.dfsc) {
                .translation_fault_lv0, .translation_fault_lv1, .translation_fault_lv2, .translation_fault_lv3 => {
                    log.err("unresolved translation fault at 0x{x}", .{far});
                    arch.cpu.halt();
                },
                else => {
                    log.err("unhandled data/inst abort ({s}) at 0x{x}", .{ @tagName(iss.dfsc), far });
                    arch.cpu.halt();
                },
            }
        },

        .brk_aarch64 => {
            const iss = esr.iss.brk_aarch64;
            const rframe = currentReducedFrame(frame);
            log.debug("breakpoint (comment={}) at 0x{x}", .{ iss.comment, rframe.program_counter });
            rframe.program_counter += 4;
        },

        else => {
            log.err("unexpected synchronous exception", .{});
            esr.dump();
            arch.cpu.halt();
        },
    }

    restoreCurrent(frame, .{ .via_eret = saved_spsr });
}

fn irqHandler(frame: *ReducedFrame, saved_spsr: arch.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    captureFrame(frame, .{ .via_eret = saved_spsr });

    const ctrl = drivers.intc.active_controller orelse {
        log.err("IRQ trapped with no interrupt controller registered", .{});
        arch.cpu.halt();
    };

    if (ctrl.acknowledge()) |irq_id| {
        ctrl.dispatch(irq_id);
    } else {
        log.warn("spurious interrupt", .{});
    }

    restoreCurrent(frame, .{ .via_eret = saved_spsr });
}

fn unexpectedException(_: *ReducedFrame, saved_spsr: arch.registers.SPSR_EL1) callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    _ = saved_spsr;

    log.err("unexpected exception (fiq/serror)", .{});
    arch.registers.ESR_EL1.load().dump();
    arch.cpu.halt();
}

fn nestedSyncHandler(esr_raw: u64, far: u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr: arch.registers.ESR_EL1 = @bitCast(esr_raw);

    switch (esr.ec) {
        .data_abort_same_el, .data_abort_lower_el => {
            const iss = esr.iss.data_abort;
            switch (iss.dfsc) {
                .translation_fault_lv0, .translation_fault_lv1, .translation_fault_lv2, .translation_fault_lv3 => {
                    log.err("unresolved nested translation fault at 0x{x}", .{far});
                    arch.cpu.halt();
                },
                else => {
                    log.err("unhandled nested data/inst abort ({s}) at 0x{x}", .{ @tagName(iss.dfsc), far });
                    arch.cpu.halt();
                },
            }
        },
        else => {
            log.err("unexpected nested synchronous exception", .{});
            esr.dump();
            arch.cpu.halt();
        },
    }
}

fn unexpectedNestedException(esr_raw: u64, _: u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr: arch.registers.ESR_EL1 = @bitCast(esr_raw);
    log.err("unexpected nested exception (irq/fiq/serror)", .{});
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
    cpuInit();
}

pub fn cpuInit() void {
    arch.registers.storeVbarEl1(@intFromPtr(&exception_vector_table));
    const interrupts_context = InterruptsContext.current();
    arch.registers.storeSpEl1(interrupts_context.kernel_stack_top);
}

pub const InterruptsContext = struct {
    kernel_stack_top: u64,

    pub fn init(self: *InterruptsContext) !void {
        const stack_size = 512 * 1024; // 512 KiB
        const pages_count = stack_size / mem.paging.page_size;
        self.kernel_stack_top = (mem.hhdm_offset + try mem.phys.allocContiguous(pages_count)) + stack_size;
    }

    pub fn current() *InterruptsContext {
        return &kernel.cpu.CpuContext.current().?.interrupts_context;
    }

    pub fn updateHhdm(self: *InterruptsContext) void {
        self.kernel_stack_top = @intFromPtr(mem.updatePtr(anyopaque, @ptrFromInt(self.kernel_stack_top)));
    }
};

// --- //

pub const ReducedFrame = extern struct {
    xregs: [30]u64, // x0..x29
    link_register: u64, // x30
    program_counter: u64, // elr_el1 OR return_address
    spsr_el1: u64,
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
    std.debug.assert(@offsetOf(ReducedFrame, "spsr_el1") == 256);
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
