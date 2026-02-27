pub fn Default_Server(comptime comptime_options: server.Comptime_Options) type {
    const providers = struct {
        pub fn inject_cid(req: *Request) Connection_Id {
            return req.cid;
        }

        pub fn inject_random(req: *Request) !std.Random {
            const rng: *std.Random.Xoshiro256 = try req.arena.create(std.Random.Xoshiro256);
            var seed: [4]u64 = undefined;
            req.io.random(std.mem.asBytes(&seed));
            rng.* = .{
                .s = seed,
            };
            return rng.random();
        }

        pub fn inject_allocator(req: *Request) !std.mem.Allocator {
            try req.replace_arena();
            return req.arena;
        }

        pub fn inject_temp_allocator(req: *Request) !*Temp_Allocator {
            try req.replace_arena();
            return &req.internal.ta_pool.allocators[req.internal.ta_pool.index.?];
        }

        pub fn inject_loop(req: *Request) *Loop {
            return req.internal.loop;
        }
    };

    return Server(dizzy.Injector(providers, .{ .Input_Type = *Request }), comptime_options);
}

const log = std.log.scoped(.http);

const Server = server.Server;
const server = @import("server.zig");
const Loop = @import("Loop.zig");
const Request = @import("Request.zig");
const Index_Pool = @import("Index_Pool.zig");
const Connection_Id = @import("Connection_Id.zig");
const Temp_Allocator = @import("Temp_Allocator");
const dizzy = @import("dizzy");
const fmt = @import("fmt");
const std = @import("std");
