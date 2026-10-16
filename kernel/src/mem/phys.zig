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
var full_zones_bitmap: []u64 = undefined;
var density_buckets: [PAGES_PER_ZONE + 1]u32 = undefined;
var bucket_occupation: BucketBitSet = undefined;

pub fn updateHhdm() void {
    bitmaps.ptr = mem.updatePtrs(ZoneBitSet, bitmaps.ptr);
    free_counts.ptr = mem.updatePtrs(u16, free_counts.ptr);
    links.ptr = mem.updatePtrs(ZoneLinks, links.ptr);
    full_zones_bitmap.ptr = mem.updatePtrs(u64, full_zones_bitmap.ptr);
}

var total_pages: usize = undefined;
var available_pages: usize = undefined;

var global_lock: kernel.mem.utils.RwLock align(8) = undefined;

pub fn totalPages() usize {
    return total_pages;
}

pub fn availablePages() usize {
    const int_state = global_lock.acquire(.read, 0);
    defer global_lock.release(.read, int_state);

    return available_pages;
}

pub const PhysContext = struct {
    const CACHE_LEN: usize = switch (PAGE_SIZE) {
        4 * 1024 => 256,
        16 * 1024 => 128,
        64 * 1024 => 64,
        else => unreachable,
    };

    preheat_cache: *[CACHE_LEN]u64,
    preheat_len: usize,
    recycle_cache: *[CACHE_LEN]u64,
    recycle_len: usize,

    pub fn init(self: *PhysContext) !void {
        var page: [1]u64 = undefined;
        try _allocNonContiguous(&page);
        const base_va: [*]u64 = @ptrCast(mem.toHhdm(u64, page[0]));

        self.preheat_cache = base_va[0..CACHE_LEN];
        self.preheat_len = CACHE_LEN;

        self.recycle_cache = base_va[CACHE_LEN .. CACHE_LEN + CACHE_LEN];
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
        mem.updateRef([CACHE_LEN]u64, &self.preheat_cache);
        mem.updateRef([CACHE_LEN]u64, &self.recycle_cache);
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
    const full_words_count: usize = (zone_count + 63) / 64;

    const bitmaps_size = zone_count * @sizeOf(ZoneBitSet);
    const counts_size = zone_count * @sizeOf(u16);
    const links_size = zone_count * @sizeOf(ZoneLinks);
    const full_bitmap_size = full_words_count * @sizeOf(u64);

    const bitmaps_offset = 0;
    const counts_offset = std.mem.alignForward(u64, bitmaps_offset + bitmaps_size, @sizeOf(u64));
    const links_offset = std.mem.alignForward(u64, counts_offset + counts_size, @sizeOf(u64));
    const full_bitmap_offset = std.mem.alignForward(u64, links_offset + links_size, @sizeOf(u64));

    const total_metadata_bytes = std.mem.alignForward(u64, full_bitmap_offset + full_bitmap_size, PAGE_SIZE);

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

    full_zones_bitmap.ptr = @alignCast(@as([*]u64, @ptrFromInt(metadata_virt_base + full_bitmap_offset)));
    full_zones_bitmap.len = full_words_count;

    @memset(bitmaps, .empty);
    @memset(free_counts, 0);
    @memset(links, .{});
    @memset(full_zones_bitmap, 0);
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

        while (current_addr < end_addr) {
            const zone_idx: u32 = @intCast(current_addr / ZONE_SIZE);
            const start_bit: usize = @intCast((current_addr % ZONE_SIZE) / PAGE_SIZE);
            const remaining_pages = (end_addr - current_addr) / PAGE_SIZE;
            const pages_in_zone = @min(remaining_pages, PAGES_PER_ZONE - start_bit);

            releaseBits(zone_idx, start_bit, pages_in_zone);
            free_counts[zone_idx] += @intCast(pages_in_zone);
            available_pages += pages_in_zone;

            current_addr += pages_in_zone * PAGE_SIZE;
        }
    }

    for (0..zone_count) |i| {
        const idx: u32 = @intCast(i);
        insertZone(idx, free_counts[idx]);
    }

    total_pages = available_pages;

    if (builtin.optimize.runtimeSafety()) {
        validate();
    }
}

inline fn removeZone(zone_idx: u32, count: u16) void {
    std.debug.assert(free_counts[zone_idx] == count);

    if (count == PAGES_PER_ZONE) {
        const word_idx = zone_idx / 64;
        const bit_idx: u6 = @intCast(zone_idx % 64);
        full_zones_bitmap[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }

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

    if (count == PAGES_PER_ZONE) {
        const word_idx = zone_idx / 64;
        const bit_idx: u6 = @intCast(zone_idx % 64);
        full_zones_bitmap[word_idx] |= (@as(u64, 1) << bit_idx);
    }

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

        const cached_total = phys_context.recycle_len + phys_context.preheat_len;

        if (buffer.len <= cached_total) {
            const from_recycle = @min(buffer.len, phys_context.recycle_len);
            if (from_recycle > 0) {
                const start_idx = phys_context.recycle_len - from_recycle;
                @memcpy(
                    buffer[0..from_recycle],
                    phys_context.recycle_cache[start_idx..phys_context.recycle_len],
                );
                phys_context.recycle_len = start_idx;
            }

            const from_preheat = buffer.len - from_recycle;
            if (from_preheat > 0) {
                const start_idx = phys_context.preheat_len - from_preheat;
                @memcpy(
                    buffer[from_recycle..buffer.len],
                    phys_context.preheat_cache[start_idx..phys_context.preheat_len],
                );
                phys_context.preheat_len = start_idx;
            }
            return;
        }

        const needed = buffer.len - cached_total;

        if (needed < PhysContext.CACHE_LEN) {
            if (_allocNonContiguous(phys_context.preheat_cache[0..])) |_| {
                if (phys_context.recycle_len > 0) {
                    @memcpy(
                        buffer[0..phys_context.recycle_len],
                        phys_context.recycle_cache[0..phys_context.recycle_len],
                    );
                    phys_context.recycle_len = 0;
                }

                const rem_start = PhysContext.CACHE_LEN - needed;
                @memcpy(
                    buffer[cached_total..buffer.len],
                    phys_context.preheat_cache[rem_start..PhysContext.CACHE_LEN],
                );
                phys_context.preheat_len = rem_start;
                return;
            } else |_| {
                try _allocNonContiguous(buffer[cached_total..buffer.len]);
            }
        } else {
            try _allocNonContiguous(buffer[cached_total..buffer.len]);
        }

        const r_len = phys_context.recycle_len;
        if (r_len > 0) {
            @memcpy(buffer[0..r_len], phys_context.recycle_cache[0..r_len]);
            phys_context.recycle_len = 0;
        }

        const p_len = phys_context.preheat_len;
        if (p_len > 0) {
            @memcpy(buffer[r_len..cached_total], phys_context.preheat_cache[0..p_len]);
            phys_context.preheat_len = 0;
        }
    } else {
        @branchHint(.cold);
        return _allocNonContiguous(buffer);
    }
}

inline fn findMostFilledBucket() ?u16 {
    const MaskInt = @TypeOf(bucket_occupation.masks[0]);
    const BITS_PER_WORD = @bitSizeOf(MaskInt);

    const word0 = bucket_occupation.masks[0] & ~@as(MaskInt, 1);
    if (word0 != 0) {
        return @intCast(@ctz(word0));
    }

    for (bucket_occupation.masks[1..], 1..) |word, w| {
        if (word != 0) {
            return @intCast(w * BITS_PER_WORD + @ctz(word));
        }
    }

    return null;
}

fn _allocNonContiguous(buffer: []u64) !void {
    if (buffer.len == 0) return;

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    if (available_pages < buffer.len) {
        return Error.OutOfMemory;
    }

    const MaskInt = @TypeOf(bitmaps[0].masks[0]);
    const FULL_WORD: MaskInt = ~@as(MaskInt, 0);
    const BITS_PER_WORD = @bitSizeOf(MaskInt);

    available_pages -= buffer.len;
    var filled: usize = 0;

    while (filled < buffer.len) {
        const bucket = findMostFilledBucket() orelse unreachable;
        const zone_idx = density_buckets[bucket];
        removeZone(zone_idx, bucket);

        std.debug.assert(free_counts[zone_idx] == bucket);
        const pages_to_pump = @min(buffer.len - filled, bucket);
        const zone_base = @as(u64, zone_idx) * ZONE_SIZE;

        if (pages_to_pump == PAGES_PER_ZONE) {
            for (0..PAGES_PER_ZONE) |p| {
                buffer[filled + p] = zone_base + (@as(u64, p) * PAGE_SIZE);
            }
            filled += PAGES_PER_ZONE;
            bitmaps[zone_idx] = .empty;
        } else if (pages_to_pump == bucket) {
            for (bitmaps[zone_idx].masks, 0..) |word_val, word_idx| {
                var word = word_val;
                if (word == 0) continue;

                const word_base = zone_base + (@as(u64, word_idx) * BITS_PER_WORD * PAGE_SIZE);
                while (word != 0) {
                    const bit = @ctz(word);
                    word &= word - 1;

                    buffer[filled] = word_base + (@as(u64, bit) * PAGE_SIZE);
                    filled += 1;
                }
            }
            bitmaps[zone_idx] = .empty;
        } else {
            var remaining: usize = pages_to_pump;

            for (&bitmaps[zone_idx].masks, 0..) |*word_ptr, word_idx| {
                var word = word_ptr.*;
                if (word == 0 or word == FULL_WORD) continue;

                const word_base = zone_base + (@as(u64, word_idx) * BITS_PER_WORD * PAGE_SIZE);
                while (word != 0) {
                    const bit = @ctz(word);
                    word &= word - 1;

                    buffer[filled] = word_base + (@as(u64, bit) * PAGE_SIZE);
                    filled += 1;
                    remaining -= 1;

                    if (remaining == 0) {
                        word_ptr.* = word;
                        break;
                    }
                } else {
                    word_ptr.* = 0;
                    continue;
                }
                break;
            }

            if (remaining > 0) {
                for (&bitmaps[zone_idx].masks, 0..) |*word_ptr, word_idx| {
                    var word = word_ptr.*;
                    if (word != FULL_WORD) continue;

                    const word_base = zone_base + (@as(u64, word_idx) * BITS_PER_WORD * PAGE_SIZE);
                    if (remaining >= BITS_PER_WORD) {
                        for (0..BITS_PER_WORD) |bit| {
                            buffer[filled + bit] = word_base + (@as(u64, bit) * PAGE_SIZE);
                        }
                        filled += BITS_PER_WORD;
                        remaining -= BITS_PER_WORD;
                        word_ptr.* = 0;
                        if (remaining == 0) break;
                    } else {
                        for (0..remaining) |bit| {
                            buffer[filled + bit] = word_base + (@as(u64, bit) * PAGE_SIZE);
                        }
                        filled += remaining;
                        const ShiftInt = std.math.Log2Int(MaskInt);
                        word = FULL_WORD << @as(ShiftInt, @intCast(remaining));
                        word_ptr.* = word;
                        break;
                    }
                }
            }
        }

        free_counts[zone_idx] = bucket - @as(u16, @intCast(pages_to_pump));
        insertZone(zone_idx, free_counts[zone_idx]);
    }
}

pub inline fn allocPage() !u64 {
    if (PhysContext.current()) |ctx| {
        @branchHint(.likely);
        if (ctx.recycle_len > 0) {
            ctx.recycle_len -= 1;
            return ctx.recycle_cache[ctx.recycle_len];
        }
        if (ctx.preheat_len > 0) {
            ctx.preheat_len -= 1;
            return ctx.preheat_cache[ctx.preheat_len];
        }
    }

    var page: [1]u64 = undefined;
    try allocNonContiguous(&page);
    return page[0];
}

fn findContiguousBits(bitmap: *const ZoneBitSet, count: usize) ?usize {
    const MaskInt = @TypeOf(bitmap.masks[0]);
    const FULL_WORD: MaskInt = ~@as(MaskInt, 0);
    const BITS_PER_WORD = @bitSizeOf(MaskInt);
    const ShiftInt = std.math.Log2Int(MaskInt);

    var best_start: ?usize = null;
    var best_len: usize = std.math.maxInt(usize);

    var current_run: usize = 0;
    var run_start: usize = 0;

    for (bitmap.masks, 0..) |word, w| {
        const word_bit_base = w * BITS_PER_WORD;

        if (word == 0) {
            if (current_run >= count and current_run < best_len) {
                best_len = current_run;
                best_start = run_start;
                if (best_len == count) return best_start;
            }
            current_run = 0;
            continue;
        }

        if (word == FULL_WORD) {
            if (current_run == 0) run_start = word_bit_base;
            current_run += BITS_PER_WORD;
            continue;
        }

        const prefix: usize = @ctz(~word);
        if (current_run > 0) {
            const total_run = current_run + prefix;
            if (total_run >= count and total_run < best_len) {
                best_len = total_run;
                best_start = run_start;
                if (best_len == count) return best_start;
            }
            current_run = 0;
        } else if (prefix > 0) {
            if (prefix >= count and prefix < best_len) {
                best_len = prefix;
                best_start = word_bit_base;
                if (best_len == count) return best_start;
            }
        }

        const suffix: usize = @clz(~word);

        const low_mask = FULL_WORD << @as(ShiftInt, @intCast(prefix));
        const high_mask = FULL_WORD >> @as(ShiftInt, @intCast(suffix));
        var mid: MaskInt = word & low_mask & high_mask;

        if (@popCount(mid) >= count) {
            while (mid != 0) {
                const bit_pos: usize = @ctz(mid);
                const lsb: MaskInt = mid & -%mid;
                const sum: MaskInt = mid + lsb;

                const run_len: usize = @ctz(sum) - bit_pos;
                if (run_len >= count and run_len < best_len) {
                    best_len = run_len;
                    best_start = word_bit_base + bit_pos;
                    if (best_len == count) return best_start;
                }

                mid &= sum;
            }
        }

        current_run = suffix;
        run_start = word_bit_base + (BITS_PER_WORD - suffix);
    }

    if (current_run >= count and current_run < best_len) {
        best_start = run_start;
    }

    return best_start;
}

inline fn claimBits(zone_idx: u32, start_bit: usize, count: usize) void {
    std.debug.assert(count > 0);
    std.debug.assert(start_bit + count <= PAGES_PER_ZONE);

    if (start_bit == 0 and count == PAGES_PER_ZONE) {
        if (std.debug.runtime_safety) {
            std.debug.assert(bitmaps[zone_idx].count() == PAGES_PER_ZONE);
        }
        bitmaps[zone_idx] = .empty;
        return;
    }

    const MaskInt = @TypeOf(bitmaps[0].masks[0]);
    const BITS_PER_WORD = @bitSizeOf(MaskInt);
    const ShiftInt = std.math.Log2Int(MaskInt);

    const end_bit = start_bit + count - 1;
    const first_word = start_bit / BITS_PER_WORD;
    const last_word = end_bit / BITS_PER_WORD;

    const masks = &bitmaps[zone_idx].masks;
    for (first_word..last_word + 1) |w| {
        const lo = if (w == first_word) start_bit % BITS_PER_WORD else 0;
        const hi = if (w == last_word) end_bit % BITS_PER_WORD else BITS_PER_WORD - 1;

        const low_mask = ~@as(MaskInt, 0) << @as(ShiftInt, @intCast(lo));
        const high_mask = ~@as(MaskInt, 0) >> @as(ShiftInt, @intCast((BITS_PER_WORD - 1) - hi));
        const mask = low_mask & high_mask;

        std.debug.assert((masks[w] & mask) == mask);
        masks[w] &= ~mask;
    }
}

fn findContiguousFullZones(required_zones: u32) ?u32 {
    const FULL_WORD: u64 = ~@as(u64, 0);

    var best_start: ?u32 = null;
    var best_len: u32 = std.math.maxInt(u32);

    var current_run: u32 = 0;
    var run_start: u32 = 0;

    for (full_zones_bitmap, 0..) |word, w| {
        const word_zone_base: u32 = @intCast(w * 64);

        if (word == 0) {
            if (current_run >= required_zones and current_run < best_len) {
                best_len = current_run;
                best_start = run_start;
                if (best_len == required_zones) return best_start;
            }
            current_run = 0;
            continue;
        }

        if (word == FULL_WORD) {
            if (current_run == 0) run_start = word_zone_base;
            current_run += 64;
            continue;
        }

        const prefix: u32 = @ctz(~word);
        if (current_run > 0) {
            const total_run = current_run + prefix;
            if (total_run >= required_zones and total_run < best_len) {
                best_len = total_run;
                best_start = run_start;
                if (best_len == required_zones) return best_start;
            }
            current_run = 0;
        } else if (prefix > 0) {
            if (prefix >= required_zones and prefix < best_len) {
                best_len = prefix;
                best_start = word_zone_base;
                if (best_len == required_zones) return best_start;
            }
        }

        const suffix: u32 = @clz(~word);

        const low_mask = FULL_WORD << @as(u6, @intCast(prefix));
        const high_mask = FULL_WORD >> @as(u6, @intCast(suffix));
        var mid: u64 = word & low_mask & high_mask;

        if (@popCount(mid) >= required_zones) {
            while (mid != 0) {
                const bit_pos: u32 = @ctz(mid);
                const lsb: u64 = mid & -%mid;
                const sum: u64 = mid + lsb;

                const run_len: u32 = @ctz(sum) - bit_pos;
                if (run_len >= required_zones and run_len < best_len) {
                    best_len = run_len;
                    best_start = word_zone_base + bit_pos;
                    if (best_len == required_zones) return best_start;
                }

                mid &= sum;
            }
        }

        current_run = suffix;
        run_start = word_zone_base + (64 - suffix);
    }

    if (current_run >= required_zones and current_run < best_len) {
        best_start = run_start;
    }

    return best_start;
}

pub fn allocContiguous(pages: usize) Error!u64 {
    if (pages == 0) return 0;

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    if (available_pages < pages) return Error.OutOfMemory;

    if (pages <= PAGES_PER_ZONE) {
        if (pages < PAGES_PER_ZONE) {
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
        }

        const full_zone = density_buckets[PAGES_PER_ZONE];
        if (full_zone != NULL_INDEX) {
            removeZone(full_zone, PAGES_PER_ZONE);

            claimBits(full_zone, 0, pages);

            free_counts[full_zone] = @intCast(PAGES_PER_ZONE - pages);
            insertZone(full_zone, free_counts[full_zone]);
            available_pages -= pages;

            return @as(u64, full_zone) * ZONE_SIZE;
        }

        return Error.OutOfMemory;
    }

    if (!bucket_occupation.isSet(PAGES_PER_ZONE)) {
        return Error.OutOfMemory;
    }

    const required_zones: u32 = @intCast((pages - 1) / PAGES_PER_ZONE + 1);

    if (findContiguousFullZones(required_zones)) |best_start| {
        var pages_left = pages;

        for (0..required_zones) |offset| {
            const z: u32 = best_start + @as(u32, @intCast(offset));
            removeZone(z, PAGES_PER_ZONE);

            const pages_to_take = @min(pages_left, PAGES_PER_ZONE);
            claimBits(z, 0, pages_to_take);

            free_counts[z] = @intCast(PAGES_PER_ZONE - pages_to_take);
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
    std.debug.assert(count > 0);
    std.debug.assert(start_bit + count <= PAGES_PER_ZONE);

    if (start_bit == 0 and count == PAGES_PER_ZONE) {
        if (std.debug.runtime_safety) {
            std.debug.assert(bitmaps[zone_idx].count() == 0);
        }
        bitmaps[zone_idx] = .full;
        return;
    }

    const MaskInt = @TypeOf(bitmaps[0].masks[0]);
    const BITS_PER_WORD = @bitSizeOf(MaskInt);
    const ShiftInt = std.math.Log2Int(MaskInt);

    const end_bit = start_bit + count - 1;
    const first_word = start_bit / BITS_PER_WORD;
    const last_word = end_bit / BITS_PER_WORD;

    const masks = &bitmaps[zone_idx].masks;
    for (first_word..last_word + 1) |w| {
        const lo = if (w == first_word) start_bit % BITS_PER_WORD else 0;
        const hi = if (w == last_word) end_bit % BITS_PER_WORD else BITS_PER_WORD - 1;

        const low_mask = ~@as(MaskInt, 0) << @as(ShiftInt, @intCast(lo));
        const high_mask = ~@as(MaskInt, 0) >> @as(ShiftInt, @intCast((BITS_PER_WORD - 1) - hi));
        const mask = low_mask & high_mask;

        std.debug.assert((masks[w] & mask) == 0);
        masks[w] |= mask;
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
            const space_in_recycle = PhysContext.CACHE_LEN - phys_context.recycle_len;

            if (space_in_recycle > 0) {
                const chunk = @min(remaining.len, space_in_recycle);

                @memcpy(
                    phys_context.recycle_cache[phys_context.recycle_len .. phys_context.recycle_len + chunk],
                    remaining[0..chunk],
                );

                phys_context.recycle_len += chunk;
                remaining = remaining[chunk..];
            } else if (remaining.len >= PhysContext.CACHE_LEN and phys_context.preheat_len > 0) {
                _freeNonContiguous(remaining);
                return;
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

    if (buffer.len > 1) {
        std.mem.sortUnstable(u64, buffer, {}, std.sort.asc(u64));
    }

    const int_state = global_lock.acquire(.write, 0);
    defer global_lock.release(.write, int_state);

    const max_pages = @as(u64, free_counts.len) * PAGES_PER_ZONE;
    var i: usize = 0;

    while (i < buffer.len) {
        const first_addr = buffer[i];
        std.debug.assert(first_addr % PAGE_SIZE == 0);
        std.debug.assert((first_addr / PAGE_SIZE) < max_pages);

        const zone_idx: u32 = @intCast(first_addr / ZONE_SIZE);
        var count = free_counts[zone_idx];
        removeZone(zone_idx, count);

        const zone_bitmap = &bitmaps[zone_idx];
        const first_bit: usize = @intCast((first_addr % ZONE_SIZE) / PAGE_SIZE);
        std.debug.assert(!zone_bitmap.isSet(first_bit));
        zone_bitmap.set(first_bit);
        count += 1;
        i += 1;

        while (i < buffer.len) {
            const addr = buffer[i];
            const next_zone: u32 = @intCast(addr / ZONE_SIZE);
            if (next_zone != zone_idx) break;

            std.debug.assert(addr % PAGE_SIZE == 0);
            std.debug.assert((addr / PAGE_SIZE) < max_pages);

            const bit_idx: usize = @intCast((addr % ZONE_SIZE) / PAGE_SIZE);
            std.debug.assert(!zone_bitmap.isSet(bit_idx));
            zone_bitmap.set(bit_idx);

            count += 1;
            i += 1;
        }

        free_counts[zone_idx] = count;
        insertZone(zone_idx, count);
    }

    available_pages += buffer.len;
}

pub inline fn freePage(page: u64) void {
    if (PhysContext.current()) |ctx| {
        @branchHint(.likely);
        if (ctx.recycle_len < PhysContext.CACHE_LEN) {
            ctx.recycle_cache[ctx.recycle_len] = page;
            ctx.recycle_len += 1;
            return;
        }
    }

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

        const is_marked_full = (full_zones_bitmap[z / 64] & (@as(u64, 1) << @as(u6, @intCast(z % 64)))) != 0;
        std.debug.assert(is_marked_full == (count == PAGES_PER_ZONE));
    }

    std.debug.assert(total == available_pages);
}
