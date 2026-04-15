test "server lifecycle" {
    var loop: http.Loop = .init(std.testing.io, std.testing.allocator);
    defer loop.deinit();

    var server = http.default_server(&loop, .{});
    defer server.deinit();

    const r = http.routing;
    try server.router("", .{
        .{ "/hello",
            r.static_internal(.{
                .content = "Hello World",
                .content_type = .text_utf8,
            }),
        },
        .{ "/shutdown",
            r.static_internal(.{
                .content = "Shutting Down",
                .content_type = .html_utf8,
            }),
            r.shutdown,
        },
    });

    loop.start();
    defer loop.finish_running();

    try server.lookup_and_start("127.0.0.1", 21345, .{});

    loop.begin_running();
    loop.stop();
    loop.finish_running();
}

const http = @import("http");
const std = @import("std");
