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

const mem = kernel.mem;

// --- drivers/acpi.zig --- //

pub const Rsdp = extern struct {
    pub const SIGNATURE = "RSD PTR ";

    // ACPI 1.0
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,

    // ACPI 2.0+
    length: u32,
    xsdt_address: u64 align(4),
    extended_checksum: u8,
    reserved: [3]u8,

    pub fn isValid(self: *const Rsdp) bool {
        const bytes = std.mem.asBytes(self);

        if (!std.mem.eql(u8, &self.signature, SIGNATURE)) return false;

        if (self.revision < 2) return false;

        var basic_sum: u8 = 0;
        for (bytes[0..20]) |b| basic_sum +%= b;
        if (basic_sum != 0) return false;

        var extended_sum: u8 = 0;
        for (bytes) |b| extended_sum +%= b;

        return extended_sum == 0;
    }

    comptime {
        if (@sizeOf(Rsdp) != 36) @compileError("Rsdp should have a size of 36");

        if (@offsetOf(Rsdp, "signature") != 0) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "checksum") != 8) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "oem_id") != 9) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "revision") != 15) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "rsdt_address") != 16) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "length") != 20) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "xsdt_address") != 24) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "extended_checksum") != 32) @compileError("Incorrect offset");
        if (@offsetOf(Rsdp, "reserved") != 33) @compileError("Incorrect offset");
    }
};

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: u64 align(4),
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn isValid(self: *const SdtHeader) bool {
        const table_bytes = @as([*]const u8, @ptrCast(self))[0..self.length];

        var sum: u8 = 0;
        for (table_bytes) |b| {
            sum +%= b;
        }

        return sum == 0;
    }

    comptime {
        if (@sizeOf(SdtHeader) != 36) @compileError("SdtHeader should have a size of 36");
        if (@offsetOf(SdtHeader, "creator_revision") != 32) @compileError("Incorrect offset");
    }
};

pub const Xsdt = extern struct {
    pub const SIGNATURE = "XSDT";

    header: SdtHeader,

    pub fn isValid(self: *const Xsdt) bool {
        if (!std.mem.eql(u8, &self.header.signature, SIGNATURE)) return false;

        return self.header.isValid();
    }

    pub fn entryCount(self: *const Xsdt) usize {
        if (self.header.length < @sizeOf(SdtHeader)) return 0;
        return (self.header.length - @sizeOf(SdtHeader)) / @sizeOf(u64);
    }

    pub fn entries(self: *const Xsdt) []align(4) const u64 {
        const count = self.entryCount();

        const entries_addr = @intFromPtr(self) + @sizeOf(SdtHeader);
        const entries_ptr = @as([*]align(4) const u64, @ptrFromInt(entries_addr));

        return entries_ptr[0..count];
    }

    pub fn find(self: *const Xsdt, comptime Table: type) ?*const Table {
        for (self.entries()) |entry_pa| {
            const table = mem.toHhdm(Table, entry_pa);
            const header: *SdtHeader = &table.header;

            if (!std.mem.eql(u8, &header.signature, Table.SIGNATURE)) continue;
            if (!header.isValid()) continue;

            return table;
        }

        return null;
    }
};

pub const Gas = extern struct {
    address_space_id: AddressSpaceId,
    register_bit_width: u8,
    register_bit_offset: u8,
    access_size: AccessSize,

    address: u64 align(4),

    pub const AddressSpaceId = enum(u8) {
        system_memory = 0,
        system_io = 1,
        pci_config_space = 2,
        embedded_controller = 3,
        smbus = 4,
        system_cmos = 5,
        pci_bar_target = 6,
        ipmi = 7,
        general_purpose_io = 8,
        generic_serial_bus = 9,
        platform_comms_channel = 10,
        platform_runtime_mechanism = 11,
        functional_fixed_hardware = 0x7F,
        _, // 0x0C-0x7E reserved, 0x80-0xFF OEM defined
    };

    pub const AccessSize = enum(u8) {
        undefined_size = 0,
        byte = 1,
        word = 2,
        dword = 3,
        qword = 4,
        _, // reserved
    };

    comptime {
        if (@sizeOf(Gas) != 12) @compileError("Gas should have a size of 12");
    }
};

pub const Madt = extern struct {
    pub const SIGNATURE = "APIC";

    header: SdtHeader,
    local_interrupt_controller_address: u32,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        pcat_compat: bool = false,
        _reserved: u31 = 0,
    };

    pub fn iterator(self: *const Madt) Iterator {
        const base: [*]const u8 = @ptrCast(self);
        return .{
            .current = base + @sizeOf(Madt),
            .end = base + self.header.length,
        };
    }

    pub const Record = union(enum) {
        local_apic: *const LocalApic,
        io_apic: *const IoApic,
        interrupt_source_override: *const InterruptSourceOverride,
        nmi_source: *const NmiSource,
        local_apic_nmi: *const LocalApicNmi,
        local_apic_address_override: *const LocalApicAddressOverride,
        local_x2apic: *const LocalX2Apic,
        local_x2apic_nmi: *const LocalX2ApicNmi,
        gicc: *const Gicc,
        gicd: *const Gicd,
        gic_msi_frame: *const GicMsiFrame,
        gicr: *const Gicr,
        gic_its: *const GicIts,
        riscv_intc: *const RiscvIntc,
        unknown: *const RecordHeader,
    };

    pub const Iterator = struct {
        current: [*]const u8,
        end: [*]const u8,

        pub fn next(self: *Iterator) ?Record {
            if (@intFromPtr(self.current) >= @intFromPtr(self.end)) return null;

            const header: *const RecordHeader = @ptrCast(@alignCast(self.current));

            if (header.length < @sizeOf(RecordHeader)) return null;

            self.current += header.length;

            return switch (header.record_type) {
                .local_apic => if (header.cast(LocalApic)) |p| .{ .local_apic = p } else .{ .unknown = header },
                .io_apic => if (header.cast(IoApic)) |p| .{ .io_apic = p } else .{ .unknown = header },
                .interrupt_source_override => if (header.cast(InterruptSourceOverride)) |p| .{ .interrupt_source_override = p } else .{ .unknown = header },
                .nmi_source => if (header.cast(NmiSource)) |p| .{ .nmi_source = p } else .{ .unknown = header },
                .local_apic_nmi => if (header.cast(LocalApicNmi)) |p| .{ .local_apic_nmi = p } else .{ .unknown = header },
                .local_apic_address_override => if (header.cast(LocalApicAddressOverride)) |p| .{ .local_apic_address_override = p } else .{ .unknown = header },
                .local_x2apic => if (header.cast(LocalX2Apic)) |p| .{ .local_x2apic = p } else .{ .unknown = header },
                .local_x2apic_nmi => if (header.cast(LocalX2ApicNmi)) |p| .{ .local_x2apic_nmi = p } else .{ .unknown = header },
                .gicc => if (header.cast(Gicc)) |p| .{ .gicc = p } else .{ .unknown = header },
                .gicd => if (header.cast(Gicd)) |p| .{ .gicd = p } else .{ .unknown = header },
                .gic_msi_frame => if (header.cast(GicMsiFrame)) |p| .{ .gic_msi_frame = p } else .{ .unknown = header },
                .gicr => if (header.cast(Gicr)) |p| .{ .gicr = p } else .{ .unknown = header },
                .gic_its => if (header.cast(GicIts)) |p| .{ .gic_its = p } else .{ .unknown = header },
                .riscv_intc => if (header.cast(RiscvIntc)) |p| .{ .riscv_intc = p } else .{ .unknown = header },
                else => .{ .unknown = header },
            };
        }
    };

    pub const RecordHeader = extern struct {
        record_type: Type,
        length: u8,

        pub const Type = enum(u8) {
            local_apic = 0,
            io_apic = 1,
            interrupt_source_override = 2,
            nmi_source = 3,
            local_apic_nmi = 4,
            local_apic_address_override = 5,
            io_sapic = 6,
            local_sapic = 7,
            platform_interrupt_sources = 8,
            local_x2apic = 9,
            local_x2apic_nmi = 10,
            gicc = 11,
            gicd = 12,
            gic_msi_frame = 13,
            gicr = 14,
            gic_its = 15,
            riscv_intc = 24,
            _,
        };

        pub fn cast(self: *const RecordHeader, comptime T: type) ?*const T {
            if (self.length < @sizeOf(T)) return null;
            return @ptrCast(@alignCast(self));
        }
    };

    pub const LocalApicFlags = packed struct(u32) {
        enabled: bool = false,
        online_capable: bool = false,
        _reserved: u30 = 0,
    };

    pub const MpsIntiFlags = packed struct(u16) {
        polarity: u2 = 0, // 0 = Conforms, 1 = Active High, 3 = Active Low
        trigger_mode: u2 = 0, // 0 = Conforms, 1 = Edge, 3 = Level
        _reserved: u12 = 0,
    };

    pub const LocalApic = extern struct {
        header: RecordHeader,
        acpi_processor_uid: u8,
        apic_id: u8,
        flags: LocalApicFlags,
    };

    pub const IoApic = extern struct {
        header: RecordHeader,
        io_apic_id: u8,
        _reserved: u8,
        io_apic_address: u32,
        global_system_interrupt_base: u32,
    };

    pub const InterruptSourceOverride = extern struct {
        header: RecordHeader,
        bus: u8,
        source: u8,
        global_system_interrupt: u32 align(2),
        flags: MpsIntiFlags,
    };

    pub const NmiSource = extern struct {
        header: RecordHeader,
        flags: MpsIntiFlags,
        global_system_interrupt: u32,
    };

    pub const LocalApicNmi = extern struct {
        header: RecordHeader,
        acpi_processor_uid: u8,
        flags: MpsIntiFlags align(1),
        local_apic_lint: u8,
    };

    pub const LocalApicAddressOverride = extern struct {
        header: RecordHeader,
        _reserved: u16,
        local_apic_address: u64 align(4),
    };

    pub const LocalX2Apic = extern struct {
        header: RecordHeader,
        _reserved: u16,
        x2apic_id: u32,
        flags: LocalApicFlags,
        acpi_processor_uid: u32,
    };

    pub const LocalX2ApicNmi = extern struct {
        header: RecordHeader,
        flags: MpsIntiFlags,
        acpi_processor_uid: u32,
        local_x2apic_lint: u8,
        _reserved: [3]u8,
    };

    pub const Gicc = extern struct {
        header: RecordHeader,
        _reserved1: u16,
        cpu_interface_number: u32,
        acpi_processor_uid: u32,
        flags: LocalApicFlags,
        parking_protocol_version: u32,
        performance_interrupt_gsiv: u32,
        parked_address: u64,
        physical_base_address: u64,
        gicv: u64,
        gich: u64,
        vgic_maintenance_interrupt: u32,
        gicr_base_address: u64 align(4),
        mpidr: u64 align(4),
        processor_power_efficiency_class: u8,
        _reserved2: u8,
        spe_overflow_interrupt: u16,
    };

    pub const Gicd = extern struct {
        header: RecordHeader,
        _reserved1: u16,
        gic_id: u32,
        physical_base_address: u64,
        system_vector_base: u32,
        gic_version: u8,
        _reserved2: [3]u8,
    };

    pub const GicMsiFrame = extern struct {
        header: RecordHeader,
        _reserved1: u16,
        gic_msi_frame_id: u32,
        physical_base_address: u64,
        flags: u32,
        spi_count: u16,
        spi_base: u16,
    };

    pub const Gicr = extern struct {
        header: RecordHeader,
        _reserved: u16,
        discovery_range_base_address: u64 align(4),
        discovery_range_length: u32,
    };

    pub const GicIts = extern struct {
        header: RecordHeader,
        _reserved: u16,
        gic_its_id: u32,
        physical_base_address: u64 align(4),
        _reserved2: u32,
    };

    pub const RiscvIntc = extern struct {
        header: RecordHeader,
        version: u8,
        _reserved: u8,
        flags: LocalApicFlags,
        hart_id: u64 align(4),
        acpi_processor_uid: u32,
    };

    comptime {
        if (@sizeOf(Madt) != 44) @compileError("Madt should have a size of 44 (SdtHeader + 8 bytes)");
        if (@offsetOf(Madt, "local_interrupt_controller_address") != 36) @compileError("Madt.local_interrupt_controller_address offset mismatch");

        if (@sizeOf(LocalApic) != 8) @compileError("LocalApic size mismatch");
        if (@sizeOf(IoApic) != 12) @compileError("IoApic size mismatch");
        if (@sizeOf(InterruptSourceOverride) != 10) @compileError("InterruptSourceOverride size mismatch");
        if (@sizeOf(NmiSource) != 8) @compileError("NmiSource size mismatch");
        if (@sizeOf(LocalApicNmi) != 6) @compileError("LocalApicNmi size mismatch");
        if (@sizeOf(LocalApicAddressOverride) != 12) @compileError("LocalApicAddressOverride size mismatch");
        if (@sizeOf(LocalX2Apic) != 16) @compileError("LocalX2Apic size mismatch");
        if (@sizeOf(LocalX2ApicNmi) != 12) @compileError("LocalX2ApicNmi size mismatch");

        if (@sizeOf(Gicc) != 80) @compileError("Gicc size mismatch (expected 80 bytes for ACPI 6.0+)");
        if (@sizeOf(Gicd) != 24) @compileError("Gicd size mismatch");
        if (@sizeOf(GicMsiFrame) != 24) @compileError("GicMsiFrame size mismatch");
        if (@sizeOf(Gicr) != 16) @compileError("Gicr size mismatch");
        if (@sizeOf(GicIts) != 20) @compileError("GicIts size mismatch");

        if (@sizeOf(RiscvIntc) != 20) @compileError("RiscvIntc size mismatch (expected 20 bytes for ACPI 6.5)");
    }
};

pub const Fadt = extern struct {
    pub const SIGNATURE = "FACP";

    header: SdtHeader,
};

pub const Spcr = extern struct {
    pub const SIGNATURE = "SPCR";

    header: SdtHeader,

    interface_type: InterfaceType,
    _reserved0: [3]u8,

    base_address: Gas align(4),

    interrupt_type: InterruptType,
    irq: u8,

    global_system_interrupt: u32 align(2),

    configured_baud_rate: ConfiguredBaudRate,
    parity: Parity,
    stop_bits: StopBits,
    flow_control: FlowControl,
    terminal_type: TerminalType,
    language: u8, // always 0

    pci_device_id: u16,
    pci_vendor_id: u16,
    pci_bus_number: u8,
    pci_device_number: u8,
    pci_function_number: u8,

    pci_flags: PciFlags align(1),

    pci_segment: u8,

    uart_clock_frequency: u32,
    precise_baud_rate: u32,

    namespace_string_length: u16,
    namespace_string_offset: u16,

    pub const InterfaceType = enum(u8) {
        full_16550 = 0,
        full_16450 = 1,
        ns16550_subset = 2,
        arm_pl011 = 3,
        arm_sbsa_generic_uart_2 = 14,
        arm_sbsa_generic_uart = 15,
        ns16550_dec_dc374 = 16,
        ns16550a_generic = 18,
        nsconsult_ci109 = 19,
        _, // unspecified
    };

    pub const InterruptType = packed struct(u8) {
        pcat_8259: bool = false,
        io_apic: bool = false,
        io_sapic: bool = false,
        armh_gic: bool = false,
        riscv_plic_aplic: bool = false,
        _reserved: u3 = 0,
    };

    pub const ConfiguredBaudRate = enum(u8) {
        as_is = 0,
        rate_9600 = 3,
        rate_19200 = 4,
        rate_57600 = 6,
        rate_115200 = 7,
        _, // reserved
    };

    pub const Parity = enum(u8) {
        none = 0,
        _, // reserved
    };

    pub const StopBits = enum(u8) {
        one = 1,
        _, // reserved
    };

    pub const FlowControl = packed struct(u8) {
        dcd_required: bool = false,
        rts_cts: bool = false,
        xon_xoff: bool = false,
        _reserved: u5 = 0,
    };

    pub const TerminalType = enum(u8) {
        vt100 = 0,
        vt100_plus = 1,
        vt_utf8 = 2,
        ansi = 3,
        _, // reserved
    };

    pub const PciFlags = packed struct(u32) {
        no_suppress_pnp_and_power_mgmt: bool = false,
        _reserved: u31 = 0,
    };

    pub fn isPciDevice(self: *const Spcr) bool {
        return self.pci_device_id != 0xFFFF and self.pci_vendor_id != 0xFFFF;
    }

    pub fn uartClockFrequency(self: *const Spcr) ?u32 {
        const field_end = @offsetOf(Spcr, "uart_clock_frequency") + @sizeOf(u32);
        if (field_end > self.header.length) return null;
        return if (self.uart_clock_frequency == 0) null else self.uart_clock_frequency;
    }

    pub fn preciseBaudRate(self: *const Spcr) ?u32 {
        const field_end = @offsetOf(Spcr, "precise_baud_rate") + @sizeOf(u32);
        if (field_end > self.header.length) return null;
        return if (self.precise_baud_rate == 0) null else self.precise_baud_rate;
    }

    pub fn namespaceString(self: *const Spcr) ?[]const u8 {
        const field_end = @offsetOf(Spcr, "namespace_string_offset") + @sizeOf(u16);
        if (field_end > self.header.length) return null;
        if (self.namespace_string_offset == 0) return null;

        const end = @as(u32, self.namespace_string_offset) + self.namespace_string_length;
        if (end > self.header.length) return null;

        const base: [*]const u8 = @ptrCast(self);
        return base[self.namespace_string_offset..][0..self.namespace_string_length];
    }

    comptime {
        if (@sizeOf(Spcr) != 88) @compileError("Spcr should have a size of 88 (revision 4 fixed part)");
        if (@offsetOf(Spcr, "global_system_interrupt") != 54) @compileError("Spcr.global_system_interrupt offset mismatch");
        if (@offsetOf(Spcr, "pci_flags") != 71) @compileError("Spcr.pci_flags offset mismatch");
        if (@offsetOf(Spcr, "namespace_string_offset") != 86) @compileError("Spcr.namespace_string_offset offset mismatch");
    }
};

pub const Dbg2 = extern struct {
    pub const SIGNATURE = "DBG2";

    header: SdtHeader,

    info_offset: u32,
    info_count: u32,

    pub fn getDevice(self: *const Dbg2, index: u32) ?*align(1) const DebugDeviceInformation {
        if (index >= self.info_count) return null;

        var current_offset = self.info_offset;
        var i: u32 = 0;
        const base_ptr: [*]const u8 = @ptrCast(self);

        while (i < index) : (i += 1) {
            if (current_offset + @sizeOf(DebugDeviceInformation) > self.header.length) return null;
            const dev: *align(1) const DebugDeviceInformation = @ptrCast(&base_ptr[current_offset]);
            current_offset += dev.length;
        }

        if (current_offset + @sizeOf(DebugDeviceInformation) > self.header.length) return null;
        return @ptrCast(&base_ptr[current_offset]);
    }
};

pub const DebugDeviceInformation = extern struct {
    revision: u8,
    length: u16 align(1),
    base_address_register_count: u8,
    namespace_string_length: u16 align(1),
    namespace_string_offset: u16 align(1),
    oem_data_length: u16 align(1),
    oem_data_offset: u16 align(1),
    port_type: PortType align(1),
    port_subtype: u16 align(1),
    _reserved: u16 align(1),
    base_address_register_offset: u16 align(1),
    address_size_offset: u16 align(1),

    pub const PortType = enum(u16) {
        serial = 0x8000,
        ieee1394 = 0x8001,
        usb = 0x8002,
        net = 0x8003,
        _, // reserved
    };

    pub const PortSubtypeSerial = enum(u16) {
        full_16550 = 0x0000,
        full_16450 = 0x0001,
        arm_pl011 = 0x0003,
        arm_sbsa_generic_uart = 0x000E,
        _, // other variations
    };

    pub fn getBaseAddress(self: *align(1) const DebugDeviceInformation, index: u8) ?*align(1) const Gas {
        if (index >= self.base_address_register_count) return null;

        const base_ptr: [*]const u8 = @ptrCast(self);
        const gas_array_ptr: [*]align(1) const Gas = @ptrCast(&base_ptr[self.base_address_register_offset]);

        return &gas_array_ptr[index];
    }

    pub fn getAddressSize(self: *align(1) const DebugDeviceInformation, index: u8) ?u32 {
        if (index >= self.base_address_register_count) return null;

        const base_ptr: [*]const u8 = @ptrCast(self);
        const size_array_ptr: [*]align(1) const u32 = @ptrCast(&base_ptr[self.address_size_offset]);

        return size_array_ptr[index];
    }

    pub fn namespaceString(self: *align(1) const DebugDeviceInformation) ?[]const u8 {
        if (self.namespace_string_length == 0 or self.namespace_string_offset == 0) return null;

        const base_ptr: [*]const u8 = @ptrCast(self);
        return base_ptr[self.namespace_string_offset..][0..self.namespace_string_length];
    }

    comptime {
        if (@sizeOf(DebugDeviceInformation) != 22) @compileError("DebugDeviceInformation size must be 22");
        if (@offsetOf(DebugDeviceInformation, "length") != 1) @compileError("Offset mismatch");
        if (@offsetOf(DebugDeviceInformation, "base_address_register_offset") != 18) @compileError("Offset mismatch");
        if (@offsetOf(DebugDeviceInformation, "address_size_offset") != 20) @compileError("Offset mismatch");
    }
};
