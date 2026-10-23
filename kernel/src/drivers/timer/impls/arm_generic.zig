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

const drivers = kernel.drivers;
const acpi = drivers.acpi;
const intc = drivers.intc;

const Domain = intc.Domain;

// --- drivers/timer/arm_generic.zig --- //

var freq_hz: u64 = 0;
var boot_offset: u64 = 0;

inline fn ticksToNs(ticks: u64) u64 {
    return @intCast((@as(u128, ticks) * 1_000_000_000) / freq_hz);
}

inline fn nsToTicks(ns: u64) u64 {
    return @intCast((@as(u128, ns) * freq_hz) / 1_000_000_000);
}

fn vUptimeNsV(_: *anyopaque) u64 {
    return ticksToNs(readCntvct() - boot_offset);
}

fn vArmV(_: *anyopaque, deadline_ns: u64) void {
    writeCntvCval(boot_offset + nsToTicks(deadline_ns));
    writeCntvCtl(.{ .enable = true, .imask = false });
}

fn vMaskV(_: *anyopaque, masked: bool) void {
    var ctl = readCntvCtl();
    ctl.imask = masked;
    writeCntvCtl(ctl);
}

fn vInitV(_: *anyopaque) anyerror!void {
    vMaskV(undefined, true);

    try commonInit(false);
}

const vtable_el1: drivers.timer.TimerImpl.VTable = .{
    .initPerCpu = vInitV,
    .now = vUptimeNsV,
    .arm = vArmV,
    .setMask = vMaskV,
};

fn vUptimeNsP(_: *anyopaque) u64 {
    return ticksToNs(readCntpct() - boot_offset);
}

fn vArmP(_: *anyopaque, deadline_ns: u64) void {
    writeCntpCval(boot_offset + nsToTicks(deadline_ns));
    writeCntpCtl(.{ .enable = true, .imask = false });
}

fn vMaskP(_: *anyopaque, masked: bool) void {
    var ctl = readCntpCtl();
    ctl.imask = masked;
    writeCntpCtl(ctl);
}

fn vInitP(_: *anyopaque) anyerror!void {
    vMaskP(undefined, true);

    try commonInit(true);
}

fn topHalfP(_: *anyopaque) callconv(basalt.system.call_conv) bool {
    vMaskP(undefined, true);

    drivers.timer.handle() catch |err| {
        std.log.err("timer handling failed: {any}", .{err});
    };

    return true;
}

fn topHalfV(_: *anyopaque) callconv(basalt.system.call_conv) bool {
    vMaskV(undefined, true);

    drivers.timer.handle() catch |err| {
        std.log.err("timer handling failed: {any}", .{err});
    };

    return true;
}

fn commonInit(is_phys: bool) !void {
    const ic_ref: Domain.Ref = try intc.getRootRef();
    const ic: *Domain = ic_ref.payload();

    _ = try ic.register(ic_ref, .{
        .hardware_irq = @intCast(gsiv),
        .kind = .handler,
        .content = .{
            .handler = .{
                .context = undefined,
                .top_half = if (is_phys) &topHalfP else &topHalfV,
                .future = .null,
            },
        },
        .priority = 0x30,
        .trigger_mode = if (flags.mode == .edge_triggered) .edge_rising else .level_high,
    });
}

const vtable_el2: drivers.timer.TimerImpl.VTable = .{
    .initPerCpu = vInitP,
    .now = vUptimeNsP,
    .arm = vArmP,
    .setMask = vMaskP,
};

var active_vtable: *const drivers.timer.TimerImpl.VTable = undefined;
var gsiv: u32 = undefined;
var flags: acpi.TimerFlags = undefined;

fn asTimer() drivers.timer.TimerImpl {
    return .{ .ptr = undefined, .vtable = active_vtable };
}

// --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.aarch64};
pub const discover_stage: ?drivers.Stage = .stage4;

var discovered = false;

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    _ = stage;

    if (xsdt) |x| try xsdtDiscover(x);
    if (dt) |d| try dtDiscover(d);
}

inline fn xsdtDiscover(xsdt: *const acpi.Xsdt) !void {
    const gtdt = xsdt.find(acpi.Gtdt) orelse return;

    const el2 = kernel.arch.registers.currentEL().isEl2();
    active_vtable = if (el2) &vtable_el2 else &vtable_el1;

    freq_hz = readCntfrq();
    if (freq_hz == 0) return error.InvalidFrequency;

    gsiv = if (el2) gtdt.el2_gsiv else gtdt.el1_virtual_gsiv;
    flags = if (el2) gtdt.el2_flags else gtdt.el1_virtual_flags;

    boot_offset = if (el2) readCntpct() else readCntvct();

    drivers.timer.impl = asTimer();

    discovered = true;
}

inline fn dtDiscover(dt: void) !void {
    if (discovered) return;

    _ = dt;
}

// --- registers --- //

inline fn readCntfrq() u64 {
    return asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
}

const CntCtl = packed struct(u64) {
    enable: bool = false,
    imask: bool = false,
    istatus: bool = false,
    _reserved: u61 = 0,
};

inline fn readCntvct() u64 {
    return asm volatile ("mrs %[r], cntvct_el0"
        : [r] "=r" (-> u64),
    );
}

inline fn writeCntvCval(v: u64) void {
    asm volatile ("msr cntv_cval_el0, %[v]"
        :
        : [v] "r" (v),
    );
}

inline fn readCntvCtl() CntCtl {
    return @bitCast(asm volatile ("mrs %[r], cntv_ctl_el0"
        : [r] "=r" (-> u64),
    ));
}

inline fn writeCntvCtl(ctl: CntCtl) void {
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, @bitCast(ctl))),
    );
    asm volatile ("isb" ::: .{ .memory = true });
}

inline fn readCntpct() u64 {
    return asm volatile ("mrs %[r], cntpct_el0"
        : [r] "=r" (-> u64),
    );
}

inline fn writeCntpCval(v: u64) void {
    asm volatile ("msr cntp_cval_el0, %[v]"
        :
        : [v] "r" (v),
    );
}

inline fn readCntpCtl() CntCtl {
    return @bitCast(asm volatile ("mrs %[r], cntp_ctl_el0"
        : [r] "=r" (-> u64),
    ));
}

inline fn writeCntpCtl(ctl: CntCtl) void {
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, @bitCast(ctl))),
    );
    asm volatile ("isb" ::: .{ .memory = true });
}
