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

test "Range.parse" {
    try std.testing.expectFmt("[0...0]", "{f}", .{ try http.Range.parse("0-0") });
    try std.testing.expectFmt("[0...]", "{f}", .{ try http.Range.parse("0-") });
    try std.testing.expectFmt("[500...]", "{f}", .{ try http.Range.parse("500-") });
    try std.testing.expectFmt("[500...501]", "{f}", .{ try http.Range.parse("500-501") });
    try std.testing.expectFmt("[...500]", "{f}", .{ try http.Range.parse("-500") });
    try std.testing.expectFmt("[0...0]", "{f}", .{ try http.Range.parse(" 0 - 0 ") });
    try std.testing.expectFmt("[0...]", "{f}", .{ try http.Range.parse(" 0 - ") });
    try std.testing.expectFmt("[500...]", "{f}", .{ try http.Range.parse(" 500 - ") });
    try std.testing.expectFmt("[500...501]", "{f}", .{ try http.Range.parse("    500      - 501    ") });
    try std.testing.expectFmt("[...500]", "{f}", .{ try http.Range.parse(" - 500  ") });
    try std.testing.expectError(error.BadRange, http.Range.parse(""));
    try std.testing.expectError(error.BadRange, http.Range.parse("   "));
    try std.testing.expectError(error.BadRange, http.Range.parse("--"));
    try std.testing.expectError(error.BadRange, http.Range.parse("0-500 0-500"));
    try std.testing.expectError(error.BadRange, http.Range.parse("0-500-"));
    try std.testing.expectError(error.BadRange, http.Range.parse("+0-500"));
    try std.testing.expectError(error.BadRange, http.Range.parse("/0-500"));
}

test "Range.satisfy" {
    try std.testing.expectFmt("[0..][0..1]", "{f}", .{ try (try http.Range.parse("0-0")).satisfy(1000) });
    try std.testing.expectFmt("[0..][0..1000]", "{f}", .{ try (try http.Range.parse("0-")).satisfy(1000) });
    try std.testing.expectFmt("[500..][0..500]", "{f}", .{ try (try http.Range.parse("500-")).satisfy(1000) });
    try std.testing.expectFmt("[500..][0..2]", "{f}", .{ try (try http.Range.parse("500-501")).satisfy(1000) });
    try std.testing.expectFmt("[500..][0..500]", "{f}", .{ try (try http.Range.parse("-500")).satisfy(1000) });
    try std.testing.expectFmt("[900..][0..100]", "{f}", .{ try (try http.Range.parse("-100")).satisfy(1000) });
}

test "Range.Satisfied.maybe_coalesce" {
    const r1: http.Range.Satisfied = .{ .offset = 0, .len = 10 };
    const r2: http.Range.Satisfied = .{ .offset = 5, .len = 100 };
    const r3: http.Range.Satisfied = .{ .offset = 50, .len = 10 };

    try std.testing.expectEqual(r1, r1.maybe_coalesce(r1, 0));
    try std.testing.expectEqual(r2, r2.maybe_coalesce(r2, 10));
    try std.testing.expectEqual(r3, r3.maybe_coalesce(r3, 1000));

    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 105 }, r1.maybe_coalesce(r2, 0));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 105 }, r2.maybe_coalesce(r1, 0));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 105 }, r1.maybe_coalesce(r2, 50));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 105 }, r2.maybe_coalesce(r1, 50));

    try std.testing.expectEqual(http.Range.Satisfied { .offset = 5, .len = 100 }, r2.maybe_coalesce(r3, 0));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 5, .len = 100 }, r3.maybe_coalesce(r2, 0));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 5, .len = 100 }, r2.maybe_coalesce(r3, 50));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 5, .len = 100 }, r3.maybe_coalesce(r2, 50));

    try std.testing.expectEqual(null, r1.maybe_coalesce(r3, 0));
    try std.testing.expectEqual(null, r3.maybe_coalesce(r1, 0));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 60 }, r1.maybe_coalesce(r3, 50));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 60 }, r3.maybe_coalesce(r1, 50));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 60 }, r1.maybe_coalesce(r3, 40));
    try std.testing.expectEqual(http.Range.Satisfied { .offset = 0, .len = 60 }, r3.maybe_coalesce(r1, 40));
    try std.testing.expectEqual(null, r1.maybe_coalesce(r3, 39));
    try std.testing.expectEqual(null, r3.maybe_coalesce(r1, 39));
}

test "Range.Iterator" {
    var iter: http.Range.Iterator = try .init("bytes=1-10,50-100");
    try std.testing.expectEqualStrings("bytes", iter.unit);
    try std.testing.expectFmt("[1...10]", "{?f}", .{ try iter.next() });
    try std.testing.expectFmt("[50...100]", "{?f}", .{ try iter.next() });
    try std.testing.expectFmt("null", "{?f}", .{ try iter.next() });

    iter = try .init("monkeys   =   1-10  ,   50-100   ");
    try std.testing.expectEqualStrings("monkeys", iter.unit);
    try std.testing.expectFmt("[1...10]", "{?f}", .{ try iter.next() });
    try std.testing.expectFmt("[50...100]", "{?f}", .{ try iter.next() });
    try std.testing.expectFmt("null", "{?f}", .{ try iter.next() });

    try std.testing.expectError(error.BadRange, http.Range.Iterator.init("asdf"));

    iter = try .init("bytes   =   1--  ,   50-100   ");
    try std.testing.expectEqualStrings("bytes", iter.unit);
    try std.testing.expectError(error.BadRange, iter.next());
    try std.testing.expectFmt("[50...100]", "{?f}", .{ try iter.next() });
    try std.testing.expectFmt("null", "{?f}", .{ try iter.next() });

    iter = try .init("bytes   =   1--  ,   50-100   ");
    try std.testing.expectEqualStrings("bytes", iter.unit);
    try std.testing.expectFmt("[50...100]", "{?f}", .{ iter.next_valid() });
    try std.testing.expectFmt("null", "{?f}", .{ iter.next_valid() });

    iter = try .init("bytes= 1-5, 10-20, 25-30, 100-500, 7-8, 6-6, 9-9, 50-100");
    const coalesced = try iter.coalesce(std.testing.allocator, 1000, 0);
    defer std.testing.allocator.free(coalesced);
    try std.testing.expectEqualSlices(http.Range.Satisfied, &.{
        .{ .offset = 1, .len = 20 },
        .{ .offset = 25, .len = 6 },
        .{ .offset = 50, .len = 451 },
    }, coalesced);

    const coalesced2 = try iter.coalesce(std.testing.allocator, 1000, 5);
    defer std.testing.allocator.free(coalesced2);
    try std.testing.expectEqualSlices(http.Range.Satisfied, &.{
        .{ .offset = 1, .len = 30 },
        .{ .offset = 50, .len = 451 },
    }, coalesced2);

    const coalesced3 = try iter.coalesce(std.testing.allocator, 1000, 50);
    defer std.testing.allocator.free(coalesced3);
    try std.testing.expectEqualSlices(http.Range.Satisfied, &.{
        .{ .offset = 1, .len = 500 },
    }, coalesced3);
}

test "Range.Writer single range" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var buf: [10]u8 = undefined;
    var rw: http.Range.Writer = .init(&out.writer, 10000, &.{
        .{ .offset = 5, .len = 5 },
    }, "asdfasdfasdf", "text/plain", &buf);
    
    var data: [10][]const u8 = .{
        "012",
        "3456789abcdef",
        "|123",
        "456",
        "7",
        "89abc",
        "def|123456789abcdef",
        "|123456789abcdef",
        "|123456789abcdef",
        "|123456789abcdef",
    };
    try rw.interface.writeVecAll(&data);

    try rw.finish();

    try std.testing.expectEqualStrings("56789", out.written());
}

test "Range.Writer multiple ranges" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var buf: [10]u8 = undefined;
    var rw: http.Range.Writer = .init(&out.writer, 10000, &.{
        .{ .offset = 5, .len = 5 },
        .{ .offset = 10, .len = 20 },
        .{ .offset = 40, .len = 50 },
    }, "asdfasdfasdf", "text/plain", &buf);
    
    var data: [10][]const u8 = .{
        "012",
        "3456789abcdef",
        "|123",
        "456",
        "7",
        "89abc",
        "def|123456789abcdef",
        "|123456789abcdef",
        "|123456789abcdef",
        "|123456789abcdef",
    };
    try rw.interface.writeVecAll(&data);

    try rw.finish();

    try std.testing.expectEqualStrings(lf_to_crlf(
        \\
        \\--asdfasdfasdf
        \\content-type: text/plain
        \\content-range: bytes 5-9/10000
        \\
        \\56789
        \\--asdfasdfasdf
        \\content-type: text/plain
        \\content-range: bytes 10-29/10000
        \\
        \\abcdef|123456789abcd
        \\--asdfasdfasdf
        \\content-type: text/plain
        \\content-range: bytes 40-89/10000
        \\
        \\89abcdef|123456789abcdef|123456789abcdef|123456789
        \\--asdfasdfasdf--
        \\
    ), out.written());
}

test "Range.Writer no content type" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var buf: [10]u8 = undefined;
    var rw: http.Range.Writer = .init(&out.writer, 10000, &.{
        .{ .offset = 5, .len = 5 },
        .{ .offset = 10, .len = 20 },
        .{ .offset = 40, .len = 50 },
    }, "asdfasdfasdf", "", &buf);
    
    var data: [8][]const u8 = .{
        "012",
        "3456789abcdef",
        "|123",
        "456",
        "7",
        "89abc",
        "def|123456789abcdef",
        "|123456789abcdef",
    };
    try rw.interface.writeSplatAll(&data, 5);

    try rw.finish();

    try std.testing.expectEqualStrings(lf_to_crlf(
        \\
        \\--asdfasdfasdf
        \\content-range: bytes 5-9/10000
        \\
        \\56789
        \\--asdfasdfasdf
        \\content-range: bytes 10-29/10000
        \\
        \\abcdef|123456789abcd
        \\--asdfasdfasdf
        \\content-range: bytes 40-89/10000
        \\
        \\89abcdef|123456789abcdef|123456789abcdef|123456789
        \\--asdfasdfasdf--
        \\
    ), out.written());
}

fn lf_to_crlf(comptime str: []const u8) []const u8 {
    comptime var out_buf: [str.len * 2]u8 = undefined;
    comptime var len: usize = 0;
    comptime {
        for (str) |ch| {
            if (ch == '\n') {
                out_buf[len] = '\r';
                out_buf[len + 1] = '\n';
                len += 2;
            } else {
                out_buf[len] = ch;
                len += 1;
            }
        }
    }
    const out: [len]u8 = out_buf[0..len].*;
    return &out;
}

const http = @import("http");
const std = @import("std");
