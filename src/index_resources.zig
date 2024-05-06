var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Arg_Type = enum {
    source_path,
    output_file,
    dependency_file,
    ignored_extension,
    template_extension,
};
const arg_map = std.ComptimeStringMap(Arg_Type, .{
    .{ "-s", .source_path },
    .{ "--src", .source_path },
    .{ "-o", .output_file },
    .{ "--out", .output_file },
    .{ "-D", .dependency_file },
    .{ "--depfile", .dependency_file },
    .{ "-i", .ignored_extension },
    .{ "--ignore-ext", .ignored_extension },
    .{ "-t", .template_extension },
    .{ "--template-ext", .template_extension },
});

const Hash = std.crypto.hash.sha2.Sha256;
const Digest = [Hash.digest_length]u8;

var out: std.fs.File.Writer = undefined;
var dep_out: std.fs.File.Writer = undefined;
var digest_map: std.StringHashMap(Digest) = undefined;
var content_map: std.StringHashMap([]const u8) = undefined;
var content: std.ArrayList(u8) = undefined;
var template_extensions: std.StringHashMap(void) = undefined;
var current_dir: *std.fs.Dir = undefined;
var current_dir_path: []const u8 = undefined;

pub fn main() !void {
    var search_paths = std.ArrayList([]const u8).init(gpa.allocator());
    defer search_paths.deinit();

    template_extensions = std.StringHashMap(void).init(gpa.allocator());
    defer template_extensions.deinit();

    var ignored_extensions = std.StringHashMap(void).init(gpa.allocator());
    defer template_extensions.deinit();

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    var out_path: []const u8 = "res.zig";
    var dep_path: []const u8 = "res.zig.d";

    while (arg_iter.next()) |arg| {
        if (arg_map.get(arg)) |arg_type| switch (arg_type) {
            .source_path => try search_paths.append(arg_iter.next() orelse return error.ExpectedSourcePath),
            .output_file => out_path = arg_iter.next() orelse return error.ExpectedOutputFile,
            .dependency_file => dep_path = arg_iter.next() orelse return error.ExpectedDependencyFile,
            .ignored_extension => try template_extensions.put(arg_iter.next() orelse return error.ExpectedExtension, {}),
            .template_extension => try template_extensions.put(arg_iter.next() orelse return error.ExpectedExtension, {}),
        };
    }

    content = std.ArrayList(u8).init(gpa.allocator());
    defer content.deinit();

    digest_map = std.StringHashMap(Digest).init(gpa.allocator());
    defer digest_map.deinit();

    content_map = std.StringHashMap([]const u8).init(gpa.allocator());
    defer content_map.deinit();

    const f = try std.fs.cwd().createFile(out_path, .{});
    defer f.close();

    const df = try std.fs.cwd().createFile(dep_path, .{});
    defer df.close();

    out = f.writer();
    dep_out = df.writer();

    try dep_out.print("\"{}\": ", .{ std.zig.fmtEscapes(out_path) });

    try out.print(
        \\const tempora = @import("tempora");
        \\pub const build_time = tempora.Date_Time.With_Offset.from_timestamp_s({}, null).dt;
        \\
        \\
        , .{
            std.time.timestamp(),
        });

    for (search_paths.items) |search_path| {
        var dir = try std.fs.cwd().openDir(search_path, .{ .iterate = true });
        defer dir.close();
        current_dir = &dir;
        current_dir_path = search_path;

        var walker = try current_dir.walk(gpa.allocator());
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (ignored_extensions.get(std.fs.path.extension(entry.path)) != null) continue;

                _ = try resource_path(entry.path);
            }
        }
    }

    try out.writeAll(
        \\
        \\pub const content = struct {
        \\
    );
    try out.writeAll(content.items);
    try out.writeAll(
        \\};
        \\
    );
}

var temp_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

fn resource_path(path: []const u8) anyerror![]const u8 {
    const ext = std.fs.path.extension(path);

    if (digest_map.get(path)) |digest| {
        if (std.mem.eql(u8, &digest, &std.mem.zeroes(Digest))) {
            log.err("Circular dependency detected involving {s}", .{ path });
            return error.CircularDependency;
        }
    } else {
        try process_resource(path);
    }
    return std.fmt.bufPrint(&temp_path_buf, "/{}{s}", .{ std.fmt.fmtSliceHexLower(&digest_map.get(path).?), ext });
}

fn resource_content(path: []const u8) anyerror![]const u8 {
    if (digest_map.get(path)) |digest| {
        if (std.mem.eql(u8, &digest, &std.mem.zeroes(Digest))) {
            log.err("Circular dependency detected involving {s}", .{ path });
            return error.CircularDependency;
        }
    } else {
        try process_resource(path);
    }
    return content_map.get(path).?;
}

fn process_resource(path: []const u8) !void {
    const owned_path = try std.fs.path.resolvePosix(arena.allocator(), &.{ path });
    const ext = std.fs.path.extension(path);

    // prevent reference cycles from causing stack overflow:
    try digest_map.put(owned_path, std.mem.zeroes(Digest));

    var the_resource_content = try current_dir.readFileAlloc(gpa.allocator(), path, 100_000_000);
    defer gpa.allocator().free(the_resource_content);

    if (template_extensions.get(ext) != null) {
        var builder = std.ArrayList(u8).init(gpa.allocator());
        defer builder.deinit();

        try template.render(the_resource_content, {}, builder.writer(), .{
            .resource_path = resource_path,
            .resource_content = resource_content,
        });

        gpa.allocator().free(the_resource_content);
        the_resource_content = try builder.toOwnedSlice();

        try content.writer().print("    pub const {} = \"{}\";\n", .{
            std.zig.fmtId(owned_path),
            std.zig.fmtEscapes(the_resource_content),
        });
    } else {
        try content.writer().print("    pub const {} = \"{}\";\n", .{
            std.zig.fmtId(owned_path),
            std.zig.fmtEscapes(the_resource_content),
        });
    }

    var hash: Digest = undefined;
    Hash.hash(the_resource_content, &hash, .{});

    try digest_map.put(owned_path, hash);
    try content_map.put(owned_path, try arena.allocator().dupe(u8, the_resource_content));

    try dep_out.print("\"{}{s}{}\" ", .{
        std.zig.fmtEscapes(current_dir_path),
        std.fs.path.sep_str,
        std.zig.fmtEscapes(owned_path),
    });

    try out.print("pub const {} = \"{}\";\n", .{
        std.zig.fmtId(owned_path),
        std.fmt.fmtSliceHexLower(&hash),
    });
}

const log = std.log.scoped(.index_resources);

const template = @import("template.zig");
const std = @import("std");
