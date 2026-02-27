bitset: std.DynamicBitSetUnmanaged,

pub const init: Index_Pool = .{
    .bitset = .{},
};

pub fn deinit(self: *Index_Pool, allocator: std.mem.Allocator) void {
    self.bitset.deinit(allocator);
}

// Not threadsafe.
pub fn reset(self: *Index_Pool, allocator: std.mem.Allocator, size: usize) !void {
    if (size > self.bitset.capacity()) {
        self.bitset.setAll();
        try self.bitset.resize(allocator, size, true);
    } else {
        try self.bitset.resize(allocator, size, true);
        self.bitset.setAll();
    }
}

pub fn acquire(self: *Index_Pool, random: usize) !usize {
    const count = self.bitset.bit_length;
    const num_masks = self.get_num_masks();
    const first = random % num_masks;
    var offset: usize = first * @bitSizeOf(Mask_Int);
    for (self.bitset.masks[first..num_masks]) |*mask| {
        return try_acquire(offset, mask, count) orelse {
            offset += @bitSizeOf(Mask_Int);
            continue;
        };
    }
    offset = 0;
    for (self.bitset.masks[0..first]) |*mask| {
        return try_acquire(offset, mask, count) orelse {
            offset += @bitSizeOf(Mask_Int);
            continue;
        };
    }
    return error.InsufficientResources;
}

fn try_acquire(offset: usize, mask: *Mask_Int, count: usize) ?usize {
    var current = @atomicLoad(Mask_Int, mask, .acquire);
    while (true) {
        if (current == 0) return null;
        const new = current & (current - 1); // clear lowest set bit
        if (@cmpxchgWeak(Mask_Int, mask, current, new, .acq_rel, .acquire)) |new_current| {
            current = new_current;
        } else {
            const index = offset + @ctz(current);
            return if (index < count) index else null;
        }
    }
}

pub fn release(self: *Index_Pool, index: usize) void {
    const count = self.bitset.bit_length;
    std.debug.assert(index < count);

    const mask = &self.bitset.masks[mask_index(index)];
    const bit_to_set = mask_bit(index);

    var current = @atomicLoad(Mask_Int, mask, .acquire);
    while (true) {
        const new = current | bit_to_set;
        if (@cmpxchgWeak(Mask_Int, mask, current, new, .acq_rel, .acquire)) |new_current| {
            current = new_current;
        } else return;
    }
}

inline fn get_num_masks(self: *const Index_Pool) usize {
    return (self.bitset.bit_length + (@bitSizeOf(Mask_Int) - 1)) / @bitSizeOf(Mask_Int);
}

inline fn mask_index(index: usize) usize {
    return index >> @bitSizeOf(Shift_Int);
}

inline fn mask_bit(index: usize) Mask_Int {
    return @as(Mask_Int, 1) << @as(Shift_Int, @truncate(index));
}

const Mask_Int = std.DynamicBitSetUnmanaged.MaskInt;
const Shift_Int = std.DynamicBitSetUnmanaged.ShiftInt;

const Index_Pool = @This();

const std = @import("std");
