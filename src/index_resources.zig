var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Arg_Type = enum {
    source_path,
    output_file,
    dependency_file,
    ignored_extension,
    template_extension,
    static_template_extension,
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
    .{ "-T", .static_template_extension },
    .{ "--static-template-ext", .static_template_extension },
});

const Hash = std.crypto.hash.sha2.Sha256;
const Digest = [Hash.digest_length]u8;

var out: std.fs.File.Writer = undefined;
var dep_out: std.fs.File.Writer = undefined;
var digest_map: std.StringHashMap(Digest) = undefined;
var path_map: std.StringHashMap([]const u8) = undefined;
var content_map: std.StringHashMap([]const u8) = undefined;
var template_source_map: std.StringHashMap(zkittle.Source) = undefined;
var content_writer: std.io.AnyWriter = undefined;
var templates_data_writer: std.io.AnyWriter = undefined;
var templates_writer: std.io.AnyWriter = undefined;
var extensions: std.StringHashMap(Arg_Type) = undefined;
var current_dir: *std.fs.Dir = undefined;
var current_dir_path: []const u8 = undefined;
var template_parser: zkittle.Parser = undefined;

pub fn main() !void {
    var search_paths = std.ArrayList([]const u8).init(gpa.allocator());
    defer search_paths.deinit();

    extensions = std.StringHashMap(Arg_Type).init(gpa.allocator());
    defer extensions.deinit();

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    var out_path: []const u8 = "res.zig";
    var dep_path: []const u8 = "res.zig.d";

    while (arg_iter.next()) |arg| {
        if (arg_map.get(arg)) |arg_type| switch (arg_type) {
            .source_path => try search_paths.append(arg_iter.next() orelse return error.ExpectedSourcePath),
            .output_file => out_path = arg_iter.next() orelse return error.ExpectedOutputFile,
            .dependency_file => dep_path = arg_iter.next() orelse return error.ExpectedDependencyFile,
            .ignored_extension, .template_extension, .static_template_extension => {
                try extensions.put(arg_iter.next() orelse return error.ExpectedExtension, arg_type);
            },
        };
    }

    var content_struct = std.ArrayList(u8).init(gpa.allocator());
    defer content_struct.deinit();
    const content_struct_writer = content_struct.writer();
    content_writer = content_struct_writer.any();

    var templates_data_struct = std.ArrayList(u8).init(gpa.allocator());
    defer templates_data_struct.deinit();
    const templates_data_struct_writer = templates_data_struct.writer();
    templates_data_writer = templates_data_struct_writer.any();

    var templates_struct = std.ArrayList(u8).init(gpa.allocator());
    defer templates_struct.deinit();
    const templates_struct_writer = templates_struct.writer();
    templates_writer = templates_struct_writer.any();

    digest_map = std.StringHashMap(Digest).init(gpa.allocator());
    defer digest_map.deinit();

    path_map = std.StringHashMap([]const u8).init(gpa.allocator());
    defer path_map.deinit();

    content_map = std.StringHashMap([]const u8).init(gpa.allocator());
    defer content_map.deinit();

    template_source_map = std.StringHashMap(zkittle.Source).init(gpa.allocator());
    defer template_source_map.deinit();

    template_parser = .{
        .gpa = gpa.allocator(),
        .include_callback = template_source,
        .resource_callback = resource_path,
    };
    defer template_parser.deinit();

    const f = try std.fs.cwd().createFile(out_path, .{});
    defer f.close();

    const df = try std.fs.cwd().createFile(dep_path, .{});
    defer df.close();

    out = f.writer();
    dep_out = df.writer();

    try dep_out.print("\"{}\": ", .{ std.zig.fmtEscapes(out_path) });

    try out.print(
        \\const tempora = @import("tempora");
        \\const zkittle = @import("zkittle");
        \\
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

        var walker = try dir.walk(gpa.allocator());
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (extensions.get(std.fs.path.extension(entry.path))) |kind| switch (kind) {
                    .ignored_extension => continue,
                    .template_extension => {
                        _ = try process_template(entry.path);
                        continue;
                    },
                    else => {},
                };
                _ = try resource_path(entry.path);
            }
        }
    }

    try out.writeAll(
        \\
        \\pub const content = struct {
        \\
    );
    try out.writeAll(content_struct.items);
    try out.writeAll(
        \\};
        \\
        \\pub const templates = struct {
        \\    const data = struct {
        \\
    );
    try out.writeAll(templates_data_struct.items);
    try out.print(
        \\        const literal_data = "{}";
        \\    }};
        \\
        , .{ std.zig.fmtEscapes(template_parser.literal_data.items) });
    try out.writeAll(templates_struct.items);
    try out.writeAll(
        \\};
        \\
    );
}

var temp_path: [std.fs.MAX_PATH_BYTES]u8 = undefined;
fn get_unix_path(path: []const u8) ![]const u8 {
    const unix_path = try std.fmt.bufPrint(&temp_path, "{s}", .{ path });
    std.mem.replaceScalar(u8, unix_path, '\\', '/');
    return unix_path;
}

fn resource_path(path: []const u8) anyerror![]const u8 {
    const unix_path = try get_unix_path(path);

    if (digest_map.get(unix_path)) |digest| {
        if (std.mem.eql(u8, &digest, &std.mem.zeroes(Digest))) {
            log.err("Circular dependency detected involving {s}", .{ unix_path });
            return error.CircularDependency;
        }
        return path_map.get(unix_path).?;
    } else {
        try process_resource(unix_path);
        return path_map.get(try get_unix_path(path)).?;
    }
}

fn process_resource(unix_path: []const u8) anyerror!void {
    const owned_path = try arena.allocator().dupe(u8, unix_path);

    // prevent reference cycles from causing stack overflow:
    try digest_map.put(owned_path, std.mem.zeroes(Digest));

    var the_resource_content = try current_dir.readFileAlloc(gpa.allocator(), unix_path, 100_000_000);
    defer gpa.allocator().free(the_resource_content);

    const ext = std.fs.path.extension(owned_path);
    if ((extensions.get(ext) orelse .source_path) == .static_template_extension) {
        var builder = std.ArrayList(u8).init(gpa.allocator());
        defer builder.deinit();

        var parser: zkittle.Parser = .{
            .gpa = gpa.allocator(),
            .include_callback = template_source,
            .resource_callback = resource_path,
        };
        defer parser.deinit();

        var source = try zkittle.Source.init_buf(gpa.allocator(), owned_path, the_resource_content);
        defer source.deinit(gpa.allocator());

        try parser.append(source);

        var template = try parser.finish(gpa.allocator(), true);
        defer template.deinit(gpa.allocator());

        var writer = builder.writer();
        try template.render(writer.any(), {}, .{ .escape_fn = zkittle.escape_none });

        gpa.allocator().free(the_resource_content);
        the_resource_content = try builder.toOwnedSlice();

        try content_writer.print("    pub const {} = \"{}\";\n", .{
            std.zig.fmtId(owned_path),
            std.zig.fmtEscapes(the_resource_content),
        });
    } else {
        try content_writer.print("    pub const {} = \"{}\";\n", .{
            std.zig.fmtId(owned_path),
            std.zig.fmtEscapes(the_resource_content),
        });
    }

    var hash: Digest = undefined;
    Hash.hash(the_resource_content, &hash, .{});

    try digest_map.put(owned_path, hash);
    try content_map.put(owned_path, try arena.allocator().dupe(u8, the_resource_content));
    try path_map.put(owned_path, try std.fmt.allocPrint(arena.allocator(), "/{}{s}", .{ std.fmt.fmtSliceHexLower(&digest_map.get(owned_path).?), ext }));

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

fn template_source(path: []const u8) anyerror!zkittle.Source {
    const owned_path = try arena.allocator().dupe(u8, path);
    std.mem.replaceScalar(u8, owned_path, '\\', '/');

    if (template_source_map.get(owned_path)) |source| {
        arena.allocator().free(owned_path);
        return source;
    }

    const source = try zkittle.Source.init_file(arena.allocator(), current_dir, path);
    try template_source_map.put(owned_path, source);
    return source;
}

fn process_template(path: []const u8) anyerror!zkittle.Source {
    const unix_path = try get_unix_path(path);
    const source = try template_source(path);

    try template_parser.append(source);

    var template = try template_parser.finish(gpa.allocator(), false);
    defer template.deinit(gpa.allocator());

    const instruction_data = try template.get_static_instruction_data(gpa.allocator());

    try templates_data_writer.print("        pub const {} = [_]u64 {{", .{
        std.zig.fmtId(unix_path),
    });

    var i: usize = 8;
    for (instruction_data) |word| {
        if (i == 8) {
            i = 0;
            try templates_data_writer.writeAll("\n            ");
        } else {
            i += 1;
            try templates_data_writer.writeByte(' ');
        }
        try templates_data_writer.print("{},", .{ word });
    }

    try templates_data_writer.writeAll("\n        };\n");

    try templates_writer.print("    pub const {} = zkittle.init_static({}, &data.{}, data.literal_data);\n", .{
        std.zig.fmtId(unix_path),
        template.opcodes.len,
        std.zig.fmtId(unix_path),
    });

    try dep_out.print("\"{}{s}{}\" ", .{
        std.zig.fmtEscapes(current_dir_path),
        std.fs.path.sep_str,
        std.zig.fmtEscapes(unix_path),
    });

    return source;
}

const log = std.log.scoped(.index_resources);

const zkittle = @import("zkittle");
const std = @import("std");
