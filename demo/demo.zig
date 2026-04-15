pub fn main(init: std.process.Init) !void {
    var threaded_io: std.Io.Threaded = .init(init.gpa, .{
        .stack_size = 2 * 1024 * 1024,
    });
    defer threaded_io.deinit();

    var loop: http.Loop = .init(threaded_io.io(), init.gpa);
    defer loop.deinit();

    var server = http.default_server(&loop, .{});
    defer server.deinit();

    const Injector = @TypeOf(server).Injector;
    const r = http.routing;
    try server.router("", .{
        .{ "/", r.module(Injector, index) },
        .{ "/something/**" },
        .{ "/something_else/**", "/something/**" },
        r.resource("style.css"),
    });

    try server.router("/something/**", .{
        .{ "shutdown", r.method(.GET), r.shutdown },
        .{ "hello", r.replace_arena, r.module(Injector, hello) },
        .{ "hello/id:*", r.replace_arena, r.module(Injector, hello) },
    });

    loop.start();
    defer loop.finish_running();

    try server.lookup_and_start("localhost", 21345, .{});
    
    loop.begin_running();
}

const hello = struct {
    pub fn get(req: *http.Request) !void {
        std.log.info("Hellorld!", .{});
        try req.respond("Hellorld!");
    }

    pub fn post(req: *http.Request) !void {
        std.log.info("Hello Post!", .{});
        try req.respond("Hello Post!");
    }
};

const index = struct {
    pub fn get(req: *http.Request) !void {
        try req.render("index.zk", {}, .{});
    }
};

pub const resources = @import("resources");

const http = @import("http");
const std = @import("std");
