/// usage:
///    generate_res <templates_dir> <metadata_dir> <output_file> <template_string_data_output_file> <depfile_path> [[-t <extension>]... <search_path>]...

pub fn main() !void {
    defer std.debug.assert(.ok == gpa.deinit());

    Resource_File.cache = .{
        .arena = arena.allocator(),
        .gpa = gpa.allocator(),
    };
    defer Resource_File.cache.?.deinit();

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    _ = arg_iter.next(); // exe name
    const template_dir_path = arg_iter.next() orelse return error.ExpectedTemplateDir;
    const metadata_dir_path = arg_iter.next() orelse return error.ExpectedMetadataDir;
    const out_path = arg_iter.next() orelse return error.ExpectedOutputPath;
    const template_string_data_out_path = arg_iter.next() orelse return error.ExpectedTemplateStringDataOutputPath;
    const depfile_path = arg_iter.next() orelse return error.ExpectedDepfilePath;
    
    var template_extensions = std.ArrayList([]const u8).init(gpa.allocator());
    defer template_extensions.deinit();

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            const ext = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedTemplateExtension);
            try template_extensions.append(ext);
        } else {
            const path = try arena.allocator().dupe(u8, arg);
            try Resource_File.cache.?.add_dir(path, template_extensions.items);
            template_extensions.clearRetainingCapacity();
        }
    }

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    var out = out_file.writer();

    var temp = std.ArrayList(u8).init(gpa.allocator());
    defer temp.deinit();

    { // Templates
        try out.print(
            \\const tempora = @import("tempora");
            \\const zkittle = @import("zkittle");
            \\
            \\pub const build_time = tempora.Date_Time.With_Offset.from_timestamp_s({}, null).dt;
            \\
            \\pub const templates = struct {{
            \\
            , .{ std.time.timestamp() });

        var parser: zkittle.Parser = .{
            .gpa = gpa.allocator(),
            .include_callback = Resource_File.template_include,
            .resource_callback = Resource_File.template_resource,
        };
        defer parser.deinit();

        var tw = temp.writer();
        
        var template_dir = try std.fs.cwd().openDir(template_dir_path, .{ .iterate = true });
        defer template_dir.close();

        var walker = try template_dir.walk(gpa.allocator());
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const source = try zkittle.Source.init_file(arena.allocator(), template_dir, entry.path);

            try parser.append(source);
            var template = try parser.finish(gpa.allocator(), false);
            defer template.deinit(gpa.allocator());

            const instruction_data = try template.get_static_instruction_data(arena.allocator());
            const instruction_count = template.opcodes.len;

            var temp_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const unix_path = try std.fmt.bufPrint(&temp_path_buf, "{s}", .{ entry.path });
            std.mem.replaceScalar(u8, unix_path, '\\', '/');

            try out.print("    pub const {} = zkittle.init_static({}, &data.{}, data.strings);\n", .{
                std.zig.fmtId(unix_path),
                instruction_count,
                std.zig.fmtId(unix_path),
            });

            try tw.print("\n        pub const {} = [_]u64 {{", .{
                std.zig.fmtId(unix_path),
            });

            var i: usize = 8;
            for (instruction_data) |word| {
                if (i == 8) {
                    i = 0;
                    try tw.writeAll("\n            ");
                } else {
                    i += 1;
                    try tw.writeByte(' ');
                }
                try tw.print("{},", .{ word });
            }

            try tw.writeAll("\n        };\n");
        }

        try out.writeAll(
            \\    const data = struct {
            \\        const strings = @embedFile("template_string_data");
            \\
        );
        try out.writeAll(temp.items);
        try out.writeAll(
            \\    };
            \\};
            \\
            \\
        );

        try std.fs.cwd().writeFile(.{
            .sub_path = template_string_data_out_path,
            .data = parser.literal_data.items,
        });
    }

    temp.clearRetainingCapacity();

    { // Hashed resources
        var hash_dedup = std.StringHashMap([]const u8).init(gpa.allocator());
        defer hash_dedup.deinit();

        var metadata_dir = try std.fs.cwd().openDir(metadata_dir_path, .{ .iterate = true });
        defer metadata_dir.close();

        var walker = try metadata_dir.walk(gpa.allocator());
        defer walker.deinit();

        var tw = temp.writer();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const f = try metadata_dir.openFile(entry.path, .{});
            defer f.close();
            const r = f.reader();

            var unix_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            var unix_path_stream = std.io.fixedBufferStream(&unix_path_buf);
            try r.streamUntilDelimiter(unix_path_stream.writer(), '\n', null);
            const unix_path = unix_path_stream.getWritten();
            std.mem.replaceScalar(u8, unix_path, '\\', '/');

            var compressed_file_path_buf: [256]u8 = undefined;
            var compressed_file_path_stream = std.io.fixedBufferStream(&compressed_file_path_buf);
            try r.streamUntilDelimiter(compressed_file_path_stream.writer(), '\n', null);

            var hash_buf: [@sizeOf(Resource_File.Digest) * 2]u8 = undefined;
            var hash_stream = std.io.fixedBufferStream(&hash_buf);
            try r.streamUntilDelimiter(hash_stream.writer(), '\n', null);

            const gop = try hash_dedup.getOrPut(hash_stream.getWritten());
            if (gop.found_existing) {
                try tw.print("    pub const {} = content.{};\n", .{
                    std.zig.fmtId(unix_path),
                    std.zig.fmtId(gop.value_ptr.*),
                });
            } else {
                gop.key_ptr.* = try arena.allocator().dupe(u8, hash_stream.getWritten());
                gop.value_ptr.* = try arena.allocator().dupe(u8, unix_path);

                try tw.print("    pub const {} = @embedFile(\"{}\");\n", .{
                    std.zig.fmtId(unix_path),
                    std.zig.fmtEscapes(compressed_file_path_stream.getWritten()),
                });
            }

            try out.print("pub const {} = \"{s}\";\n", .{
                std.zig.fmtId(unix_path),
                hash_stream.getWritten(),
            });
        }

        try out.writeAll(
            \\
            \\/// zlib compressed resource content
            \\pub const content = struct {
            \\
        );
        try out.writeAll(temp.items);
        try out.writeAll("};\n");
    }

    { // Depfile
        const depfile = try std.fs.cwd().createFile(depfile_path, .{});
        defer depfile.close();
        var dw = depfile.writer();

        try dw.print("\"{s}\":", .{ out_path });

        for (Resource_File.cache.?.files.values()) |file| {
            try dw.print(" \"{s}\"", .{ file.realpath });
        }
    }
}

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Resource_File = @import("Resource_File.zig");
const zkittle = @import("zkittle");
const std = @import("std");
