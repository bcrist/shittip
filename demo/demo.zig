pub fn main(init: std.process.Init) !void {
    var threaded_io: std.Io.Threaded = .init(init.gpa, .{
        .stack_size = 2 * 1024 * 1024,
    });
    defer threaded_io.deinit();

    var loop: http.Loop = .init(threaded_io.io(), init.gpa);
    defer loop.deinit();

    var server = http.default_server(&loop, .{});
    defer server.deinit();


    const Module = comptime http.routing.Module(@TypeOf(server).Injector);
    try server.router("", .{
        .{ "/", Module(index) },
        .{ "/something/**" },
        .{ "/something_else/**", "/something/**" },
        http.routing.resource("style.css"),
        .{ "/semi-static", "semi_static" },
    });

    try server.router("/something/**", .{
        .{ "shutdown", http.routing.method(.GET), http.routing.shutdown },
        .{ "hello", Module(hello) },
        .{ "hello/id:*", Module(hello) },
    });

    var updatable_module: http.Static_Updatable = try .init(init.gpa, loop.io, "updatable.zk", .{
        .asdf = "1234",
    }, .{}, http.Content_Type.text_utf8);
    defer updatable_module.deinit();
    try server.register_module("semi_static", &updatable_module);

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
