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
const limine = @import("limine");

// --- imports --- //

const kernel = @import("root");

const mem = kernel.mem;

// --- mem/phys.zig --- //

pub const Error = error{OutOfMemory};

const PAGE_SIZE = mem.paging.page_size;
const PAGES_PER_ZONE = 512;
const ZONE_SIZE = PAGES_PER_ZONE * PAGE_SIZE;

const NULL_INDEX: u32 = std.math.maxInt(u32);

const ZoneBitSet = std.StaticBitSet(PAGES_PER_ZONE);
const BucketBitSet = std.StaticBitSet(PAGES_PER_ZONE + 1);

const ZoneLinks = struct {
    prev: u32 = NULL_INDEX,
    next: u32 = NULL_INDEX,
};

var bitmaps: []ZoneBitSet = undefined;
var free_counts: []u16 = undefined;
var links: []ZoneLinks = undefined;
var density_buckets: [PAGES_PER_ZONE + 1]u32 = undefined;
var bucket_occupation: BucketBitSet = undefined;

var total_pages: usize = undefined;
var available_pages: usize = undefined;

var global_lock: kernel.mem.utils.RwLock align(8) = undefined;

pub fn updateHhdm() void {
    bitmaps.ptr = mem.updatePtrs(ZoneBitSet, bitmaps.ptr);
    free_counts.ptr = mem.updatePtrs(u16, free_counts.ptr);
    links.ptr = mem.updatePtrs(ZoneLinks, links.ptr);
}

pub fn totalPages() usize {
    return total_pages;
}

pub fn availablePages() usize {
    const int_state = global_lock.acquire(.read, 0);
    defer global_lock.release(.read, int_state);

    return available_pages;
}

pub const PhysContext = struct {
    const CACHE_LEN = PAGE_SIZE / @sizeOf(u64);
    const CACHE_TYPE = [CACHE_LEN]u64;
    preheat_cache: *CACHE_TYPE,
    preheat_len: usize,
    recycle_cache: *CACHE_TYPE,
    recycle_len: usize,

    pub fn init(self: *PhysContext) !void {
        var page: [1]u64 = undefined;

        try _allocNonContiguous(&page);
        self.preheat_cache = mem.toHhdm(CACHE_TYPE, page[0]);
        self.preheat_len = CACHE_LEN;

        try _allocNonContiguous(&page);
        self.recycle_cache = mem.toHhdm(CACHE_TYPE, page[0]);
        self.recycle_len = 0;

        try _allocNonContiguous(self.preheat_cache[0..]);
    }

    pub fn current() ?*PhysContext {
        if (kernel.cpu.CpuContext.current()) |cpu_context| {
            @branchHint(.likely);
            return &cpu_context.phys_context;
        } else {
            @branchHint(.cold);
            return null;
        }
    }

    pub fn updateHhdm(self: *PhysContext) void {
        mem.updateRef(CACHE_TYPE, &self.preheat_cache);
        mem.updateRef(CACHE_TYPE, &self.recycle_cache);
    }
};

pub fn init(memmap_entries: []*limine.MemoryMapEntry) !void {
    var max_phys_addr: u64 = 0;
    for (memmap_entries) |entry| {
        const end_addr = entry.base + entry.length;
        if (end_addr > max_phys_addr) {
            max_phys_addr = end_addr;
        }
    }

    const aligned_max = std.mem.alignForward(u64, max_phys_addr, ZONE_SIZE);
    const zone_count: u32 = @intCast(aligned_max / ZONE_SIZE);

    const bitmaps_size = zone_count * @sizeOf(ZoneBitSet);
    const counts_size = zone_count * @sizeOf(u16);
    const links_size = zone_count * @sizeOf(ZoneLinks);

    const bitmaps_offset = 0;
    const counts_offset = std.mem.alignForward(u64, bitmaps_offset + bitmaps_size, @sizeOf(u64));
    const links_offset = std.mem.alignForward(u64, counts_offset + counts_size, @sizeOf(u64));

    const total_metadata_bytes = std.mem.alignForward(u64, links_offset + links_size, PAGE_SIZE);

    var metadata_phys_base: u64 = 0;
    var found_space = false;

    for (memmap_entries) |entry| {
        if (entry.type != .usable) continue;

        const initial_end = entry.base + entry.length;

        const aligned_base = std.mem.alignForward(u64, entry.base, PAGE_SIZE);
        if (aligned_base >= initial_end) {
            entry.length = 0;
            continue;
        }

        const aligned_end = std.mem.alignBackward(u64, initial_end, PAGE_SIZE);
        if (aligned_base >= aligned_end) {
            entry.length = 0;
            continue;
        }

        entry.base = aligned_base;
        entry.length = aligned_end - aligned_base;

        if (!found_space and entry.length >= total_metadata_bytes) {
            metadata_phys_base = entry.base;

            entry.base += total_metadata_bytes;
            entry.length -= total_metadata_bytes;

            found_space = true;
        }
    }

    if (!found_space) {
        return error.NotEnoughMemory;
    }

    const metadata_virt_base = mem.hhdm_offset + metadata_phys_base;

    bitmaps.ptr = @alignCast(@as([*]ZoneBitSet, @ptrFromInt(metadata_virt_base + bitmaps_offset)));
    bitmaps.len = zone_count;

    free_counts.ptr = @alignCast(@as([*]u16, @ptrFromInt(metadata_virt_base + counts_offset)));
    free_counts.len = zone_count;

    links.ptr = @alignCast(@as([*]ZoneLinks, @ptrFromInt(metadata_virt_base + links_offset)));
    links.len = zone_count;

    @memset(bitmaps, .empty);
    @memset(free_counts, 0);
    @memset(links, .{});
    @memset(&density_buckets, NULL_INDEX);
    bucket_occupation = .empty;

    available_pages = 0;
    global_lock = .{};

    for (memmap_entries) |entry| {
        if (entry.type != .usable) continue;

        var current_addr = entry.base;
        const end_addr = entry.base + entry.length;

        if (current_addr == 0) {
            current_addr += PAGE_SIZE;
        }

        while (current_addr < end_addr) : (current_addr += PAGE_SIZE) {
            const zone_idx = current_addr / ZONE_SIZE;
            const bit_idx = (current_addr % ZONE_SIZE) / PAGE_SIZE;

            bitmaps[zone_idx].set(bit_idx);
            free_counts[zone_idx] += 1;
            available_pages += 1;
        }
    }

    for (0..zone_count) |i| {
        const idx: u32 = @intCast(i);
        const count = free_counts[idx];

        const head_idx = density_buckets[count];
        links[idx].next = head_idx;
        links[idx].prev = NULL_INDEX;

        if (head_idx != NULL_INDEX) {
            links[head_idx].prev = idx;
        }

        density_buckets[count] = idx;
        bucket_occupation.set(count);
    }

    total_pages = available_pages;

    validate();
}

inline fn removeZone(zone_idx: u32, count: u16) void {
    std.debug.assert(free_counts[zone_idx] == count);

    const prev_idx = links[zone_idx].prev;
    const next_idx = links[zone_idx].next;

    if (prev_idx != NULL_INDEX) {
        links[prev_idx].next = next_idx;
    } else {
        density_buckets[count] = next_idx;

        if (next_idx == NULL_INDEX) {
            bucket_occupation.unset(count);
        }
    }

    if (next_idx != NULL_INDEX) {
        links[next_idx].prev = prev_idx;
    }

    links[zone_idx].prev = NULL_INDEX;
    links[zone_idx].next = NULL_INDEX;
}

inline fn insertZone(zone_idx: u32, count: u16) void {
    std.debug.assert(count <= PAGES_PER_ZONE);
    std.debug.assert(free_counts[zone_idx] == count);

    const head_idx = density_buckets[count];

    links[zone_idx].next = head_idx;
    links[zone_idx].prev = NULL_INDEX;

    if (head_idx != NULL_INDEX) {
        links[head_idx].prev = zone_idx;
    }

    density_buckets[count] = zone_idx;

    bucket_occupation.set(count);
}

pub fn allocNonContiguous(buffer: []u64) !void {
    if (buffer.len == 0) return;

    if (PhysContext.current()) |phys_context| {
        @branchHint(.likely);

        var filled: usize = @min(buffer.len, phys_context.recycle_len);
        if (filled > 0) {
            const start_idx = phys_context.recycle_len - filled;

            @memcpy(
                buffer[0..filled],
                phys_context.recycle_cache[start_idx..phys_context.recycle_len],
            );
            phys_context.recycle_len -= filled;
        }

        while (filled < buffer.len) {
            if (phys_context.preheat_len == 0) {
                try _allocNonContiguous(phys_context.preheat_cache[0..]);
                phys_context.preheat_len = phys_context.preheat_cache.len;
            }

            const remaining = buffer.len - filled;
            const delta = @min(remaining, phys_context.preheat_len);

            const preheat_start = phys_context.preheat_len - delta;
            const new_filled = filled + delta;

            @memcpy(
                buffer[filled..new_filled],
                phys_context.preheat_cache[preheat_start..phys_context.preheat_len],
            );

            phys_context.preheat_len -= delta;
            filled = new_filled;
        }
    } else {
        @branchHint(.cold);
        return _allocNonContiguous(buffer);
    }
}

fn _allocNonContiguous(buffer: []u64) !void {
    if (buffer.len == 0) return;

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    const to_fill = @min(buffer.len, available_pages);
    if (to_fill == 0) {
        return Error.OutOfMemory;
    }

    std.debug.assert(to_fill <= available_pages);
    available_pages -= to_fill;
    var filled: usize = 0;

    while (filled < to_fill) {
        var search_mask = bucket_occupation;
        search_mask.unset(0);

        const best_bucket_idx = search_mask.findFirstSet() orelse unreachable;
        const bucket: u16 = @intCast(best_bucket_idx);

        const zone_idx = density_buckets[bucket];
        removeZone(zone_idx, bucket);

        std.debug.assert(free_counts[zone_idx] == bucket);
        const pages_to_pump = @min(to_fill - filled, bucket);

        var i: usize = 0;
        while (i < pages_to_pump) : (i += 1) {
            const page_bit_idx = bitmaps[zone_idx].findFirstSet() orelse unreachable;

            bitmaps[zone_idx].unset(page_bit_idx);

            buffer[filled] = (@as(u64, zone_idx) * ZONE_SIZE) + (@as(u64, page_bit_idx) * PAGE_SIZE);
            filled += 1;
        }

        free_counts[zone_idx] -= @intCast(pages_to_pump);
        insertZone(zone_idx, free_counts[zone_idx]);
    }
}

pub inline fn allocPage() !u64 {
    var page: [1]u64 = undefined;
    try allocNonContiguous(&page);
    return page[0];
}

fn findContiguousBits(bitmap: *const ZoneBitSet, count: usize) ?usize {
    var run: usize = 0;
    var start: usize = 0;
    for (0..PAGES_PER_ZONE) |i| {
        if (bitmap.isSet(i)) {
            if (run == 0) start = i;
            run += 1;
            if (run == count) return start;
        } else {
            run = 0;
        }
    }
    return null;
}

inline fn claimBits(zone_idx: u32, start_bit: usize, count: usize) void {
    std.debug.assert(start_bit + count <= PAGES_PER_ZONE);

    var b: usize = 0;
    while (b < count) : (b += 1) {
        std.debug.assert(bitmaps[zone_idx].isSet(start_bit + b));
        bitmaps[zone_idx].unset(start_bit + b);
    }
}

/// Allocates `pages` physically contiguous pages.
///
/// For allocations up to `PAGES_PER_ZONE`, the allocator searches within
/// individual zones for a contiguous run.
///
/// For larger allocations, the allocator only considers runs of fully-free
/// consecutive zones and returns a `ZONE_SIZE`-aligned allocation. The final
/// zone may be only partially consumed.
///
/// This policy intentionally avoids consuming partially-free zones for large
/// contiguous allocations, preserving large physically contiguous regions
/// for future allocations. Consequently, the function may fail even when a
/// sufficiently large contiguous run exists across partially-free zones.
///
/// This allocator is primarily intended for consumers that require physical
/// contiguity, such as DMA-capable device drivers.
pub fn allocContiguous(pages: usize) Error!u64 {
    if (pages == 0) return 0;

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    if (available_pages < pages) return Error.OutOfMemory;

    if (pages <= PAGES_PER_ZONE) {
        var search_mask = bucket_occupation;

        const MaskInt = @TypeOf(search_mask.masks[0]);
        const BITS_PER_WORD = @bitSizeOf(MaskInt);

        const start_word = pages / BITS_PER_WORD;
        const start_bit = pages % BITS_PER_WORD;

        for (0..start_word) |w| {
            search_mask.masks[w] = 0;
        }

        if (start_word < search_mask.masks.len) {
            const one: MaskInt = 1;
            const shift_amt: std.math.Log2Int(MaskInt) = @intCast(start_bit);

            const keep_mask = ~((one << shift_amt) - 1);
            search_mask.masks[start_word] &= keep_mask;
        }

        search_mask.unset(PAGES_PER_ZONE);

        while (search_mask.findFirstSet()) |best_bucket_idx| {
            const bucket_idx: u16 = @intCast(best_bucket_idx);
            var current_zone = density_buckets[bucket_idx];

            while (current_zone != NULL_INDEX) {
                if (findContiguousBits(&bitmaps[current_zone], pages)) |start_bit_idx| {
                    removeZone(current_zone, bucket_idx);

                    claimBits(current_zone, start_bit_idx, pages);

                    free_counts[current_zone] -= @intCast(pages);
                    insertZone(current_zone, free_counts[current_zone]);
                    available_pages -= pages;

                    return (@as(u64, current_zone) * ZONE_SIZE) + (@as(u64, start_bit_idx) * PAGE_SIZE);
                }
                current_zone = links[current_zone].next;
            }

            search_mask.unset(bucket_idx);
        }

        if (bucket_occupation.isSet(PAGES_PER_ZONE)) {
            var z: u32 = @intCast(free_counts.len);
            while (z > 0) {
                z -= 1;
                if (free_counts[z] == PAGES_PER_ZONE) {
                    removeZone(z, PAGES_PER_ZONE);

                    claimBits(z, 0, pages);

                    free_counts[z] -= @intCast(pages);
                    insertZone(z, free_counts[z]);
                    available_pages -= pages;

                    return @as(u64, z) * ZONE_SIZE;
                }
            }
            unreachable;
        }

        return Error.OutOfMemory;
    }

    const required_zones: u32 = @intCast((pages - 1) / PAGES_PER_ZONE + 1);

    var best_start: u32 = NULL_INDEX;
    var best_run_diff: u32 = std.math.maxInt(u32);

    var current_run: u32 = 0;
    var run_start: u32 = 0;

    for (free_counts, 0..) |count, i| {
        if (count == PAGES_PER_ZONE) {
            if (current_run == 0) run_start = @intCast(i);
            current_run += 1;
        } else {
            if (current_run >= required_zones) {
                const diff = current_run - required_zones;
                if (diff < best_run_diff) {
                    best_run_diff = diff;
                    best_start = run_start;
                    if (diff == 0) break;
                }
            }
            current_run = 0;
        }
    }

    if (current_run >= required_zones) {
        const diff = current_run - required_zones;
        if (diff < best_run_diff) {
            best_start = run_start;
        }
    }

    if (best_start != NULL_INDEX) {
        var pages_left = pages;

        for (0..required_zones) |offset| {
            const z: u32 = best_start + @as(u32, @intCast(offset));
            removeZone(z, PAGES_PER_ZONE);

            const pages_to_take = @min(pages_left, PAGES_PER_ZONE);
            claimBits(z, 0, pages_to_take);

            free_counts[z] -= @intCast(pages_to_take);
            insertZone(z, free_counts[z]);

            pages_left -= pages_to_take;
        }

        std.debug.assert(pages_left == 0);
        available_pages -= pages;

        return @as(u64, best_start) * ZONE_SIZE;
    }

    return Error.OutOfMemory;
}

inline fn releaseBits(zone_idx: u32, start_bit: usize, count: usize) void {
    std.debug.assert(start_bit + count <= PAGES_PER_ZONE);

    if (start_bit == 0 and count == PAGES_PER_ZONE) {
        if (std.debug.runtime_safety) {
            std.debug.assert(bitmaps[zone_idx].count() == 0);
        }
        bitmaps[zone_idx] = ZoneBitSet.initFull();
        return;
    }

    var b: usize = 0;
    while (b < count) : (b += 1) {
        std.debug.assert(!bitmaps[zone_idx].isSet(start_bit + b));
        bitmaps[zone_idx].set(start_bit + b);
    }
}

pub fn freeContiguous(phys_addr: u64, pages: usize) void {
    if (pages == 0) return;

    std.debug.assert(phys_addr % PAGE_SIZE == 0);

    const max_pages = @as(u64, free_counts.len) * PAGES_PER_ZONE;
    const start_page = phys_addr / PAGE_SIZE;

    std.debug.assert(start_page < max_pages);
    std.debug.assert(pages <= max_pages - start_page);

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    var current_zone: u32 = @intCast(phys_addr / ZONE_SIZE);
    var start_bit: usize =
        @intCast((phys_addr % ZONE_SIZE) / PAGE_SIZE);

    var pages_left = pages;

    while (pages_left > 0) {
        const max_in_zone = PAGES_PER_ZONE - start_bit;
        const pages_to_free = @min(pages_left, max_in_zone);

        removeZone(current_zone, free_counts[current_zone]);

        releaseBits(current_zone, start_bit, pages_to_free);

        free_counts[current_zone] += @intCast(pages_to_free);
        insertZone(current_zone, free_counts[current_zone]);

        pages_left -= pages_to_free;
        current_zone += 1;
        start_bit = 0;
    }

    available_pages += pages;
}

pub fn freeNonContiguous(buffer: []u64) void {
    if (buffer.len == 0) return;

    if (PhysContext.current()) |phys_context| {
        @branchHint(.likely);

        var remaining = buffer;

        while (remaining.len > 0) {
            const space_in_recycle = phys_context.recycle_cache.len - phys_context.recycle_len;

            if (space_in_recycle > 0) {
                const chunk = @min(remaining.len, space_in_recycle);

                @memcpy(phys_context.recycle_cache[phys_context.recycle_len .. phys_context.recycle_len + chunk], remaining[0..chunk]);

                phys_context.recycle_len += chunk;
                remaining = remaining[chunk..];
            } else {
                if (phys_context.preheat_len > 0) {
                    _freeNonContiguous(phys_context.preheat_cache[0..phys_context.preheat_len]);
                }

                const temp_ptr = phys_context.preheat_cache;
                phys_context.preheat_cache = phys_context.recycle_cache;
                phys_context.recycle_cache = temp_ptr;

                phys_context.preheat_len = phys_context.recycle_len;
                phys_context.recycle_len = 0;
            }
        }
    } else {
        @branchHint(.cold);
        _freeNonContiguous(buffer);
    }
}

fn _freeNonContiguous(buffer: []u64) void {
    if (buffer.len == 0) return;

    std.mem.sortUnstable(u64, buffer, {}, std.sort.asc(u64));

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    var current_zone: u32 = NULL_INDEX;
    var current_count: u16 = 0;

    const max_pages = @as(u64, free_counts.len) * PAGES_PER_ZONE;

    for (buffer) |phys_addr| {
        std.debug.assert(phys_addr % PAGE_SIZE == 0);

        const page_idx = phys_addr / PAGE_SIZE;
        std.debug.assert(page_idx < max_pages);

        const zone_idx: u32 = @intCast(phys_addr / ZONE_SIZE);
        const page_bit_idx: usize = @intCast((phys_addr % ZONE_SIZE) / PAGE_SIZE);

        if (zone_idx != current_zone) {
            if (current_zone != NULL_INDEX) {
                free_counts[current_zone] = current_count;
                insertZone(current_zone, current_count);
            }
            current_zone = zone_idx;
            current_count = free_counts[zone_idx];
            removeZone(zone_idx, current_count);
        }

        std.debug.assert(!bitmaps[current_zone].isSet(page_bit_idx));

        bitmaps[current_zone].set(page_bit_idx);
        current_count += 1;
    }

    if (current_zone != NULL_INDEX) {
        free_counts[current_zone] = current_count;
        insertZone(current_zone, current_count);
    }

    available_pages += buffer.len;
}

pub inline fn freePage(page: u64) void {
    var buf: [1]u64 = .{page};
    freeNonContiguous(&buf);
}

fn validate() void {
    var total: usize = 0;

    for (free_counts, 0..) |count, i| {
        const z: u32 = @intCast(i);

        std.debug.assert(bitmaps[z].count() == count);
        total += count;

        const in_bucket =
            links[z].prev != NULL_INDEX or
            links[z].next != NULL_INDEX or
            density_buckets[count] == z;

        std.debug.assert(in_bucket);
    }

    std.debug.assert(total == available_pages);
}
