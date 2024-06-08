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
const arg_map = util.ComptimeStringMap(Arg_Type, .{
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

const Resource_File = struct {
    realpath: []const u8,
    static_template: bool,
    digest: ?Digest = null,
    compressed_content: ?[]const u8 = null,
    http_path: ?[]const u8 = null,
};

const Template_File = struct {
    source: zkittle.Source,
    instructions: ?usize = null,
    instruction_data: []const usize = &.{},
};

var resource_files: std.StringHashMap(Resource_File) = undefined;
var template_files: std.StringHashMap(Template_File) = undefined;
var template_parser: zkittle.Parser = undefined;

pub fn main() !void {
    resource_files = std.StringHashMap(Resource_File).init(gpa.allocator());
    template_files = std.StringHashMap(Template_File).init(gpa.allocator());
    defer resource_files.deinit();
    defer template_files.deinit();

    const out_path = try parse_args_and_source_paths();

    try process_resource_files();

    template_parser = .{
        .gpa = gpa.allocator(),
        .include_callback = template_source,
        .resource_callback = resource_path,
    };
    defer template_parser.deinit();

    try process_template_files();

    try write_output(out_path);
}

fn parse_args_and_source_paths() ![]const u8 {
    var search_paths = std.ArrayList([]const u8).init(gpa.allocator());
    defer search_paths.deinit();

    var extensions = std.StringHashMap(Arg_Type).init(gpa.allocator());
    defer extensions.deinit();

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    var out_path: []const u8 = "res.zig";
    var dep_path: []const u8 = "res.zig.d";

    while (arg_iter.next()) |arg| {
        if (arg_map.get(arg)) |arg_type| switch (arg_type) {
            .source_path => {
                const path = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedSourcePath);
                try search_paths.append(path);
            },
            .output_file => {
                out_path = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedOutputFile);
            },
            .dependency_file => {
                dep_path = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedDependencyFile);
            },
            .ignored_extension, .template_extension, .static_template_extension => {
                const ext = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedExtension);
                try extensions.put(ext, arg_type);
            },
        };
    }

    const df = try std.fs.cwd().createFile(dep_path, .{});
    defer df.close();
    var dep_out = df.writer();
    try dep_out.print("\"{}\": ", .{ std.zig.fmtEscapes(out_path) });

    for (search_paths.items) |search_path| {
        var base = search_path;
        if (std.mem.endsWith(u8, search_path, std.fs.path.sep_str)) {
            base = search_path[0 .. search_path.len - 1];
        }

        var dir = try std.fs.cwd().openDir(search_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(gpa.allocator());
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                const ext = extensions.get(std.fs.path.extension(entry.path)) orelse .source_path;
                switch (ext) {
                    .template_extension => {
                        const unix_path = try std.fmt.allocPrint(arena.allocator(), "{s}", .{ entry.path });
                        std.mem.replaceScalar(u8, unix_path, '\\', '/');
                        const source = try zkittle.Source.init_file(arena.allocator(), &dir, entry.path);
                        try template_files.putNoClobber(unix_path, .{
                            .source = source,
                        });
                    },
                    .static_template_extension, .source_path => {
                        const unix_path = try std.fmt.allocPrint(arena.allocator(), "{s}", .{ entry.path });
                        std.mem.replaceScalar(u8, unix_path, '\\', '/');
                        try resource_files.putNoClobber(unix_path, .{
                            .realpath = try dir.realpathAlloc(arena.allocator(), entry.path),
                            .static_template = ext == .static_template_extension,
                        });

                        
                    },
                    else => continue,
                }
                try dep_out.print("\"{}{s}{}\" ", .{
                    std.zig.fmtEscapes(base),
                    std.fs.path.sep_str,
                    std.zig.fmtEscapes(entry.path),
                });
            }
        }
    }

    return out_path;
}

fn process_resource_files() !void {
    var iter = resource_files.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const info = entry.value_ptr;

        if (info.digest == null) {
            try process_resource(path, info);
        }
    }
}

fn process_resource(path: []const u8, info: *Resource_File) anyerror!void {
    // prevent reference cycles from causing stack overflow:
    info.digest = std.mem.zeroes(Digest);

    var content = try std.fs.cwd().readFileAlloc(gpa.allocator(), info.realpath, 100_000_000);
    defer gpa.allocator().free(content);

    const ext = std.fs.path.extension(path);
    if (info.static_template) {
        var builder = std.ArrayList(u8).init(gpa.allocator());
        defer builder.deinit();

        var parser: zkittle.Parser = .{
            .gpa = gpa.allocator(),
            .include_callback = template_source,
            .resource_callback = resource_path,
        };
        defer parser.deinit();

        var source = try zkittle.Source.init_buf(gpa.allocator(), path, content);
        defer source.deinit(gpa.allocator());

        try parser.append(source);

        var template = try parser.finish(gpa.allocator(), true);
        defer template.deinit(gpa.allocator());

        var writer = builder.writer();
        try template.render(writer.any(), {}, .{ .escape_fn = zkittle.escape_none });

        gpa.allocator().free(content);
        content = try builder.toOwnedSlice();
    }

    var hash: Digest = undefined;
    Hash.hash(content, &hash, .{});

    var stream = std.io.fixedBufferStream(content);
    var compressed = std.ArrayList(u8).init(gpa.allocator());
    defer compressed.deinit();
    try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{ .level = .level_9 });

    info.digest = hash;
    info.compressed_content = try arena.allocator().dupe(u8, compressed.items);
    info.http_path = try std.fmt.allocPrint(arena.allocator(), "/{}{s}", .{ std.fmt.fmtSliceHexLower(&hash), ext });
}

fn process_template_files() !void {
    var iter = template_files.valueIterator();
    while (iter.next()) |info| {
        try template_parser.append(info.source);
        var template = try template_parser.finish(gpa.allocator(), false);
        defer template.deinit(gpa.allocator());

        info.instruction_data = try template.get_static_instruction_data(arena.allocator());
        info.instructions = template.opcodes.len;
    }
}

fn write_output(out_path: []const u8) !void {
    const f = try std.fs.cwd().createFile(out_path, .{});
    defer f.close();
    var out = f.writer();

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

    {
        var iter = resource_files.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            if (info.digest) |digest| {
                try out.print("pub const {} = \"{}\";\n", .{
                    std.zig.fmtId(path),
                    std.fmt.fmtSliceHexLower(&digest),
                });
            }
        }
    }

    try out.writeAll(
        \\
        \\/// zlib compressed resource content
        \\pub const content = struct {
        \\
    );
    
    {
        var iter = resource_files.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            if (info.compressed_content) |content| {
                try out.print("    pub const {} = \"{}\";\n", .{
                    std.zig.fmtId(path),
                    std.zig.fmtEscapes(content),
                });
            }
        }
    }

    try out.writeAll(
        \\};
        \\
        \\pub const templates = struct {
        \\    const data = struct {
        \\
    );
    
    {
        var iter = template_files.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            if (info.instructions) |_| {
                try out.print("        pub const {} = [_]u64 {{", .{
                    std.zig.fmtId(path),
                });

                var i: usize = 8;
                for (info.instruction_data) |word| {
                    if (i == 8) {
                        i = 0;
                        try out.writeAll("\n            ");
                    } else {
                        i += 1;
                        try out.writeByte(' ');
                    }
                    try out.print("{},", .{ word });
                }

                try out.writeAll("\n        };\n");
            }
        }
    }

    try out.print(
        \\        const literal_data = "{}";
        \\    }};
        \\
        , .{ std.zig.fmtEscapes(template_parser.literal_data.items) });

    {
        var iter = template_files.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            if (info.instructions) |instruction_count| {
                try out.print("    pub const {} = zkittle.init_static({}, &data.{}, data.literal_data);\n", .{
                    std.zig.fmtId(path),
                    instruction_count,
                    std.zig.fmtId(path),
                });
            }
        }
    }

    try out.writeAll(
        \\};
        \\
    );
}

fn resource_path(raw_path: []const u8) anyerror![]const u8 {
    var temp_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const unix_path = try std.fmt.bufPrint(&temp_path_buf, "{s}", .{ raw_path });
    std.mem.replaceScalar(u8, unix_path, '\\', '/');

    const entry = resource_files.getEntry(unix_path) orelse return error.FileNotFound;
    const path = entry.key_ptr.*;
    const info = entry.value_ptr;

    if (info.http_path) |http_path| {
        return http_path;
    }

    if (info.digest) |_| {
        log.err("Circular dependency detected involving {s}", .{ path });
        return error.CircularDependency;
    }

    try process_resource(path, info);
    return info.http_path.?;
}

fn template_source(raw_path: []const u8) anyerror!zkittle.Source {
    var temp_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const unix_path = try std.fmt.bufPrint(&temp_path_buf, "{s}", .{ raw_path });
    std.mem.replaceScalar(u8, unix_path, '\\', '/');

    const info = template_files.get(unix_path) orelse return error.FileNotFound;
    return info.source;
}

const log = std.log.scoped(.index_resources);

const util = @import("util.zig");
const zkittle = @import("zkittle");
const std = @import("std");
