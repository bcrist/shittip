io: std.Io,
arena: std.mem.Allocator, // recommend replacing with a Temp_Allocator for requests that hit a valid endpoint
cid: Connection_Id,
req: std.http.Server.Request,
received_dt: tempora.Date_Time,
content_type: ?Content_Type,

target: struct {
    full: []const u8,
    path: []const u8,
    path_remaining: []const u8, // hierarchical handlers can trim components off this and chain into other handlers
    query: []const u8,
    fragment: []const u8,

    pub fn parse(target: []const u8) @This() {
        const path = if (std.mem.indexOfAny(u8, target, "?#")) |end| target[0..end] else target;
        const remaining_target = target[path.len..];
        const query = if (std.mem.indexOfScalar(u8, remaining_target, '#')) |end| remaining_target[0..end] else remaining_target;
        const fragment = remaining_target[query.len..];

        return .{
            .full = target,
            .path = path,
            .path_remaining = path,
            .query = query,
            .fragment = fragment,
        };
    }
},

handlers: std.Deque(server.Handler_Func),

response: struct {
    headers: std.ArrayList(std.http.Header),
    version: std.http.Version,
    status: std.http.Status,
    reason: ?[]const u8,
    keep_alive: bool,
    transfer_encoding: ?std.http.TransferEncoding,
    content_length: ?u64,
    buffer_bytes: usize,
    state: union (enum) {
        not_started,
        streaming: std.http.BodyWriter,
        sent,
    },

    pub fn options(self: *const @This()) std.http.Server.Request.RespondOptions {
        return .{
            .version = self.version,
            .status = self.status,
            .reason = self.reason,
            .keep_alive = self.keep_alive,
            .extra_headers = self.headers.items,
            .transfer_encoding = self.transfer_encoding,
        };
    }
},

// Internal use; recommend not touching these:
internal: struct {
    loop: *Loop,
    registry: *const std.StringHashMapUnmanaged(std.ArrayList(server.Handler_Func)),
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
    scratch_alloc: std.mem.Allocator,
},

const Request = @This();

pub fn handle(self: *Request, ctx: *anyopaque, root_flow: []const u8) !void {
    _ = try self.chain(root_flow);

    while (self.handlers.popFront()) |handler| {
        try handler(self, ctx);
    }

    try self.end_response();
}

pub fn chain(self: *Request, flow: []const u8) std.mem.Allocator.Error!bool {
    if (self.internal.registry.get(flow)) |handlers| {
        log.debug("{f}: Chaining {d} handler(s) for flow '{f}'", .{
            self.cid,
            handlers.items.len,
            std.zig.fmtString(flow),
        });
        try self.handlers.pushBackSlice(self.internal.scratch_alloc, handlers.items);
        return true;
    } else {
        log.debug("{f}: No handler(s) for flow '{f}'", .{
            self.cid,
            std.zig.fmtString(flow),
        });
    }
    return false;
}

pub fn replace_arena(self: *Request) error{InsufficientResources}!void {
    if (self.internal.ta_pool.index == null) {
        const index = try self.internal.ta_pool.pool.acquire(self.cid.connection_num);
        self.internal.ta_pool.index = index;
        self.arena = self.internal.ta_pool.allocators[index].allocator();
    }
}

fn try_set_date(self: *Request) !void {
    if (self.response.state == .not_started) {
        try self.maybe_add_response_header("date", try self.fmt_http_date(self.received_dt));
    }
}

pub fn header_iterator(self: *Request) std.http.HeaderIterator {
    return std.http.HeaderIterator.init(self.internal.head_buffer);
}

pub fn get_header(self: *Request, name: []const u8) ?std.http.Header {
    var iter = self.header_iterator();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(name, header.name)) {
            return header;
        }
    }
    return null;
}

pub fn check_accept_encoding(self: *Request, desired_encoding: std.http.ContentEncoding) bool {
    if (desired_encoding == .identity) return true;
    if (self.get_header("accept-encoding")) |header| {
        const name = @tagName(desired_encoding);
        var iter = std.mem.tokenizeAny(u8, header.value, ", ");
        while (iter.next()) |item| {
            if (std.ascii.eqlIgnoreCase(item, name)) return true;
        }
    }
    return false;
}

pub fn path_iterator(self: *Request) std.mem.SplitIterator(u8, .scalar) {
    var full_path = self.target.path;
    if (std.mem.startsWith(u8, full_path, "/")) {
        full_path = full_path[1..];
    }
    return std.mem.splitScalar(u8, full_path, '/');
}

pub fn path_remaining_iterator(self: *Request) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, self.target.path_remaining, '/');
}

pub fn get_path_param(self: *Request, name: []const u8) !?[]const u8 {
    var temp: std.ArrayList(u8) = .empty;
    var iter = self.path_iterator();
    while (iter.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, ':')) |end| {
            temp.clearRetainingCapacity();
            const prefix = try percent_encoding.decode_maybe_append(self.internal.scratch_alloc, &temp, part[0 .. end], .{});
            if (std.mem.eql(u8, name, prefix)) {
                temp.clearRetainingCapacity();
                return try percent_encoding.decode_maybe_append(self.internal.scratch_alloc, &temp, part[end + 1 ..], .{});
            }
        }
    }
    return null;
}

pub fn query_iterator(self: *Request) Query_Iterator {
    return Query_Iterator.init(self.internal.scratch_alloc, self.target.query);
}

pub fn get_query_param(self: *Request, name: []const u8) !?[]const u8 {
    var iter = self.query_iterator();
    while (try iter.next()) |param| {
        if (std.mem.eql(u8, param.name, name)) {
            return param.value;
        }
    }
    return null;
}

pub fn has_query_param(self: *Request, name: []const u8) !bool {
    var iter = self.query_iterator();
    defer iter.deinit();
    while (try iter.next()) |param| {
        if (std.mem.eql(u8, param.name, name)) {
            return true;
        }
    }
    return false;
}

pub fn body_reader(self: *Request) !*std.Io.Reader {
    if (self.internal.body) |reader| return reader;

    const has_body = self.req.head.method.requestHasBody() and if (self.req.head.content_length) |length| length > 0 else true;
    if (has_body) {
        const flush = self.req.head.expect != null;
        try self.req.writeExpectContinue();
        if (flush) try self.req.server.out.flush();

        try self.clone_header_strings();

        switch (self.req.head.transfer_compression) {
            .compress => return error.UnsupportedMediaType,
            .zstd => {
                const transfer_buffer = try self.arena.alloc(u8, 4096);
                const decompress_buffer = try self.arena.alloc(u8, std.compress.zstd.block_size_max + std.compress.zstd.default_window_len);
                self.internal.body = self.req.server.reader.bodyReaderDecompressing(
                    transfer_buffer,
                    self.req.head.transfer_encoding,
                    self.req.head.content_length,
                    self.req.head.transfer_compression,
                    &self.internal.decompress,
                    decompress_buffer,
                );
            },
            .gzip, .deflate => {
                const transfer_buffer = try self.arena.alloc(u8, 4096);
                const decompress_buffer = try self.arena.alloc(u8, std.compress.flate.max_window_len);
                self.internal.body = self.req.server.reader.bodyReaderDecompressing(
                    transfer_buffer,
                    self.req.head.transfer_encoding,
                    self.req.head.content_length,
                    self.req.head.transfer_compression,
                    &self.internal.decompress,
                    decompress_buffer,
                );
            },
            .identity => {
                const transfer_buffer = try self.arena.alloc(u8, 4096);
                self.internal.body = self.req.server.reader.bodyReader(
                    transfer_buffer,
                    self.req.head.transfer_encoding,
                    self.req.head.content_length
                );
            },
        }
    } else {
        self.req.server.reader.interface = std.Io.Reader.fixed("");
        self.req.server.reader.state = .body_none;
        self.internal.body = &self.req.server.reader.interface;
    }

    return self.internal.body.?;
}

pub fn clone_header_strings(self: *Request) !void {
    if (self.internal.header_strings_cloned) return;

    self.internal.head_buffer = try self.arena.dupe(u8, self.internal.head_buffer);
    self.req.head_buffer = self.internal.head_buffer;

    const path_remaining = try self.arena.dupe(u8, self.target.path_remaining);
    self.target = .parse(try self.arena.dupe(u8, self.target.full));
    self.target.path_remaining = path_remaining;

    self.req.head.target = self.target.full;

    if (self.get_header("content-type")) |ct| {
        self.req.head.content_type = ct.value;
        self.content_type = .parse(ct.value);
    }

    self.internal.header_strings_cloned = true;
}

fn restore_std_req_strings(self: *Request) void {
    // undo the damage from std.http.Server.Request.Head.invalidateStrings()
    std.debug.assert(self.internal.header_strings_cloned);
    self.req.head_buffer = self.internal.head_buffer;
    self.req.head.target = self.target.full;
    if (self.get_header("content-type")) |ct| {
        self.req.head.content_type = ct.value;
    }
}

pub fn form_iterator(self: *Request) !Query_Reader {
    return try Query_Reader.init(self.internal.scratch_alloc, try self.body_reader());
}

pub fn ensure_response_not_started(self: *Request) !void {
    if (self.response.state != .not_started) return error.ResponseAlreadyStarted;
}

pub fn add_response_header(self: *Request, name: []const u8, value: []const u8) !void {
    try self.ensure_response_not_started();
    try self.response.headers.append(self.internal.scratch_alloc, .{
        .name = name,
        .value = value,
    });
}

pub fn maybe_add_response_header(self: *Request, name: []const u8, value: []const u8) !bool {
    try self.ensure_response_not_started();

    for (self.response.headers.items) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return false;
        }
    }
    
    try self.response.headers.append(self.internal.scratch_alloc, .{
        .name = name,
        .value = value,
    });
    return true;
}

pub fn set_response_header(self: *Request, name: []const u8, value: []const u8) !void {
    try self.ensure_response_not_started();

    for (self.response.headers.items) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            header.value = value;
            return;
        }
    }

    try self.response.headers.append(self.internal.scratch_alloc, .{
        .name = name,
        .value = value,
    });
}

pub fn get_response_header(self: *Request, name: []const u8) ?[]const u8 {
    for (self.response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return null;
}

pub fn check_and_add_last_modified(self: *Request, last_modified_utc: tempora.Date_Time) !void {
    try self.add_response_header("last-modified", try self.fmt_http_date(last_modified_utc));
    if (self.get_header("if-modified-since")) |header| {
        const DTO = tempora.Date_Time.With_Offset;
        if (DTO.from_string(DTO.http, header.value)) |last_seen| {
            std.debug.assert(last_seen.utc_offset_ms == 0);
            if (!last_seen.dt.is_before(last_modified_utc)) {
                self.response_status = .not_modified;
                try self.respond("");
                return error.Done;
            }
        } else |_| {
            log.debug("Could not parse if-modified-since date: {s}", .{ header.value });
        }
    }
}

pub fn hx_current_url(self: *Request) ?[]const u8 {
    return if (self.get_header("hx-current-url")) |param| param.value else null;
}

pub fn hx_current_query(self: *Request) []const u8 {
    if (self.hx_current_url()) |url| {
        if (std.mem.indexOfScalar(u8, url, '?')) |query_start| {
            return url[query_start..];
        }
    }
    return "";
}

fn maybe_clone_strings_before_response(self: *Request) !bool {
    if (!self.response.keep_alive or !self.req.head.keep_alive or !self.req.head.method.requestHasBody()) return false;
    const transfer_encoding_none = (self.response.transfer_encoding orelse .chunked) == .none;
    if (transfer_encoding_none) return false; // we're not sending a content-length or content-encoding header, so the connection won't be reusable.

    try self.clone_header_strings();
    return true;
}

pub fn response_writer(self: *Request) !*std.Io.Writer {
    switch (self.response.state) {
        .not_started => {
            log.info("{f}: [{d}] {t} {s}", .{
                self.cid,
                @intFromEnum(self.response.status),
                self.req.head.method,
                self.req.head.target,
            });

            const buf = try self.arena.alloc(u8, self.response.buffer_bytes);

            const should_clone_strings = try self.maybe_clone_strings_before_response();
            self.response.state = .{
                .streaming = try self.req.respondStreaming(buf, .{
                    .content_length = self.response.content_length,
                    .respond_options = self.response.options(),
                }),
            };
            if (should_clone_strings) self.restore_std_req_strings();

            return &self.response.state.streaming.writer;
        },
        .streaming => |*writer| return &writer.writer,
        .sent => return error.ResponseAlreadySent,
    }
}

pub fn end_response(self: *Request) !void {
    switch (self.response.state) {
        .not_started => return error.NotFound,
        .streaming => |*bw| {
            try bw.end();
            self.response.state = .sent;
        },
        .sent => {},
    }
}

pub fn respond(self: *Request, content: []const u8) !void {
    try self.ensure_response_not_started();
    self.response.state = .sent;

    log.info("{f}: [{d}] {t} {s}", .{
        self.cid,
        @intFromEnum(self.response.status),
        self.req.head.method,
        self.req.head.target,
    });

    self.response.content_length = content.len;

    const should_clone_strings = try self.maybe_clone_strings_before_response();
    try self.req.respond(content, self.response.options());
    if (should_clone_strings) self.restore_std_req_strings();
}

const Respond_Err_Options = struct {
    empty_content: bool = false,
    status: std.http.Status = .internal_server_error,
    err: ?anyerror = null,
    trace: ?*std.builtin.StackTrace = null,
};
pub fn respond_err(self: *Request, options: Respond_Err_Options) !void {
    if (self.response.state != .not_started) {
        if (options.err) |err| {
            log.err("{f}: [{} {} after response started] {t} {s}", .{
                self.cid,
                @intFromEnum(options.status),
                err,
                self.req.head.method,
                self.req.head.target,
            });
        } else {
            log.err("{f}: [{} after response started] {t} {s}", .{
                self.cid,
                @intFromEnum(options.status),
                self.req.head.method,
                self.req.head.target,
            });
        }
        if (options.trace) |ert| {
            std.debug.dumpStackTrace(ert);
        }
        return error.Done;
    }

    if (options.err) |e| {
        log.warn("{f}: [{} {}] {t} {s}", .{
            self.cid,
            @intFromEnum(options.status),
            e,
            self.req.head.method,
            self.req.head.target,
        });
    } else {
        log.info("{f}: [{}] {t} {s}", .{
            self.cid,
            @intFromEnum(options.status),
            self.req.head.method,
            self.req.head.target,
        });
    }
    if (options.trace) |ert| {
        std.debug.dumpStackTrace(ert);
    }

    if (!options.empty_content) {
        try self.set_response_header("content-type", Content_Type.html_utf8.to_string());
    }

    const content = try self.format_err_response(options);

    self.response.status = options.status;
    self.response.content_length = content.len;
    self.response.state = .sent;

    const should_clone_strings = try self.maybe_clone_strings_before_response();
    try self.req.respond(content, self.response.options());
    if (should_clone_strings) self.restore_std_req_strings();
}

pub fn format_err_response(self: *Request, options: Respond_Err_Options) ![]const u8 {
    if (options.empty_content) return "";

    var content: std.Io.Writer.Allocating = .init(self.internal.scratch_alloc);
    const w = &content.writer;

    try w.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{} {s}</title></head>
        \\<body>
        \\<h1>{} {s}</h1>
        \\
        , .{
            @intFromEnum(options.status),
            options.status.phrase() orelse "",
            @intFromEnum(options.status),
            options.status.phrase() orelse "",
        });

    if (options.err) |err| {
        try w.print("<h3>{s}</h3>\n", .{ @errorName(err) });
    }

    if (options.trace) |ert| {
        const terminal: std.Io.Terminal = .{
            .writer = w,
            .mode = .no_color,
        };
        try w.writeAll("<pre>\n");
        try std.debug.writeStackTrace(ert, terminal);
        try w.writeAll("</pre>\n");
    }

    try w.writeAll(
        \\</body>
        \\</html>
        \\
        );

    return content.written();
}

pub fn maybe_respond_err(self: *Request, options: Respond_Err_Options) !void {
    if (self.response.state != .not_started) {
        if (options.err) |err| {
            log.err("{f}: [{} {} after response started; suppressed] {t} {s}", .{
                self.cid,
                @intFromEnum(options.status),
                err,
                self.req.head.method,
                self.req.head.target,
            });
        } else {
            log.err("{f}: [{} after response started; suppressed] {t} {s}", .{
                self.cid,
                @intFromEnum(options.status),
                self.req.head.method,
                self.req.head.target,
            });
        }
        if (options.trace) |ert| {
            std.debug.dumpStackTrace(ert);
        }
        return;
    }

    try self.respond_err(options);
}

pub fn redirect(self: *Request, path: []const u8, status: std.http.Status) !void {
    if (self.get_header("hx-request") != null) {
        self.response.status = .no_content;
        try self.add_response_header("HX-Location", path);
    } else {
        self.response.status = status;
        try self.add_response_header("Location", path);
    }
    try self.respond("");
}

pub fn render(self: *Request, comptime template_path: []const u8, data: anytype, options: zkittle.Render_Options) anyerror!void {
    if (self.response.state == .not_started) {
        if (comptime Content_Type.ext_lookup.get(std.fs.path.extension(template_path))) |ct| {
            _ = try self.maybe_add_response_header("content-type", ct.to_string());
        }
        _ = try self.maybe_add_response_header("cache-control", "no-cache");
    }
    const w = try self.response_writer();
    try @field(root.resources.templates, template_path).render(w, data, options);
}

pub fn fmt(self: *Request, comptime pattern: []const u8, args: anytype) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(self.internal.scratch_alloc, pattern, args);
}

pub fn fmt_http_date(self: *Request, dt: tempora.Date_Time) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(self.internal.scratch_alloc, "{f}", .{ dt.with_offset(0).fmt(tempora.Date_Time.With_Offset.http) });
}

const log = std.log.scoped(.http);

const Query_Iterator = @import("Query_Iterator.zig");
const Query_Reader = @import("Query_Reader.zig");
const Connection_Id = @import("Connection_Id.zig");
const Content_Type = @import("content_type.zig").Content_Type;
const Loop = @import("Loop.zig");
const Index_Pool = @import("Index_Pool.zig");
const routing = @import("routing.zig");
const server = @import("server.zig");
const Temp_Allocator = @import("Temp_Allocator");
const percent_encoding = @import("percent_encoding");
const zkittle = @import("zkittle");
const tempora = @import("tempora");
const std = @import("std");
const root = @import("root");
