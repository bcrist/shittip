loop: *Loop,
registry: *const std.StringHashMapUnmanaged(std.ArrayList(server.Handler)),
body: ?*std.Io.Reader, // use .body_reader() to populate/access this
decompress: std.http.Decompress,
header_strings_cloned: bool,
ta_pool: struct {
    pool: *Index_Pool,
    allocators: []Temp_Allocator,
    index: ?usize,
},
// same as req.head_buffer, but we copy it into the arena to avoid it going undefined when reading request body content
head_buffer: []const u8,
scratch_alloc: std.heap.FixedBufferAllocator,
fallback_alloc: std.heap.ArenaAllocator,
handler_data: ?*anyopaque,

pub fn temp_allocator(self: *Request_Internal, entropy: usize) error{InsufficientResources}!*Temp_Allocator {
    const index = self.ta_pool.index orelse i: {
        const index = try self.ta_pool.pool.acquire(entropy);
        self.ta_pool.index = index;
        break :i index;
    };
    return &self.ta_pool.allocators[index];
}

pub inline fn arena(self: *Request_Internal) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub inline fn arena_thread_safe(self: *Request_Internal) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc_thread_safe,
            .resize = resize_thread_safe,
            .remap = remap_thread_safe,
            .free = free_thread_safe,
        },
    };
}

const fba_vtable_thread_safe = std.heap.FixedBufferAllocator.threadSafeAllocator(undefined).vtable;
const arena_alloc_vtable = std.heap.ArenaAllocator.allocator(undefined).vtable;
const ta_vtable = Temp_Allocator.allocator(undefined).vtable;
const ta_vtable_thread_safe = Temp_Allocator.allocator_thread_safe(undefined).vtable;

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (std.heap.FixedBufferAllocator.alloc(&self.scratch_alloc, len, alignment, ret_addr)) |ptr| return ptr;
    
    const entropy: usize = @intCast(std.Io.Timestamp.now(self.loop.io, .awake).toNanoseconds() & 0xFFFF);
    const ta = self.temp_allocator(entropy) catch {
        return arena_alloc_vtable.alloc(&self.fallback_alloc, len, alignment, ret_addr);
    };

    return ta_vtable.alloc(ta, len, alignment, ret_addr);
}

fn alloc_thread_safe(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (fba_vtable_thread_safe.alloc(&self.scratch_alloc, len, alignment, ret_addr)) |ptr| return ptr;
    
    if (self.ta_pool.index) |index| {
        return ta_vtable_thread_safe.alloc(&self.ta_pool.allocators[index], len, alignment, ret_addr);
    }

    return arena_alloc_vtable.alloc(&self.fallback_alloc, len, alignment, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (self.scratch_alloc.ownsPtr(buf.ptr)) {
        return std.heap.FixedBufferAllocator.resize(&self.scratch_alloc, buf, alignment, new_len, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(buf.ptr)) {
            return ta_vtable.resize(ta, buf, alignment, new_len, ret_addr);
        }
    }

    return arena_alloc_vtable.resize(&self.fallback_alloc, buf, alignment, new_len, ret_addr);
}

fn resize_thread_safe(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (self.scratch_alloc.ownsPtr(buf.ptr)) {
        return fba_vtable_thread_safe.resize(&self.scratch_alloc, buf, alignment, new_len, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(buf.ptr)) {
            return ta_vtable_thread_safe.resize(ta, buf, alignment, new_len, ret_addr);
        }
    }

    return arena_alloc_vtable.resize(&self.fallback_alloc, buf, alignment, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (self.scratch_alloc.ownsPtr(memory.ptr)) {
        return std.heap.FixedBufferAllocator.remap(&self.scratch_alloc, memory, alignment, new_len, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(memory.ptr)) {
            return ta_vtable.remap(ta, memory, alignment, new_len, ret_addr);
        }
    }

    return arena_alloc_vtable.remap(&self.fallback_alloc, memory, alignment, new_len, ret_addr);
}

fn remap_thread_safe(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));

    if (self.scratch_alloc.ownsPtr(memory.ptr)) {
        return fba_vtable_thread_safe.remap(&self.scratch_alloc, memory, alignment, new_len, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(memory.ptr)) {
            return ta_vtable_thread_safe.remap(ta, memory, alignment, new_len, ret_addr);
        }
    }

    return arena_alloc_vtable.remap(&self.fallback_alloc, memory, alignment, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));
    
    if (self.scratch_alloc.ownsPtr(buf.ptr)) {
        return std.heap.FixedBufferAllocator.free(&self.scratch_alloc, buf, alignment, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(buf.ptr)) {
            return ta_vtable.free(ta, buf, alignment, ret_addr);
        }
    }

    return arena_alloc_vtable.free(&self.fallback_alloc, buf, alignment, ret_addr);
}

fn free_thread_safe(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Request_Internal = @ptrCast(@alignCast(ctx));
    
    if (self.scratch_alloc.ownsPtr(buf.ptr)) {
        return fba_vtable_thread_safe.free(&self.scratch_alloc, buf, alignment, ret_addr);
    }

    if (self.ta_pool.index) |index| {
        const ta = &self.ta_pool.allocators[index];
        if (ta.owns_ptr(buf.ptr)) {
            return ta_vtable_thread_safe.free(ta, buf, alignment, ret_addr);
        }
    }

    return arena_alloc_vtable.free(&self.fallback_alloc, buf, alignment, ret_addr);
}

const Request_Internal = @This();

const Index_Pool = @import("Index_Pool.zig");
const Loop = @import("Loop.zig");
const server = @import("server.zig");
const Temp_Allocator = @import("Temp_Allocator");
const std = @import("std");
