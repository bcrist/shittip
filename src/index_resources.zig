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
    .{ "-s", .static_template_extension },
    .{ "--static-template-ext", .static_template_extension },
});

const Hash = std.crypto.hash.sha2.Sha256;
const Digest = [Hash.digest_length]u8;

var out: std.fs.File.Writer = undefined;
var dep_out: std.fs.File.Writer = undefined;
var digest_map: std.StringHashMap(Digest) = undefined;
var content_map: std.StringHashMap([]const u8) = undefined;
var template_source_map: std.StringHashMap(zkittle.Source) = undefined;
var content_writer: std.io.AnyWriter = undefined;
var templates_writer: std.io.AnyWriter = undefined;
var extensions: std.StringHashMap(Arg_Type) = undefined;
var current_dir: *std.fs.Dir = undefined;
var current_dir_path: []const u8 = undefined;

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

    var templates_struct = std.ArrayList(u8).init(gpa.allocator());
    defer templates_struct.deinit();
    const templates_struct_writer = templates_struct.writer();
    templates_writer = templates_struct_writer.any();

    digest_map = std.StringHashMap(Digest).init(gpa.allocator());
    defer digest_map.deinit();

    content_map = std.StringHashMap([]const u8).init(gpa.allocator());
    defer content_map.deinit();

    template_source_map = std.StringHashMap(zkittle.Source).init(gpa.allocator());
    defer template_source_map.deinit();

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

        var walker = try dir.walk(std.heap.page_allocator);
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
        \\
    );
    try out.writeAll(templates_struct.items);
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

fn process_resource(path: []const u8) anyerror!void {
    const owned_path = try arena.allocator().dupe(u8, path);
    std.mem.replaceScalar(u8, owned_path, '\\', '/');
    const ext = std.fs.path.extension(path);

    // prevent reference cycles from causing stack overflow:
    try digest_map.put(owned_path, std.mem.zeroes(Digest));

    var the_resource_content = try current_dir.readFileAlloc(gpa.allocator(), path, 100_000_000);
    defer gpa.allocator().free(the_resource_content);

    if ((extensions.get(ext) orelse .source_path) == .static_template_extension) {
        var builder = std.ArrayList(u8).init(gpa.allocator());
        defer builder.deinit();

        var parser: zkittle.Parser = .{
            .gpa = gpa.allocator(),
            .include_callback = process_template,
            .resource_callback = resource_path,
        };
        defer parser.deinit();

        var source = try zkittle.Source.init_buf(gpa.allocator(), owned_path, the_resource_content);
        defer source.deinit(gpa.allocator());

        try parser.append(source);

        var template = try parser.finish(gpa.allocator());
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

fn process_template(path: []const u8) anyerror!zkittle.Source {
    const owned_path = try arena.allocator().dupe(u8, path);
    std.mem.replaceScalar(u8, owned_path, '\\', '/');

    if (template_source_map.get(owned_path)) |source| {
        arena.allocator().free(owned_path);
        return source;
    }

    const source = try zkittle.Source.init_file(arena.allocator(), current_dir, path);
    try template_source_map.put(owned_path, source);

    var parser: zkittle.Parser = .{
        .gpa = gpa.allocator(),
        .include_callback = process_template,
        .resource_callback = resource_path,
    };
    defer parser.deinit();

    try parser.append(source);

    var template = try parser.finish(gpa.allocator());
    defer template.deinit(gpa.allocator());

    var template_data = std.ArrayList(u8).init(gpa.allocator());
    defer template_data.deinit();

    const operands: []const zkittle.Operands = template.operands[0..template.opcodes.len];
    try template_data.appendSlice(std.mem.sliceAsBytes(operands));

    const start_of_opcodes = std.mem.alignForward(usize, template_data.items.len, @alignOf(zkittle.Opcode));
    try template_data.appendNTimes(0, start_of_opcodes - template_data.items.len);
    try template_data.appendSlice(std.mem.sliceAsBytes(template.opcodes));
    try template_data.appendSlice(template.literal_data);

    try templates_writer.print("    pub const {} = zkittle.init_static({}, \"{}\");\n", .{
        std.zig.fmtId(owned_path),
        template.opcodes.len,
        std.zig.fmtEscapes(template_data.items),
    });

    try dep_out.print("\"{}{s}{}\" ", .{
        std.zig.fmtEscapes(current_dir_path),
        std.fs.path.sep_str,
        std.zig.fmtEscapes(owned_path),
    });

    return source;
}

const log = std.log.scoped(.index_resources);

const zkittle = @import("zkittle");
const std = @import("std");
