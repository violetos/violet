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

// --- drivers/timer/riscv_sstc.zig --- //

var freq_hz: u64 = 0;
var boot_offset: u64 = 0;

inline fn ticksToNs(ticks: u64) u64 {
    return @intCast((@as(u128, ticks) * 1_000_000_000) / freq_hz);
}

inline fn nsToTicks(ns: u64) u64 {
    return @intCast((@as(u128, ns) * freq_hz) / 1_000_000_000);
}

fn vUptimeNs(_: *anyopaque) u64 {
    return ticksToNs(readTime() - boot_offset);
}

fn vArm(_: *anyopaque, deadline_ns: u64) void {
    writeStimecmp(boot_offset + nsToTicks(deadline_ns));
    vMask(undefined, false);
}

fn vMask(_: *anyopaque, masked: bool) void {
    if (masked) {
        csrClear(CSR_SIE, SIE_STIE);
    } else {
        csrSet(CSR_SIE, SIE_STIE);
    }
}

fn vInit(_: *anyopaque) anyerror!void {
    vMask(undefined, true);
    writeStimecmp(std.math.maxInt(u64));
}

fn vOnInterrupt(_: *anyopaque) void {
    vMask(undefined, true);

    drivers.timer.handle() catch |err| {
        std.log.err("timer handling failed: {any}", .{err});
    };
}

const vtable: drivers.timer.TimerImpl.VTable = .{
    .initPerCpu = vInit,
    .now = vUptimeNs,
    .arm = vArm,
    .setMask = vMask,
    .onInterrupt = vOnInterrupt,
};

fn asTimer() drivers.timer.TimerImpl {
    return .{ .ptr = undefined, .vtable = &vtable };
}

// --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{.riscv64};
pub const discover_stage: ?drivers.Stage = .stage4;

var discovered = false;

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    _ = stage;

    if (xsdt) |x| try xsdtDiscover(x);
    if (dt) |d| try dtDiscover(d);
}

inline fn xsdtDiscover(xsdt: *const acpi.Xsdt) !void {
    const rhct = xsdt.find(acpi.Rhct) orelse return;

    freq_hz = rhct.time_base_freq;
    if (freq_hz == 0) return error.InvalidFrequency;

    boot_offset = readTime();

    drivers.timer.impl = asTimer();

    discovered = true;
}

inline fn dtDiscover(dt: void) !void {
    if (discovered) return;

    _ = dt;
}

// --- //

/// `sie` (Supervisor Interrupt Enable, CSR 0x104).
const CSR_SIE = "0x104";
/// `stimecmp` (Supervisor Time Comparator, CSR 0x14D - Sstc extension).
const CSR_STIMECMP = "0x14d";
/// `time` (Real-time counter, CSR 0xC01).
const CSR_TIME = "0xc01";

/// Supervisor Timer Interrupt Enable bit in `sie` (bit 5).
const SIE_STIE: u64 = 1 << 5;

inline fn readTime() u64 {
    return asm volatile ("csrr %[r], " ++ CSR_TIME
        : [r] "=r" (-> u64),
    );
}

inline fn readStimecmp() u64 {
    return asm volatile ("csrr %[r], " ++ CSR_STIMECMP
        : [r] "=r" (-> u64),
    );
}

inline fn writeStimecmp(v: u64) void {
    asm volatile ("csrw " ++ CSR_STIMECMP ++ ", %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

inline fn csrSet(comptime csr: []const u8, mask: u64) void {
    asm volatile ("csrrs zero, " ++ csr ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}

inline fn csrClear(comptime csr: []const u8, mask: u64) void {
    asm volatile ("csrrc zero, " ++ csr ++ ", %[mask]"
        :
        : [mask] "r" (mask),
        : .{ .memory = true });
}
