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

// --- drivers/dt.zig --- //

pub const FDT_MAGIC: u32 = 0xD00DFEED;

const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

pub const Header = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,

    comptime {
        if (@sizeOf(Header) != 40) @compileError("FDT Header must be 40 bytes");
    }
};

pub const RegRange = struct {
    base: u64,
    size: u64,
};

pub const Fdt = struct {
    base: [*]const u8,
    total_size: usize,
    struct_off: usize,
    struct_size: usize,
    strings_off: usize,
    strings_size: usize,

    pub fn init(ptr: *const anyopaque) ?Fdt {
        const hdr: *const Header = @ptrCast(@alignCast(ptr));
        if (std.mem.bigToNative(u32, hdr.magic) != FDT_MAGIC) return null;

        const total_size: usize = std.mem.bigToNative(u32, hdr.totalsize);
        const struct_off: usize = std.mem.bigToNative(u32, hdr.off_dt_struct);
        const struct_size: usize = std.mem.bigToNative(u32, hdr.size_dt_struct);
        const strings_off: usize = std.mem.bigToNative(u32, hdr.off_dt_strings);
        const strings_size: usize = std.mem.bigToNative(u32, hdr.size_dt_strings);

        if (total_size < @sizeOf(Header)) return null;
        if (struct_off + struct_size > total_size) return null;
        if (strings_off + strings_size > total_size) return null;
        if (struct_off % 4 != 0) return null;

        return .{
            .base = @ptrCast(ptr),
            .total_size = total_size,
            .struct_off = struct_off,
            .struct_size = struct_size,
            .strings_off = strings_off,
            .strings_size = strings_size,
        };
    }

    pub inline fn bootCpuPhysId(self: *const Fdt) u32 {
        const hdr: *const Header = @ptrCast(@alignCast(self.base));
        return std.mem.bigToNative(u32, hdr.boot_cpuid_phys);
    }

    pub fn root(self: *const Fdt) ?Node {
        if (self.struct_size < 4) return null;
        if (self.readToken(0) != FDT_BEGIN_NODE) return null;

        return .{
            .fdt = self,
            .offset = 0,
            .parent_addr_cells = 2,
            .parent_size_cells = 1,
        };
    }

    pub fn findPath(self: *const Fdt, path: []const u8) ?Node {
        var current = self.root() orelse return null;
        if (std.mem.eql(u8, path, "/")) return current;

        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |segment| {
            current = current.findChild(segment) orelse return null;
        }
        return current;
    }

    pub fn findCompatible(self: *const Fdt, compat: []const u8) ?Node {
        return self.findCompatibleAny(&.{compat});
    }

    pub fn findCompatibleAny(self: *const Fdt, compats: []const []const u8) ?Node {
        var offset: usize = 0;

        var addr_stack: [16]u32 = @splat(2);
        var size_stack: [16]u32 = @splat(1);
        var depth: usize = 0;

        while (offset + 4 <= self.struct_size) {
            const token = self.readToken(offset);
            switch (token) {
                FDT_BEGIN_NODE => {
                    const node_off = offset;
                    const p_addr = if (depth > 0) addr_stack[@min(depth - 1, 15)] else 2;
                    const p_size = if (depth > 0) size_stack[@min(depth - 1, 15)] else 1;

                    const node = Node{
                        .fdt = self,
                        .offset = node_off,
                        .parent_addr_cells = p_addr,
                        .parent_size_cells = p_size,
                    };

                    if (depth < 16) {
                        addr_stack[depth] = node.addressCells();
                        size_stack[depth] = node.sizeCells();
                    }
                    depth += 1;

                    if (node.isAvailable()) {
                        for (compats) |c| {
                            if (node.isCompatible(c)) return node;
                        }
                    }

                    offset = self.skipNodeHeader(node_off);
                },
                FDT_END_NODE => {
                    if (depth > 0) depth -= 1;
                    offset += 4;
                },
                FDT_PROP => {
                    if (offset + 12 > self.struct_size) return null;
                    const len = self.readToken(offset + 4);
                    offset = std.mem.alignForward(usize, offset + 12 + len, 4);
                },
                FDT_NOP => {
                    offset += 4;
                },
                FDT_END => return null,
                else => return null,
            }
        }
        return null;
    }

    pub fn findByPhandle(self: *const Fdt, phandle: u32) ?Node {
        if (phandle == 0 or phandle == std.math.maxInt(u32)) return null;

        var offset: usize = 0;
        var addr_stack: [16]u32 = @splat(2);
        var size_stack: [16]u32 = @splat(1);
        var depth: usize = 0;

        while (offset + 4 <= self.struct_size) {
            const token = self.readToken(offset);
            switch (token) {
                FDT_BEGIN_NODE => {
                    const node_off = offset;
                    const p_addr = if (depth > 0) addr_stack[@min(depth - 1, 15)] else 2;
                    const p_size = if (depth > 0) size_stack[@min(depth - 1, 15)] else 1;

                    const node = Node{
                        .fdt = self,
                        .offset = node_off,
                        .parent_addr_cells = p_addr,
                        .parent_size_cells = p_size,
                    };

                    if (depth < 16) {
                        addr_stack[depth] = node.addressCells();
                        size_stack[depth] = node.sizeCells();
                    }
                    depth += 1;

                    if (node.getPropU32("phandle") == phandle or
                        node.getPropU32("linux,phandle") == phandle)
                    {
                        return node;
                    }

                    offset = self.skipNodeHeader(node_off);
                },
                FDT_END_NODE => {
                    if (depth > 0) depth -= 1;
                    offset += 4;
                },
                FDT_PROP => {
                    if (offset + 12 > self.struct_size) return null;
                    const len = self.readToken(offset + 4);
                    offset = std.mem.alignForward(usize, offset + 12 + len, 4);
                },
                FDT_NOP => offset += 4,
                FDT_END => return null,
                else => return null,
            }
        }
        return null;
    }

    inline fn readToken(self: *const Fdt, struct_rel_offset: usize) u32 {
        const ptr: *align(1) const u32 = @ptrCast(self.base + self.struct_off + struct_rel_offset);
        return std.mem.bigToNative(u32, ptr.*);
    }

    fn getString(self: *const Fdt, str_offset: u32) ?[]const u8 {
        if (str_offset >= self.strings_size) return null;
        const start = self.base + self.strings_off + str_offset;
        const max_len = self.strings_size - str_offset;
        var len: usize = 0;
        while (len < max_len and start[len] != 0) : (len += 1) {}
        return start[0..len];
    }

    fn skipNodeHeader(self: *const Fdt, node_off: usize) usize {
        const name_start = node_off + 4;
        const ptr = self.base + self.struct_off + name_start;
        const max_len = self.struct_size -| name_start;
        var len: usize = 0;
        while (len < max_len and ptr[len] != 0) : (len += 1) {}
        return std.mem.alignForward(usize, name_start + len + 1, 4);
    }

    fn skipSubtree(self: *const Fdt, node_off: usize) usize {
        var offset = self.skipNodeHeader(node_off);
        var depth: usize = 1;

        while (offset + 4 <= self.struct_size and depth > 0) {
            const token = self.readToken(offset);
            switch (token) {
                FDT_BEGIN_NODE => {
                    depth += 1;
                    offset = self.skipNodeHeader(offset);
                },
                FDT_END_NODE => {
                    depth -= 1;
                    offset += 4;
                },
                FDT_PROP => {
                    if (offset + 12 > self.struct_size) return self.struct_size;
                    const len = self.readToken(offset + 4);
                    offset = std.mem.alignForward(usize, offset + 12 + len, 4);
                },
                FDT_NOP => offset += 4,
                else => return self.struct_size,
            }
        }
        return offset;
    }

    pub fn findStdoutOrCompatible(self: *const Fdt, compats: []const []const u8) ?Node {
        if (self.findPath("/chosen")) |chosen| {
            const raw_path = chosen.getPropString("stdout-path") orelse
                chosen.getPropString("linux,stdout-path");

            if (raw_path) |raw| {
                const path_part = if (std.mem.indexOfScalar(u8, raw, ':')) |colon|
                    raw[0..colon]
                else
                    raw;

                if (path_part.len > 0) {
                    const resolved_path = if (path_part[0] != '/') blk: {
                        const aliases = self.findPath("/aliases") orelse break :blk null;
                        break :blk aliases.getPropString(path_part);
                    } else path_part;

                    if (resolved_path) |rpath| {
                        if (self.findPath(rpath)) |stdout_node| {
                            if (stdout_node.isAvailable()) {
                                for (compats) |c| {
                                    if (stdout_node.isCompatible(c)) return stdout_node;
                                }
                            }
                        }
                    }
                }
            }
        }

        return self.findCompatibleAny(compats);
    }
};

pub const Node = struct {
    fdt: *const Fdt,
    offset: usize,
    parent_addr_cells: u32 = 2,
    parent_size_cells: u32 = 1,

    pub fn name(self: Node) []const u8 {
        const name_start = self.offset + 4;
        const ptr = self.fdt.base + self.fdt.struct_off + name_start;
        const max_len = self.fdt.struct_size -| name_start;
        var len: usize = 0;
        while (len < max_len and ptr[len] != 0) : (len += 1) {}
        return ptr[0..len];
    }

    pub fn baseName(self: Node) []const u8 {
        const full = self.name();
        if (std.mem.indexOfScalar(u8, full, '@')) |at_idx| {
            return full[0..at_idx];
        }
        return full;
    }

    pub fn getProp(self: Node, prop_name: []const u8) ?[]const u8 {
        var cur = self.fdt.skipNodeHeader(self.offset);

        while (cur + 4 <= self.fdt.struct_size) {
            const token = self.fdt.readToken(cur);
            switch (token) {
                FDT_PROP => {
                    if (cur + 12 > self.fdt.struct_size) return null;
                    const len = self.fdt.readToken(cur + 4);
                    const name_off = self.fdt.readToken(cur + 8);
                    const val_start = cur + 12;

                    if (val_start + len > self.fdt.struct_size) return null;

                    if (self.fdt.getString(name_off)) |pname| {
                        if (std.mem.eql(u8, pname, prop_name)) {
                            const ptr = self.fdt.base + self.fdt.struct_off + val_start;
                            return ptr[0..len];
                        }
                    }
                    cur = std.mem.alignForward(usize, val_start + len, 4);
                },
                FDT_NOP => cur += 4,
                FDT_BEGIN_NODE, FDT_END_NODE, FDT_END => return null,
                else => return null,
            }
        }
        return null;
    }

    pub fn hasProp(self: Node, prop_name: []const u8) bool {
        return self.getProp(prop_name) != null;
    }

    pub fn getPropU32(self: Node, prop_name: []const u8) ?u32 {
        const bytes = self.getProp(prop_name) orelse return null;
        if (bytes.len < 4) return null;
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    pub fn getPropU64(self: Node, prop_name: []const u8) ?u64 {
        const bytes = self.getProp(prop_name) orelse return null;
        if (bytes.len >= 8) {
            return std.mem.readInt(u64, bytes[0..8], .big);
        } else if (bytes.len >= 4) {
            return std.mem.readInt(u32, bytes[0..4], .big);
        }
        return null;
    }

    pub fn getPropString(self: Node, prop_name: []const u8) ?[]const u8 {
        const bytes = self.getProp(prop_name) orelse return null;
        if (bytes.len == 0) return "";
        if (std.mem.indexOfScalar(u8, bytes, 0)) |nul| {
            return bytes[0..nul];
        }
        return bytes;
    }

    pub fn isCompatible(self: Node, target: []const u8) bool {
        const bytes = self.getProp("compatible") orelse return false;
        var it = std.mem.splitScalar(u8, bytes, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (std.mem.eql(u8, entry, target)) return true;
        }
        return false;
    }

    pub fn isAvailable(self: Node) bool {
        const status = self.getPropString("status") orelse return true;
        return std.mem.eql(u8, status, "okay") or std.mem.eql(u8, status, "ok");
    }

    pub fn addressCells(self: Node) u32 {
        return self.getPropU32("#address-cells") orelse 2;
    }

    pub fn sizeCells(self: Node) u32 {
        return self.getPropU32("#size-cells") orelse 1;
    }

    pub fn reg(self: Node, index: usize) ?RegRange {
        const bytes = self.getProp("reg") orelse return null;
        const addr_cells: usize = self.parent_addr_cells;
        const size_cells: usize = self.parent_size_cells;

        if (addr_cells == 0 or addr_cells > 2 or size_cells > 2) return null;

        const stride = (addr_cells + size_cells) * 4;
        if (stride == 0) return null;

        const start = index * stride;
        if (start + stride > bytes.len) return null;

        var base: u64 = 0;
        for (0..addr_cells) |i| {
            const cell_off = start + i * 4;
            const cell = std.mem.readInt(u32, bytes[cell_off..][0..4], .big);
            base = (base << 32) | cell;
        }

        var size: u64 = 0;
        for (0..size_cells) |i| {
            const cell_off = start + (addr_cells + i) * 4;
            const cell = std.mem.readInt(u32, bytes[cell_off..][0..4], .big);
            size = (size << 32) | cell;
        }

        return .{ .base = base, .size = size };
    }

    pub fn findChild(self: Node, child_name: []const u8) ?Node {
        var it = self.children();
        while (it.next()) |child| {
            if (std.mem.eql(u8, child.name(), child_name) or
                std.mem.eql(u8, child.baseName(), child_name))
            {
                return child;
            }
        }
        return null;
    }

    pub fn children(self: Node) ChildIterator {
        var cur = self.fdt.skipNodeHeader(self.offset);

        while (cur + 4 <= self.fdt.struct_size) {
            const token = self.fdt.readToken(cur);
            if (token == FDT_PROP) {
                if (cur + 12 > self.fdt.struct_size) break;
                const len = self.fdt.readToken(cur + 4);
                cur = std.mem.alignForward(usize, cur + 12 + len, 4);
            } else if (token == FDT_NOP) {
                cur += 4;
            } else {
                break;
            }
        }

        return .{
            .fdt = self.fdt,
            .current_offset = cur,
            .addr_cells = self.addressCells(),
            .size_cells = self.sizeCells(),
        };
    }

    pub const ChildIterator = struct {
        fdt: *const Fdt,
        current_offset: usize,
        addr_cells: u32,
        size_cells: u32,

        pub fn next(self: *ChildIterator) ?Node {
            while (self.current_offset + 4 <= self.fdt.struct_size) {
                const token = self.fdt.readToken(self.current_offset);
                switch (token) {
                    FDT_NOP => self.current_offset += 4,
                    FDT_BEGIN_NODE => {
                        const child = Node{
                            .fdt = self.fdt,
                            .offset = self.current_offset,
                            .parent_addr_cells = self.addr_cells,
                            .parent_size_cells = self.size_cells,
                        };
                        self.current_offset = self.fdt.skipSubtree(self.current_offset);
                        return child;
                    },
                    // Reached `FDT_END_NODE` of the parent node.
                    else => return null,
                }
            }
            return null;
        }
    };
};
