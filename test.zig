

fn run_server_guarded() void {
    run_server() catch @panic("run_server() errored!");
}

fn run_server(loop: *http.Loop) !void {
    var server = http.default_server(loop, .{});
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
}


test "server lifecycle" {
    var loop: http.Loop = .init(std.testing.io, std.testing.allocator);
    defer loop.deinit();

    var server_future = try std.testing.io.concurrent(run_server, .{ &loop });

    var client: std.http.Client = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    defer client.deinit();

    {
        var content: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer content.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = "http://localhost:21345/hello" },
            .method = .GET,
            .keep_alive = false,
            .response_writer = &content.writer,
        });
        try std.testing.expectEqual(.ok, result.status);
        try std.testing.expectEqualStrings("Hello World", content.written());
    }
    {
        const result = try client.fetch(.{
            .location = .{ .url = "http://localhost:21345/shutdown" },
            .method = .GET,
            .keep_alive = false,
        });
        try std.testing.expectEqual(.ok, result.status);
    }

    // loop.stop();

    try server_future.await(std.testing.io);
}

const http = @import("http");
const std = @import("std");
