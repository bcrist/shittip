pub const Alloc_Handler = *const fn(allocator: std.mem.Allocator, req: *Request) anyerror!void;

pub fn router(svr: anytype, comptime prefix: []const u8, comptime routes: anytype) !void {
    comptime var prefix_routes_list: []const []const u8 = &.{};
    comptime var exact_routes_list: []const struct { []const u8 } = &.{};

    const prefix_without_placeholder = if (comptime std.mem.endsWith(u8, prefix, "**")) prefix[0 .. prefix.len - 2] else prefix;

    inline for (routes) |route| {
        const path = route[0];
        if (route.len > 1) {
            inline for (1..route.len) |i| {
                if (maybe_string(&route[1])) |flow_name| {
                    try svr.register(prefix_without_placeholder ++ path, struct {
                        pub fn route_flow(req: *Request) !void {
                            _ = try req.chain(flow_name);
                        }
                    }.route_flow);
                } else {
                    try svr.register(prefix_without_placeholder ++ path, route[i]);
                }
            }
        }
        if (comptime std.mem.endsWith(u8, path, "**")) {
            prefix_routes_list = prefix_routes_list ++ .{ path };
        } else {
            exact_routes_list = exact_routes_list ++ .{ .{ path } };
        }
    }

    const final_prefix_routes_list = prefix_routes_list[0..].*;

    try svr.register(prefix, struct {

        const exact_routes: std.StaticStringMap(void) = .initComptime(exact_routes_list);
        
        pub fn route(allocator: std.mem.Allocator, req: *Request) anyerror!void {
            var path = req.target.path_remaining;

            if (exact_routes.has(path)) {
                _ = try req.chain(try flow_name(allocator, path));
                req.target.path_remaining = "";
                log.debug("{f}: remaining path is now: {s}", .{ req.cid, req.target.path_remaining });
                return;
            }

            for (final_prefix_routes_list) |prefix_path| {
                const prefix_path_without_suffix = prefix_path[0 .. prefix_path.len - 2];
                if (std.mem.startsWith(u8, path, prefix_path_without_suffix)) {
                    _ = try req.chain(try flow_name(allocator, prefix_path));
                    req.target.path_remaining = path[prefix_path_without_suffix.len..];
                    log.debug("{f}: remaining path is now: {s}", .{ req.cid, req.target.path_remaining });
                    return;
                }
            }

            path = try strip_path_params(allocator, path);

            if (exact_routes.has(path)) {
                _ = try req.chain(try flow_name(allocator, path));
                req.target.path_remaining = "";
                log.debug("{f}: remaining path is now: {s}", .{ req.cid, req.target.path_remaining });
                return;
            }

            for (final_prefix_routes_list) |prefix_path| {
                const prefix_path_without_suffix = prefix_path[0 .. prefix_path.len - 2];
                if (std.mem.startsWith(u8, path, prefix_path_without_suffix)) {
                    _ = try req.chain(try flow_name(allocator, prefix_path));
                    req.target.path_remaining = compute_new_unparsed_path(req, prefix_path_without_suffix);
                    log.debug("{f}: remaining path is now: {s}", .{ req.cid, req.target.path_remaining });
                    return;
                }
            }
        }

        fn flow_name(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
            if (prefix_without_placeholder.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_without_placeholder, path });
            } else {
                return path;
            }
        }

        fn strip_path_params(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
            const extra_bytes = std.mem.count(u8, target, ":");

            var list = try std.ArrayList(u8).initCapacity(allocator, target.len + extra_bytes);
            var iter = std.mem.splitScalar(u8, target, '/');
            var first = true;
            while (iter.next()) |part| {
                if (first) first = false else list.appendAssumeCapacity('/');

                if (std.mem.indexOfScalar(u8, part, ':')) |end| {
                    try percent_encoding.decode_append(allocator, &list, part[0 .. end + 1], .default);
                    list.appendAssumeCapacity('*');
                    continue;
                }

                // if the whole path part can be parsed as an integer, replace it with *, otherwise keep it as-is.
                const saved_len = list.items.len;
                try percent_encoding.decode_append(allocator, &list, part, .default);
                _ = std.fmt.parseInt(u128, list.items[saved_len..], 10) catch continue;
                list.items.len = saved_len;
                list.appendAssumeCapacity('*');
            }
            return std.mem.trimEnd(u8, list.items, "/");
        }

        fn compute_new_unparsed_path(req: *Request, prefix_path_without_suffix: []const u8) []const u8 {
            var unparsed_iterator = req.path_remaining_iterator();
            var prefix_iterator = std.mem.splitScalar(u8, prefix_path_without_suffix, '/');

            var chars_to_keep: usize = 0;
            var count_slash = false;
            while (unparsed_iterator.next()) |segment| {
                if (chars_to_keep == 0) {
                    if (prefix_iterator.next()) |prefix_segment| {
                        if (std.mem.endsWith(u8, prefix_segment, "*")) continue;

                        if (prefix_segment.len < segment.len) {
                            chars_to_keep += segment.len - prefix_segment.len;
                            count_slash = true;
                        }

                        continue;
                    }
                }

                if (count_slash) {
                    chars_to_keep += 1;
                } else {
                    count_slash = true;
                }
                chars_to_keep += segment.len;
            }

            const path = req.target.path_remaining;
            return path[path.len - chars_to_keep .. path.len];
        }

    }.route);
}

pub fn resource(comptime source_path: []const u8) struct { []const u8, Alloc_Handler } {
    @setEvalBranchQuota(5000); // for content_type.lookup
    const extension = std.Io.Dir.path.extension(source_path);
    const ct = Content_Type.ext_lookup.get(extension);
    return resource_with_content_type(source_path, ct);
}

pub fn resource_with_content_type(comptime source_path: []const u8, comptime ct: ?Content_Type) struct { []const u8, Alloc_Handler } {
    return .{
        resource_path(source_path),
        static_internal(.{
            .content = resource_compressed_content(source_path),
            .content_encoding = .deflate,
            .content_type = ct,
            .cache_control = "max-age=31536000, immutable, public",
            .etag = resource_etag(source_path),
            .last_modified_utc = root.resources.build_time,
        }),
    };
}

pub fn resource_path(comptime source_path: []const u8) []const u8 {
    const extension = std.Io.Dir.path.extension(source_path);
    return comptime "/" ++ @field(root.resources, source_path) ++ extension;
}

pub fn resource_compressed_content(comptime source_path: []const u8) []const u8 {
    return @field(root.resources.content, source_path);
}

pub fn resource_etag(comptime source_path: []const u8) []const u8 {
    return @field(root.resources, source_path);
}

const Static_Internal_Route_Options = struct {
    content: []const u8,
    content_encoding: std.http.ContentEncoding = .identity,
    content_disposition: ?Content_Disposition = null,
    content_type: ?Content_Type = null,
    cache_control: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?tempora.Date_Time = null,
    method: std.http.Method = .GET,
};
pub fn static_internal(comptime options: Static_Internal_Route_Options) Alloc_Handler {
    return struct {
        pub fn handler(arena: std.mem.Allocator, req: *Request) anyerror!void {
            switch (req.req.head.method) {
                .HEAD, options.method => {},
                else => return error.MethodNotAllowed,
            }

            const DTO = tempora.Date_Time.With_Offset;

            if (options.content_type) |ct| {
                _ = try req.maybe_add_response_header("content-type", ct.to_string());
            }
            if (options.content_disposition) |cd| {
                _ = try req.maybe_add_response_header("content-disposition", cd.to_string());
            }
            if (options.cache_control) |cc| {
                _ = try req.maybe_add_response_header("cache-control", cc);
            }
            if (options.etag) |etag| {
                _ = try req.maybe_add_response_header("etag", "\"" ++ etag ++ "\"");
            }
            if (options.last_modified_utc) |dt| {
                _ = try req.maybe_add_response_header("last-modified", comptime std.fmt.comptimePrint("{f}", .{ dt.with_offset(0).fmt(DTO.http) }));
            }

            var not_modified_by_date: ?bool = null;
            var not_modified_by_etag: ?bool = null;

            var iter = req.header_iterator();
            while (iter.next()) |header| {
                if (options.last_modified_utc) |last_modified| {
                    if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
                        const last_seen = DTO.from_string(DTO.http, header.value) catch continue;
                        not_modified_by_date = !last_seen.dt.is_before(last_modified);
                    }
                }
                if (options.etag) |etag| {
                    if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
                        var inm_iter: ETag_Iterator = .{ .remaining = header.value };
                        not_modified_by_etag = while (try inm_iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.value, etag)) {
                                break true;
                            }
                        } else false;
                    }
                }
            }

            const allow_cache = if (req.get_response_header("cache-control")) |header| !std.mem.eql(u8, header, "no-cache") else true;

            if (allow_cache and (not_modified_by_etag orelse not_modified_by_date orelse false)) {
                req.response.status = .not_modified;
                try req.respond("");
            } else if (req.check_accept_encoding(options.content_encoding)) {
                try req.set_response_header("content-encoding", @tagName(options.content_encoding));
                try req.respond(options.content);
            } else {
                var compressed_reader = std.Io.Reader.fixed(options.content);
                var decompress: std.http.Decompress = undefined;
                const reader = switch (options.content_encoding) {
                    .deflate => r: {
                        const decompress_buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
                        decompress = .{ .flate = .init(&compressed_reader, .zlib, decompress_buffer) };
                        break :r &decompress.flate.reader;
                    },
                    .gzip => r: {
                        const decompress_buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
                        decompress = .{ .flate = .init(&compressed_reader, .gzip, decompress_buffer) };
                        break :r &decompress.flate.reader;
                    },
                    .zstd => r: {
                        const decompress_buffer = try arena.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
                        decompress = .{ .zstd = .init(&compressed_reader, decompress_buffer, .{ .verify_checksum = false }) };
                        break :r &decompress.zstd.reader;
                    },
                    else => return error.NotAcceptable,
                };

                _ = try reader.streamRemaining(try req.response_writer());
            }
        }
    }.handler;
}

pub fn module(comptime Injector: type, comptime Module: type) *const fn(*Request, Injector.Input) anyerror!void {
    return struct {
        pub fn handler(req: *Request, in: Injector.Input) anyerror!void {
            switch (req.req.head.method) {
                .HEAD => if (@hasDecl(Module, "head")) {
                    return try Injector.call(Module.head, in);
                } else if (@hasDecl(Module, "get")) {
                    return try Injector.call(Module.get, in);
                },
                .GET => if (@hasDecl(Module, "get")) return try Injector.call(Module.get, in),
                .POST => if (@hasDecl(Module, "post")) return try Injector.call(Module.post, in),
                .PUT => if (@hasDecl(Module, "put")) return try Injector.call(Module.put, in),
                .DELETE => if (@hasDecl(Module, "delete")) return try Injector.call(Module.delete, in),
                .CONNECT => if (@hasDecl(Module, "connect")) return try Injector.call(Module.connect, in),
                .OPTIONS => if (@hasDecl(Module, "options")) return try Injector.call(Module.options, in),
                .TRACE => if (@hasDecl(Module, "trace")) return try Injector.call(Module.trace, in),
                .PATCH => if (@hasDecl(Module, "patch")) return try Injector.call(Module.patch, in),
            }

            return error.MethodNotAllowed;
        }
    }.handler;
}

pub fn method(comptime required_method: std.http.Method) *const fn(*Request) anyerror!void {
    return struct {
        pub fn handler(req: *Request) !void {
            if (req.req.head.method != required_method) {
                return error.MethodNotAllowed;
            }
        }
    }.handler;
}

pub fn shutdown(req: *Request, loop: *Loop) !void {
    defer loop.stop();
    try req.set_response_header("cache-control", "no-cache");
    req.response.keep_alive = false;
    try req.respond("");
}

pub fn replace_arena(req: *Request) !void {
    try req.replace_arena();
}

inline fn maybe_string(ptr: anytype) ?[]const u8 {
    switch (@typeInfo(@TypeOf(ptr.*))) {
        .pointer => |info| {
            if (info.child == u8 and info.size == .slice) {
                return ptr.*;
            }
            if (info.size == .one) {
                switch (@typeInfo(info.child)) {
                    .array => |array_info| {
                        if (array_info.child == u8) {
                            return ptr.*;
                        }
                    },
                    else => {},
                }
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                return ptr;
            }
        },
        else => {},
    }
    return null;
}

const log = std.log.scoped(.http);

const Content_Type = @import("content_type.zig").Content_Type;
const Content_Disposition = @import("content_disposition.zig").Content_Disposition;
const ETag_Iterator = @import("ETag_Iterator.zig");
const Request = @import("Request.zig");
const Loop = @import("Loop.zig");
const server = @import("server.zig");
const Temp_Allocator = @import("Temp_Allocator");
const percent_encoding = @import("percent_encoding");
const tempora = @import("tempora");
const std = @import("std");
const root = @import("root");
