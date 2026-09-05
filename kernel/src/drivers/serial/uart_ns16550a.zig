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

const kernel = @import("root");

const drivers = kernel.drivers;
const acpi = drivers.acpi;

const mem = kernel.mem;

// --- drivers/serial/uart_ns16550a.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{ .aarch64, .x86_64, .riscv64 };
pub const discover_stage: ?drivers.Stage = null;

var instances: [3]@This() = @splat(undefined);

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    if (xsdt) |x| try xsdtDiscover(stage, x);
    if (dt) |d| try dtDiscover(stage, d);

    if (builtin.cpu.arch == .x86_64 and stage == .stage0 and !(xsdt_discovered or dt_discovered)) {
        instances[2] = .{
            .bus = .{ .pio = 0x3f8 },
        };

        try init(&instances[2], 1, 1);
    }
}

var xsdt_discovered = false;
inline fn xsdtDiscover(comptime stage: drivers.Stage, xsdt: *const acpi.Xsdt) !void {
    if (xsdt_discovered) return;

    const spcr = xsdt.find(acpi.Spcr) orelse return;

    switch (spcr.interface_type) {
        .full_16550, .full_16450, .ns16550a_generic => {},
        else => return,
    }

    const divisor: ?u16 = switch (spcr.configured_baud_rate) {
        .as_is => null,
        .rate_9600 => 12,
        .rate_19200 => 6,
        .rate_57600 => 2,
        .rate_115200 => 1,
        else => return, // reserved (so unknown!)
    };

    instances[0] = .{
        .bus = switch (spcr.base_address.address_space_id) {
            .system_io => .{ .pio = @intCast(spcr.base_address.address) },
            .system_memory => blk: {
                if (stage != .stage2) return;

                const access_size = @intFromEnum(spcr.base_address.access_size);
                const stride: usize = if (access_size > 0)
                    @as(usize, 1) << @intCast(access_size - 1)
                else
                    @as(usize, spcr.base_address.register_bit_width) / 8;

                break :blk .{ .mmio = .{ .base = try kernel.mem.virt.mmio(
                    spcr.base_address.address,
                    kernel.mem.paging.page_size,
                ), .stride = if (stride == 0) 1 else stride } };
            },
            else => return,
        },
    };

    try init(&instances[0], divisor, 10);

    xsdt_discovered = true;
}

var dt_discovered = false;
inline fn dtDiscover(comptime stage: drivers.Stage, dt: void) !void {
    _ = stage;
    _ = dt;

    if (dt_discovered) return;

    // instances[1]
}

bus: Bus,

fn init(self: *@This(), divisor: ?u16, priority: usize) !void {
    // Disable all UART interrupts (Interrupt Enable Register)
    self.bus.writeReg(1, 0x00);

    if (divisor) |div| {
        // Enable DLAB (Divisor Latch Access Bit) to write the divisor
        self.bus.writeReg(3, 0x80);
        // Divisor LSB (Least Significant Byte)
        self.bus.writeReg(0, @truncate(div));
        // Divisor MSB (Most Significant Byte)
        self.bus.writeReg(1, @truncate(div >> 8));
    }

    // 8 data bits, no parity, 1 stop bit (also clears DLAB back to 0)
    self.bus.writeReg(3, 0x03);

    // Enable and clear both TX and RX FIFO buffers
    self.bus.writeReg(2, 0xC7);

    // Data Terminal Ready (DTR) + Request To Send (RTS) + OUT2 (required to enable IRQs on legacy PCs)
    self.bus.writeReg(4, 0x0B);

    drivers.serial.register(.{
        .name = "ns16550a",
        .context = @ptrCast(self),
        .vtable = .{ .write = write, .read = null },
    }, priority);
}

fn write(context: *anyopaque, str: []const u8) void {
    const self: *const @This() = @ptrCast(@alignCast(context));

    for (str) |char| {
        if (char == '\n') self.bus.writeChar('\r');
        self.bus.writeChar(char);
    }
}

const Bus = union(enum) {
    pio: u16,
    mmio: struct { base: usize, stride: usize },

    pub fn readReg(self: Bus, offset: usize) u8 {
        return switch (self) {
            .pio => |base_port| inb(base_port + @as(u16, @intCast(offset))),
            .mmio => |m| @as(*volatile u8, @ptrFromInt(m.base + offset * m.stride)).*,
        };
    }

    pub fn writeReg(self: Bus, offset: usize, value: u8) void {
        switch (self) {
            .pio => |base_port| outb(base_port + @as(u16, @intCast(offset)), value),
            .mmio => |m| @as(*volatile u8, @ptrFromInt(m.base + offset * m.stride)).* = value,
        }
    }

    pub fn writeChar(self: Bus, byte: u8) void {
        while (self.readReg(5) & 0x20 == 0) kernel.arch.cpu.pause();
        self.writeReg(0, byte);
    }

    inline fn inb(port: u16) u8 {
        if (comptime builtin.cpu.arch != .x86_64) unreachable;
        return asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8),
            : [port] "N{dx}" (port),
        );
    }

    inline fn outb(port: u16, value: u8) void {
        if (comptime builtin.cpu.arch != .x86_64) unreachable;
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "N{dx}" (port),
        );
    }
};
