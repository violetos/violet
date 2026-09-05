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

// --- imports --- //

const kernel = @import("root");

const drivers = kernel.drivers;
const acpi = drivers.acpi;

// --- drivers/serial/uart_pl011.zig --- //

pub const architectures: []const std.Target.Cpu.Arch = &.{ .aarch64, .x86_64, .riscv64 };
pub const discover_stage: ?drivers.Stage = .stage2;

var instances: [2]@This() = @splat(undefined);

pub fn discover(comptime stage: drivers.Stage, xsdt: ?*const acpi.Xsdt, dt: ?void) !void {
    if (stage != .stage2) return;

    if (xsdt) |x| try xsdtDiscover(stage, x);
    if (dt) |d| try dtDiscover(stage, d);
}

inline fn xsdtDiscover(comptime stage: drivers.Stage, xsdt: *const acpi.Xsdt) !void {
    _ = stage;

    const spcr = xsdt.find(acpi.Spcr) orelse return;

    switch (spcr.interface_type) {
        .arm_pl011, .arm_sbsa_generic_uart => {},
        else => return,
    }

    switch (spcr.base_address.address_space_id) {
        .system_memory => {
            instances[0] = .{
                .peripheral_base = try kernel.mem.virt.mmio(
                    spcr.base_address.address,
                    kernel.mem.paging.page_size,
                ),
            };
        },
        else => return,
    }

    const self = &instances[0];

    self.disableUart();
    self.maskAllInterrupts();

    self.writeLineControl(.{
        .brk = false,
        .par = spcr.parity != .none,
        .eps = false,
        .stp2 = spcr.stop_bits != .one,
        .fen = true,
        .wlen = .u8,
        .sps = false,
    });

    const nbaud_rate: ?u32 = if (spcr.preciseBaudRate()) |pbr| pbr else switch (spcr.configured_baud_rate) {
        .as_is => null,
        .rate_9600 => 9600,
        .rate_19200 => 19200,
        .rate_57600 => 57600,
        .rate_115200 => 115200,
        else => return, // unknown
    };

    if (nbaud_rate) |baud_rate| {
        const clock_frequency = spcr.uartClockFrequency() orelse 48_000_000;

        const baud_div = @as(f32, @floatFromInt(clock_frequency)) / @as(f32, @floatFromInt(16 * baud_rate));

        const ibrd = @as(u16, @intFromFloat(@floor(baud_div)));
        const fbrd = @as(u6, @intFromFloat(@round((baud_div - @as(f32, @floatFromInt(ibrd))) * 64)));

        self.setIntegerBaudRate(ibrd);
        self.setFractionalBaudRate(fbrd);
    }

    self.enableReceive();
    self.enableTransmit();

    self.enableUart();

    drivers.serial.register(.{
        .name = "pl011",
        .context = @ptrCast(self),
        .vtable = .{ .write = write, .read = null },
    }, 15);
}

inline fn dtDiscover(comptime stage: drivers.Stage, dt: void) !void {
    _ = stage;
    _ = dt;

    // instances[1]
}

const Self = @This();

peripheral_base: u64,

fn write(context: *anyopaque, data: []const u8) void {
    const self: *const Self = @ptrCast(@alignCast(context));

    for (data) |byte| {
        if (byte == '\n') self.writeChar('\r');
        self.writeChar(byte);
    }
}

inline fn writeChar(self: *const Self, char: u8) void {
    while (self.readFlag().transmit_fifo_full) kernel.arch.cpu.pause();
    self.dataPtr().* = char;
    while (self.readFlag().busy) kernel.arch.cpu.pause();
}

// --- registers --- //

/// Data Register (Read-write)
const UART_DR = 0x000;

inline fn dataPtr(self: *const Self) *volatile u8 {
    const dr: *volatile u8 = @ptrFromInt(self.peripheral_base + UART_DR);

    return dr;
}

/// Receive Status Register / Error Clear Register (Read-write)
const UART_RSR_ECR = 0x004;

/// Flag Register (Read-only)
const UART_FR = 0x018;

const FlagRegister = packed struct(u16) {
    clear_to_send: bool,
    data_set_ready: bool,
    data_carier_detect: bool,
    busy: bool,
    receive_fifo_empty: bool,
    transmit_fifo_full: bool,
    receive_fifo_full: bool,
    transmit_fifo_empty: bool,
    ring_indicator: bool,
    _reserved: u7,
};

inline fn readFlag(self: *const Self) FlagRegister {
    const fr: *volatile FlagRegister = @ptrFromInt(self.peripheral_base + UART_FR);

    return fr.*;
}

/// IrDA Low-Power Counter Register (Read-write)
const UART_ILPR = 0x020;

/// Integer Baud Rate Register (Read-write)
const UART_IBRD = 0x024;

inline fn setIntegerBaudRate(self: *const Self, value: u16) void {
    const ibrd: *volatile u16 = @ptrFromInt(self.peripheral_base + UART_IBRD);

    ibrd.* = value;
}

/// Fractional Baud Rate Register (Read-write)
const UART_FBRD = 0x028;

inline fn setFractionalBaudRate(self: *const Self, value: u6) void {
    const fbrd: *volatile u8 = @ptrFromInt(self.peripheral_base + UART_FBRD);

    fbrd.* = value;
}

/// Line Control Register (Read-write)
const UART_LCR_H = 0x02c;

const LineControlRegister = packed struct(u8) {
    /// Send break.
    brk: bool, // bit 0
    /// Parity enable.
    par: bool, // bit 1
    /// Even parity select.
    eps: bool, // bit 2
    /// Two stop bits select.
    stp2: bool, // bit 3
    /// Enable FIFOs
    fen: bool, // bit 4
    /// Word length.
    wlen: enum(u2) { // bit 5-6
        u8 = 0b11,
        u7 = 0b10,
        u6 = 0b01,
        u5 = 0b00,
    },
    /// Stick parity select.
    sps: bool, // bit 7
};

inline fn lineControlPtr(self: *const Self) *volatile LineControlRegister {
    return @ptrFromInt(self.peripheral_base + UART_LCR_H);
}

inline fn readLineControl(self: *const Self) LineControlRegister {
    const lcr = self.lineControlPtr();

    return lcr.*;
}

inline fn writeLineControl(self: *const Self, value: LineControlRegister) void {
    const lcr = self.lineControlPtr();

    lcr.* = value;
}

/// Control Register (Read-write)
const UART_CR = 0x030;

const ControlRegister = packed struct(u16) {
    /// Uart enable.
    uarten: bool, // bit 0
    /// SIR enable.
    siren: bool, // bit 1
    /// SIR low-power IrDA mode.
    sirlp: bool, // bit 2
    /// Do not modify.
    _reserved0: u4, // bit 3-6
    /// Loop Back enable.
    lbe: bool, // bit 7
    /// Transmit enable.
    txe: bool, // bit 8
    /// Receive enable.
    rxe: bool, // bit 9
    /// Data transmit ready.
    dtr: bool, // bit 10
    /// Request to send.
    rts: bool, // bit 11
    out1: u1, // bit 12
    out2: u1, // bit 13
    /// RTS hardware flow control enable.
    rts_en: bool, // bit 14
    /// CTS hardware flow control enable.
    cts_en: bool, // bit 15
};

inline fn controlPtr(self: *const Self) *volatile ControlRegister {
    return @ptrFromInt(self.peripheral_base + UART_CR);
}

inline fn enableUart(self: *const Self) void {
    const cr = self.controlPtr();
    cr.uarten = true;

    kernel.arch.cpu.syncMem();
}

inline fn disableUart(self: *const Self) void {
    const cr = self.controlPtr();
    cr.uarten = false;

    kernel.arch.cpu.syncMem();
}

inline fn enableTransmit(self: *const Self) void {
    const cr = self.controlPtr();
    cr.txe = true;
}

inline fn disableTransmit(self: *const Self) void {
    const cr = self.controlPtr();
    cr.txe = false;
}

inline fn enableReceive(self: *const Self) void {
    const cr = self.controlPtr();
    cr.rxe = true;
}

inline fn disableReceive(self: *const Self) void {
    const cr = self.controlPtr();
    cr.rxe = false;
}

/// Interrupt FIFO Level Select Register (Read-write)
const UART_IFLS = 0x034;

/// Interrupt Mask Set/Clear Register (Read-write)
const UART_IMSC = 0x038;

const InterruptMaskSetClearRegister = packed struct(u16) {
    /// nUARTRI modem interrupt mask.
    rimim: bool, // bit 0
    /// nUARTCTS modem interrupt mask.
    ctsmim: bool, // bit 1
    /// nUARTDCD modem interrupt mask.
    dcdmim: bool, // bit 2
    /// nUARTDSR modem interrupt mask.
    dsrmim: bool, // bit 3
    /// Receive interrupt mask.
    rxim: bool, // bit 4
    /// Transmit interrupt mask.
    txim: bool, // bit 5
    /// Receive timeout interrupt mask.
    rtim: bool, // bit 6
    /// Framing error interrupt mask.
    feim: bool, // bit 7
    /// Parity error interrupt mask.
    peim: bool, // bit 8
    /// Break error interrupt mask.
    beim: bool, // bit 9
    /// Overrun error interrupt mask.
    oeim: bool, // bit 10
    /// Do not modify.
    _reserved: u5, // bit 11-15
};

inline fn interruptMaskPtr(self: *const Self) *volatile InterruptMaskSetClearRegister {
    return @ptrFromInt(self.peripheral_base + UART_IMSC);
}

inline fn maskAllInterrupts(self: *const Self) void {
    const imsc = self.interruptMaskPtr();
    imsc.* = .{
        .rimim = true,
        .ctsmim = true,
        .dcdmim = true,
        .dsrmim = true,
        .rxim = true,
        .txim = true,
        .rtim = true,
        .feim = true,
        .peim = true,
        .beim = true,
        .oeim = true,
        ._reserved = imsc._reserved,
    };
}

/// Raw Interrupt Status Register (Read-only)
const UART_RIS = 0x03c;

/// Masked Interrupt Status Register (Read-only)
const UART_MIS = 0x040;

/// Interrupt Clear Register (Write-only)
const UART_ICR = 0x044;

/// DMA Control Register (Read-write)
const UART_DMACR = 0x048;
