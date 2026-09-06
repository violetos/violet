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
    _ = stage;

    if (xsdt) |x| try xsdtDiscover(x);
    if (dt) |d| try dtDiscover(d);
}

inline fn xsdtDiscover(xsdt: *const acpi.Xsdt) !void {
    var address: u64 = 0;
    var address_space_id: acpi.Gas.AddressSpaceId = undefined;
    var access_size: u8 = 0;
    var register_bit_width: u8 = 0;

    var is_pre_initialized = false;
    var spcr_ref: ?*const acpi.Spcr = null;

    if (xsdt.find(acpi.Spcr)) |spcr| {
        switch (spcr.interface_type) {
            .arm_pl011, .arm_sbsa_generic_uart, .arm_sbsa_generic_uart_2 => {
                address = spcr.base_address.address;
                address_space_id = spcr.base_address.address_space_id;
                access_size = @intFromEnum(spcr.base_address.access_size);
                register_bit_width = spcr.base_address.register_bit_width;

                is_pre_initialized = (spcr.configured_baud_rate == .as_is);
                spcr_ref = spcr;
            },
            else => {},
        }
    }

    if (address == 0) {
        if (xsdt.find(acpi.Dbg2)) |dbg2| {
            var i: u32 = 0;
            while (dbg2.getDevice(i)) |dev| : (i += 1) {
                if (dev.port_type == .serial) {
                    const subtype: acpi.DebugDeviceInformation.PortSubtypeSerial = @enumFromInt(dev.port_subtype);
                    switch (subtype) {
                        .arm_pl011, .arm_sbsa_generic_uart => {
                            if (dev.getBaseAddress(0)) |gas| {
                                address = gas.address;
                                address_space_id = gas.address_space_id;
                                access_size = @intFromEnum(gas.access_size);
                                register_bit_width = gas.register_bit_width;

                                is_pre_initialized = true;
                            }
                            break;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    if (address == 0) return;
    if (address_space_id != .system_memory) return;

    const calc_stride: usize = if (access_size > 0)
        @as(usize, 1) << @intCast(access_size - 1)
    else
        @as(usize, register_bit_width) / 8;

    instances[0] = .{
        .peripheral_base = try kernel.mem.virt.mmio(
            address,
            kernel.mem.paging.page_size,
        ),
        .stride = if (calc_stride == 0) 4 else calc_stride,
    };

    const self = &instances[0];

    if (!is_pre_initialized and spcr_ref != null) {
        const spcr = spcr_ref.?;

        self.disableUart();
        self.maskAllInterrupts();

        const nbaud_rate: ?u32 = if (spcr.preciseBaudRate()) |pbr| pbr else switch (spcr.configured_baud_rate) {
            .as_is => null,
            .rate_9600 => 9600,
            .rate_19200 => 19200,
            .rate_57600 => 57600,
            .rate_115200 => 115200,
            else => null,
        };

        if (nbaud_rate) |baud_rate| {
            const clock_frequency = spcr.uartClockFrequency() orelse 48_000_000;
            const dividend = clock_frequency;
            const divisor = 16 * baud_rate;

            const ibrd = @as(u16, @intCast(dividend / divisor));
            const remainder = dividend % divisor;
            const fbrd = @as(u6, @intCast(((remainder * 64) + (divisor / 2)) / divisor));

            self.writeReg(UART_IBRD, @as(u32, ibrd));
            self.writeReg(UART_FBRD, @as(u32, fbrd));
        }

        self.writeReg(UART_LCR_H, LineControlRegister{
            .brk = false,
            .par = spcr.parity != .none,
            .eps = false,
            .stp2 = spcr.stop_bits != .one,
            .fen = true,
            .wlen = .u8,
            .sps = false,
            ._reserved = 0,
        });

        self.enableReceive();
        self.enableTransmit();
        self.enableUart();
    } else {
        self.maskAllInterrupts();
    }

    drivers.serial.register(.{
        .name = "pl011",
        .context = @ptrCast(self),
        .vtable = .{ .write = write, .read = null },
    }, 15);
}

inline fn dtDiscover(dt: void) !void {
    _ = dt;

    // instances[1]
}

const Self = @This();

peripheral_base: usize,
stride: usize,

inline fn readReg(self: *const Self, comptime T: type, index: usize) T {
    const ptr: *volatile u32 = @ptrFromInt(self.peripheral_base + (index * self.stride));
    if (T == u32) return ptr.*;
    return @bitCast(ptr.*);
}

inline fn writeReg(self: *const Self, index: usize, value: anytype) void {
    const ptr: *volatile u32 = @ptrFromInt(self.peripheral_base + (index * self.stride));
    const T = @TypeOf(value);
    if (T == u32) {
        ptr.* = value;
    } else {
        ptr.* = @bitCast(value);
    }
}

fn write(context: *anyopaque, data: []const u8) void {
    const self: *const Self = @ptrCast(@alignCast(context));

    for (data) |byte| {
        if (byte == '\n') self.writeChar('\r');
        self.writeChar(byte);
    }
}

inline fn writeChar(self: *const Self, char: u8) void {
    while (self.readReg(FlagRegister, UART_FR).transmit_fifo_full) kernel.arch.cpu.pause();
    self.writeReg(UART_DR, @as(u32, char));
    while (self.readReg(FlagRegister, UART_FR).busy) kernel.arch.cpu.pause();
}

const UART_DR = 0;
const UART_RSR_ECR = 1;
const UART_FR = 6;
const UART_ILPR = 8;
const UART_IBRD = 9;
const UART_FBRD = 10;
const UART_LCR_H = 11;
const UART_CR = 12;
const UART_IFLS = 13;
const UART_IMSC = 14;
const UART_RIS = 15;
const UART_MIS = 16;
const UART_ICR = 17;
const UART_DMACR = 18;

const FlagRegister = packed struct(u32) {
    clear_to_send: bool,
    data_set_ready: bool,
    data_carier_detect: bool,
    busy: bool,
    receive_fifo_empty: bool,
    transmit_fifo_full: bool,
    receive_fifo_full: bool,
    transmit_fifo_empty: bool,
    ring_indicator: bool,
    _reserved: u23, // 32 - 9 bits
};

const LineControlRegister = packed struct(u32) {
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
    _reserved: u24, // bits 8 - 32
};

const ControlRegister = packed struct(u32) {
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
    _reserved1: u16, // bits 16 - 32
};

inline fn enableUart(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.uarten = true;
    self.writeReg(UART_CR, cr);
    kernel.arch.cpu.syncMem();
}

inline fn disableUart(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.uarten = false;
    self.writeReg(UART_CR, cr);
    kernel.arch.cpu.syncMem();
}

inline fn enableTransmit(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.txe = true;
    self.writeReg(UART_CR, cr);
}

inline fn disableTransmit(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.txe = false;
    self.writeReg(UART_CR, cr);
}

inline fn enableReceive(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.rxe = true;
    self.writeReg(UART_CR, cr);
}

inline fn disableReceive(self: *const Self) void {
    var cr = self.readReg(ControlRegister, UART_CR);
    cr.rxe = false;
    self.writeReg(UART_CR, cr);
}

const InterruptMaskSetClearRegister = packed struct(u32) {
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
    _reserved: u21, // bits 11 - 32
};

inline fn maskAllInterrupts(self: *const Self) void {
    self.writeReg(UART_IMSC, InterruptMaskSetClearRegister{
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
        ._reserved = 0,
    });
}
