//! `Static_Updatable` is used for a similar use case as `routing.static`, but while the latter
//! requires that the content be comptime-known, this does not, and in fact the content can be
//! updated while the server is running without needing to re-render the content for every request.
//!
//! The resulting endpoint will automatically support:
//!    * `content-encoding: deflate`
//!    * `range: bytes` requests
//!    * status code 304 Not Modified via etag and last modified
//! 
//! Example usage:
//!
//!    var index: http.Static_Updatable = try .init(gpa, io, "index.zk", .{
//!        .some_value_1 = whatever1,
//!        .some_value_2 = whatever2,
//!    }, .{}, .html_utf8);
//!    defer index.deinit();
//!    try server.register_module("index", &index);
//!
//!    try server.router("", .{
//!        .{ "/index", "index" },
//!        // ...
//!    });
//! 
//!    // some time later:
//!    try index.update(io, "index.zk", .{
//!        .some_value_1 = new_whatever1,
//!        .some_value_2 = new_whatever2,
//!    }, .{} .{});
//!
//! Note the indirection through a separate flow name is required due to server.router() taking
//! its list of routes as a comptime parameter.

gpa: std.mem.Allocator,
lock: std.Io.RwLock,
content_type: []const u8,
cache_control: []const u8,
uncompressed_length: usize,
compressed_data: []const u8,
etag: []const u8,
last_modified: tempora.Date_Time,

pub fn init(gpa: std.mem.Allocator, io: std.Io, comptime template_path: []const u8, render_data: anytype, comptime render_options: zkittle.Render_Options, comptime content_type: Content_Type) !Static_Updatable {
    var self: Static_Updatable = .{
        .gpa = gpa,
        .lock = .init,
        .content_type = "",
        .cache_control = "",
        .uncompressed_length = 0,
        .compressed_data = "",
        .etag = "",
        .last_modified = .epoch,
    };
    try self.update(io, template_path, render_data, render_options, .{
        .content_type = content_type.to_string(),
    });
    return self;
}

const Update_Options = struct {
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    lock_timeout: std.Io.Timeout = .none,
};
pub fn update(self: *Static_Updatable, io: std.Io, comptime template_path: []const u8, render_data: anytype, comptime render_options: zkittle.Render_Options, options: Update_Options) !void {
    log.debug("Starting Static_Updatable.update() for template {f}", .{
        std.zig.fmtString(template_path),
    });

    var w: std.Io.Writer.Allocating = .init(self.gpa);
    defer w.deinit();

    try w.ensureUnusedCapacity(1024);
    var deflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&w.writer, &deflate_buf, .zlib, .best);
    var hasher: std.Io.Writer.Hashed(std.crypto.hash.sha2.Sha256) = .initHasher(&compress.writer, .init(.{}), &.{});

    try @field(@import("root").resources.templates, template_path).render(&hasher.writer, render_data, render_options);

    try compress.finish();

    const hash = hasher.hasher.finalResult();
    const etag = try std.fmt.allocPrint(self.gpa, "{x}", .{ hash });
    errdefer self.gpa.free(etag);

    try self.lock.lock(io);
    defer self.lock.unlock(io);

    if (options.content_type) |ct| {
        self.content_type = ct;
    }

    if (options.cache_control) |cc| {
        self.cache_control = cc;
    }

    self.uncompressed_length = hasher.hasher.total_len;
    self.compressed_data = try w.toOwnedSlice();
    self.etag = etag;
    self.last_modified = tempora.now_utc(io).dt;

    log.debug("Completed Static_Updatable.update() for template {f}", .{
        std.zig.fmtString(template_path),
    });
}

pub fn deinit(self: *Static_Updatable) void {
    self.gpa.free(self.compressed_data);
    self.gpa.free(self.etag);
}

pub fn get(self: *Static_Updatable, request: *Request) !void {
    try self.lock.lockShared(request.io);
    defer self.lock.unlockShared(request.io);

    if (self.content_type.len > 0) {
        try request.set_response_header("content-type", self.content_type);
    }

    try request.maybe_add_common_response_headers(.{
        .etag = self.etag,
        .last_modified_utc = self.last_modified,
        .cache_control = if (self.cache_control.len == 0) null else self.cache_control,
    });

    try request.check_not_modified(self.last_modified, self.etag);

    if (request.check_accept_encoding(.deflate)) {
        try request.set_response_header("content-encoding", "deflate");
        try request.respond_ranged(self.compressed_data, .{});
    } else {
        var compressed_reader = std.Io.Reader.fixed(self.compressed_data);
        var decompress: std.http.Decompress = undefined;
        const decompress_buffer = try request.arena().alloc(u8, std.compress.flate.max_window_len);
        decompress = .{ .flate = .init(&compressed_reader, .zlib, decompress_buffer) };
        _ = try decompress.flate.reader.streamRemaining(try request.response_writer_ranged(self.uncompressed_length, .{}));
    }
}

const Static_Updatable = @This();

const log = std.log.scoped(.http);

const Request = @import("Request.zig");
const Content_Type = @import("content_type.zig").Content_Type;
const tempora = @import("tempora");
const zkittle = @import("zkittle");
const std = @import("std");
