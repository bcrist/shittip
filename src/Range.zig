first: ?usize,
last: ?usize,

pub fn parse(str: []const u8) error{BadRange}!Range {
    const trimmed = std.mem.trim(u8, str, &std.ascii.whitespace);
    const dash = std.mem.findScalar(u8, trimmed, '-') orelse return error.BadRange;
    const first_str = std.mem.trimEnd(u8, trimmed[0..dash], &std.ascii.whitespace);
    const last_str = std.mem.trimStart(u8, trimmed[dash + 1 ..], &std.ascii.whitespace);
    const result: Range = .{
        .first = if (first_str.len == 0) null else std.fmt.parseUnsigned(usize, first_str, 10) catch |err| switch (err) {
            error.Overflow => std.math.maxInt(usize),
            error.InvalidCharacter => return error.BadRange,
        },
        .last = if (last_str.len == 0) null else std.fmt.parseUnsigned(usize, last_str, 10) catch |err| switch (err) {
            error.Overflow => std.math.maxInt(usize),
            error.InvalidCharacter => return error.BadRange,
        },
    };
    if (result.first != null and result.last != null and result.first.? > result.last.?) return error.BadRange;
    return result;
}

pub fn format(self: Range, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.first) |first| {
        if (self.last) |last| {
            try writer.print("[{}...{}]", .{ first, last });
        } else {
            try writer.print("[{}...]", .{ first });
        }
    } else if (self.last) |last| {
        try writer.print("[...{}]", .{ last });
    } else {
        try writer.writeAll("[...]");
    }
}

pub const Satisfied = struct {
    offset: usize,
    len: usize,

    pub fn format(self: Satisfied, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("[{}..][0..{}]", .{ self.offset, self.len });
    }

    pub fn slice(self: Satisfied, content: []const u8) []const u8 {
        return content[self.offset..][0..self.len];
    }

    pub fn maybe_coalesce(self: Satisfied, other: Satisfied, min_gap: usize) ?Satisfied {
        if (self.offset > other.offset + other.len + min_gap) return null;
        if (other.offset > self.offset + self.len + min_gap) return null;
        const offset = @min(self.offset, other.offset);
        const end = @max(self.offset + self.len, other.offset + other.len);
        return .{
            .offset = offset,
            .len = end - offset,
        };
    }

    pub fn set_header(self: Satisfied, full_length: ?usize, request: *Request) !void {
        if (full_length) |full_len| {
            try request.set_response_header("content-range", try request.fmt("bytes {d}-{d}/{d}", .{
                self.offset,
                self.offset + self.len - 1,
                full_len,
            }));
        } else {
            try request.set_response_header("content-range", try request.fmt("bytes {d}-{d}/*", .{
                self.offset,
                self.offset + self.len - 1,
            }));
        }
    }

    pub fn write_header(self: Satisfied, full_length: ?usize, writer: *std.Io.Writer) !void {
        if (full_length) |full_len| {
            try writer.print("content-range: bytes {d}-{d}/{d}\r\n", .{
                self.offset,
                self.offset + self.len - 1,
                full_len,
            });
        } else {
            try writer.print("content-range: bytes {d}-{d}/*\r\n", .{
                self.offset,
                self.offset + self.len - 1,
            });
        }
    }

    pub fn write_body_part(self: Satisfied, full_length: ?usize, boundary: []const u8, content_type: []const u8, w: *std.Io.Writer) !void {
        var strings: [3][]const u8 = .{ "\r\n--", boundary, "\r\n" };
        try w.writeVecAll(&strings);
        if (content_type.len > 0) {
            strings = .{ "content-type: ", content_type, "\r\n" };
            try w.writeVecAll(&strings);
        }
        try self.write_header(full_length, w);
        try w.writeAll("\r\n");
    }

    pub fn less_than(_: void, a: Satisfied, b: Satisfied) bool {
        if (a.offset != b.offset) return a.offset < b.offset;
        return a.len < b.len;
    }
};
pub fn satisfy(self: Range, full_content_length: usize) error{RangeNotSatisfiable}!Satisfied {
    if (self.first) |first| {
        if (first >= full_content_length) return error.RangeNotSatisfiable;
        if (self.last) |last| {
            const end = @min(last + 1, full_content_length);
            return .{
                .offset = first,
                .len = end - first,
            };
        }
        return .{
            .offset = first,
            .len = full_content_length - first,
        };
    } else if (self.last) |last| {
        if (last == 0) return error.RangeNotSatisfiable;
        if (last >= full_content_length) {
            return .{
                .offset = 0,
                .len = full_content_length,
            };
        }
        return .{
            .offset = full_content_length - last,
            .len = last,
        };
    } else return error.RangeNotSatisfiable;
}

pub const Iterator = struct {
    unit: []const u8,
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn init(range_header: []const u8) error{BadRange}!Iterator {
        const equal_pos = std.mem.findScalar(u8, range_header, '=') orelse return error.BadRange;
        const unit = std.mem.trim(u8, range_header[0..equal_pos], &std.ascii.whitespace);
        return .{
            .unit = unit,
            .inner = std.mem.splitScalar(u8, range_header[equal_pos + 1 ..], ',')
        };
    }

    pub fn next(self: *Iterator) error{BadRange}!?Range {
        const raw = self.inner.next() orelse return null;
        return try .parse(raw);
    }

    pub fn next_valid(self: *Iterator) ?Range {
        while (true) return self.next() catch continue;
    }

    const Coalesce_Error = error {
        BadRange,
        OutOfMemory,
    };
    pub fn coalesce(self: Iterator, gpa: std.mem.Allocator, full_content_length: usize, min_gap: u32) Coalesce_Error![]Range.Satisfied {
        var out: std.ArrayList(Range.Satisfied) = .empty;
        defer out.deinit(gpa);

        var iter = self;
        while (try iter.next()) |r| {
            const satisfied = r.satisfy(full_content_length) catch continue;
            for (out.items) |*existing| {
                if (existing.maybe_coalesce(satisfied, min_gap)) |coalesced| {
                    existing.* = coalesced;
                    break;
                }
            } else {
                try out.append(gpa, satisfied);
            }
        }

        std.sort.pdq(Range.Satisfied, out.items, {}, Range.Satisfied.less_than);

        var i = out.items.len;
        while (i > 0) {
            i -= 1;
            const satisfied = out.items[i];
            for (out.items[0..i]) |*other| {
                if (other.maybe_coalesce(satisfied, min_gap)) |coalesced| {
                    other.* = coalesced;
                    _ = out.orderedRemove(i);
                    break;
                }
            }
        }

        return try out.toOwnedSlice(gpa);
    }
};

pub const Writer = struct {
    out: *std.Io.Writer,
    interface: std.Io.Writer,
    boundary: []const u8,
    content_type: []const u8,
    content_length: usize,
    ranges_remaining: []const Range.Satisfied,
    skip_remaining: usize,
    body_remaining: usize,
    end_of_prev_range: usize,

    pub fn init(out: *std.Io.Writer, content_length: usize, ranges: []const Range.Satisfied, boundary: []const u8, content_type: []const u8, buffer: []u8) Writer {
        return .{
            .out = out,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = drain,
                    .sendFile = sendFile,
                },
            },
            .boundary = if (ranges.len > 1) boundary else "",
            .content_type = content_type,
            .content_length = content_length,
            .ranges_remaining = ranges,
            .skip_remaining = 0,
            .body_remaining = 0,
            .end_of_prev_range = 0,
        };
    }

    pub fn finish(self: *Writer) std.Io.Writer.Error!void {
        try self.interface.flush();
        if (self.boundary.len > 0) {
            try write_terminal_boundary(self.boundary, self.out);
        }
    }

    fn setup(self: *Writer) std.Io.Writer.Error!void {
        if (self.skip_remaining == 0 and self.body_remaining == 0) {
            if (self.ranges_remaining.len > 0) {
                const range = self.ranges_remaining[0];
                self.skip_remaining = range.offset - self.end_of_prev_range;
                self.body_remaining = range.len;
                self.end_of_prev_range = range.offset + range.len;
                self.ranges_remaining = self.ranges_remaining[1..];

                if (self.boundary.len > 0) {
                    try range.write_body_part(self.content_length, self.boundary, self.content_type, self.out);
                }
            } else {
                self.skip_remaining = std.math.maxInt(usize);
                self.content_length = 0;
            }
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));

        try self.setup();

        var header: []const u8 = w.buffered();
        var data_mut = data;
        var splat_mut = splat;

        var processed_bytes: usize = 0;
        defer if (processed_bytes < w.end) {
            const remaining = w.buffer[processed_bytes..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
        } else {
            w.end = 0;
        };

        check_skip: while (self.skip_remaining > 0) {
            if (self.skip_remaining <= header.len) {
                processed_bytes += self.skip_remaining;
                header = header[self.skip_remaining..];
                self.skip_remaining = 0;
                break;
            }

            processed_bytes += header.len;
            self.skip_remaining -= header.len;
            header = "";

            for (0.., data_mut[0 .. data_mut.len - 1]) |i, buf| {
                if (buf.len > 0) {
                    header = buf;
                    data_mut = data_mut[i + 1 ..];
                    continue :check_skip;
                }
            }
            
            if (splat_mut == 0) break;
            const splat_data = data_mut[data_mut.len - 1];
            if (splat_data.len == 0) break;

            const full_splats_wanted = if (splat_data.len == 1) c: {
                @branchHint(.likely);
                break :c self.skip_remaining;
            } else self.skip_remaining / splat_data.len;

            const splats_to_consume = @min(splat_mut, full_splats_wanted);
            const splat_bytes_skipped = splats_to_consume * splat_data.len;
            processed_bytes += splat_bytes_skipped;
            self.skip_remaining -= splat_bytes_skipped;
            splat_mut -= splats_to_consume;

            if (splat_mut > 0 and self.skip_remaining > 0) {
                splat_mut -= 1;
                std.debug.assert(self.skip_remaining <= splat_data.len); // otherwise splats_to_consume would have been larger
                processed_bytes += self.skip_remaining;
                header = splat_data[self.skip_remaining..];
                self.skip_remaining = 0;
            }

            break;
        }
        
        if (self.skip_remaining == 0 and self.body_remaining > 0 and (header.len > 0 or data_mut.len > 1 or splat_mut > 0 and data_mut[data_mut.len - 1].len > 0)) {
            const bytes_written = try self.out.writeSplatHeaderLimit(header, data_mut, splat_mut, .limited(self.body_remaining));
            processed_bytes += bytes_written;
            self.body_remaining -= bytes_written;
        }

        return if (processed_bytes < w.end) 0 else processed_bytes - w.end;
    }

    fn sendFile(w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));

        try self.setup();

        var header = w.buffered();
        var limit_mut = limit;

        var processed_bytes: usize = 0;
        defer if (processed_bytes < w.end) {
            const remaining = w.buffer[processed_bytes..w.end];
            @memmove(w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
        } else {
            w.end = 0;
        };

        if (self.skip_remaining > 0) {
            if (self.skip_remaining <= header.len) {
                header = header[self.skip_remaining..];
                processed_bytes += self.skip_remaining;
                self.skip_remaining = 0;
            } else {
                processed_bytes += header.len;
                self.skip_remaining -= header.len;
                header = "";

                if (self.content_length > 0) {
                    const seek_limit = limit_mut.min(.limited(self.skip_remaining));
                    file_reader.seekBy(@intCast(seek_limit.toInt().?)) catch |err| {
                        file_reader.seek_err = err;
                        return error.ReadFailed;
                    };
                    limit_mut = limit_mut.subtract(seek_limit.toInt().?).?;
                }
            }
        }

        if (self.body_remaining > 0) {
            if (header.len > 0) {
                const header_bytes_written = try self.out.write(header[0..@min(header.len, self.body_remaining)]);
                processed_bytes += header_bytes_written;
                self.body_remaining -= header_bytes_written;
                if (processed_bytes < w.end) return 0;
            }

            const new_limit: std.Io.Limit = .min(limit_mut, .limited(self.body_remaining));

            const sendfile_bytes = try self.out.sendFile(file_reader, new_limit);
            processed_bytes += sendfile_bytes;
            self.body_remaining -= sendfile_bytes;
            return processed_bytes - w.end;
        }

        return 0;
    }
};

pub fn write_terminal_boundary(boundary: []const u8, w: *std.Io.Writer) !void {
    var strings: [3][]const u8 = .{ "\r\n--", boundary, "--\r\n" };
    try w.writeVecAll(&strings);
}

const Range = @This();

const Request = @import("Request.zig");
const std = @import("std");
