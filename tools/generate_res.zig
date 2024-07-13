/// usage:
///    generate_res <templates_dir> <metadata_dir> <output_file> <template_string_data_output_file> <depfile_path> [[-t <extension>]... <search_path>]...

pub fn main() !void {
    defer std.debug.assert(.ok == gpa.deinit());

    var cache: Resource_File.Cache = .{
        .arena = arena.allocator(),
        .gpa = gpa.allocator(),
    };
    defer cache.deinit();

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
            try cache.add_dir(path, template_extensions.items);
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
            \\const Template = @import("zkittle");
            \\
            \\pub const build_time = tempora.Date_Time.With_Offset.from_timestamp_s({}, null).dt;
            \\
            \\pub const templates = struct {{
            \\
            , .{ std.time.timestamp() });

        var parser: Template.Parser = .{
            .gpa = gpa.allocator(),
            .callback_context = &cache,
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

            const source = try Template.Source.init_file(arena.allocator(), template_dir, entry.path);

            var path_buf: [std.fs.MAX_PATH_BYTES + 100]u8 = undefined;
            var path_buf_frag: [std.fs.MAX_PATH_BYTES + 100]u8 = undefined;
            const operands_name = try std.fmt.bufPrint(&path_buf, "{s}.operand", .{ entry.path });
            const opcodes_name = operands_name[0 .. operands_name.len - "erand".len];
            const base_path = operands_name[0 .. operands_name.len - ".operand".len];
            std.mem.replaceScalar(u8, operands_name, '\\', '/');
            @memcpy(&path_buf_frag, &path_buf);

            try parser.append(source);

            for (parser.fragments.keys(), parser.fragments.values()) |frag_name, frag_info| {
                const frag_suffix = try std.fmt.bufPrint(path_buf_frag[base_path.len..], "#{s}", .{ frag_name });
                const template_name = path_buf_frag[0 .. base_path.len + frag_suffix.len];
                if (frag_info.first_instruction + frag_info.instruction_count >= parser.instructions.len) {
                    try out.print("    pub const {}: Template = .{{ .opcodes = data.{}[{}..], .operands = data.{}[{}..].ptr, .literal_data = data.strings }};\n", .{
                        std.zig.fmtId(template_name),
                        std.zig.fmtId(opcodes_name),
                        frag_info.first_instruction,
                        std.zig.fmtId(operands_name),
                        frag_info.first_instruction,
                    });
                } else {
                    try out.print("    pub const {}: Template = .{{ .opcodes = data.{}[{}..{}], .operands = data.{}[{}..].ptr, .literal_data = data.strings }};\n", .{
                        std.zig.fmtId(template_name),
                        std.zig.fmtId(opcodes_name),
                        frag_info.first_instruction,
                        frag_info.first_instruction + frag_info.instruction_count,
                        std.zig.fmtId(operands_name),
                        frag_info.first_instruction,
                    });
                }
            }

            var template = try parser.finish(gpa.allocator(), false);
            defer template.deinit(gpa.allocator());

            try out.print("    pub const {}: Template = .{{ .opcodes = data.{}, .operands = data.{}.ptr, .literal_data = data.strings }};\n", .{
                std.zig.fmtId(base_path),
                std.zig.fmtId(opcodes_name),
                std.zig.fmtId(operands_name),
            });


            try tw.print("\n        pub const {}: []const Template.Opcode = @ptrCast(&[_]u8 {{", .{
                std.zig.fmtId(opcodes_name),
            });

            const opcodes_per_line = 32;

            var i: usize = opcodes_per_line;
            for (template.opcodes) |word| {
                if (i == opcodes_per_line) {
                    i = 0;
                    try tw.writeAll("\n            ");
                } else {
                    i += 1;
                    try tw.writeByte(' ');
                }
                try tw.print("{},", .{ @intFromEnum(word) });
            }

            try tw.print("\n        }});\n        pub const {}: []const Template.Operands = @ptrCast(&[_]u32 {{", .{
                std.zig.fmtId(operands_name),
            });

            const operands_per_line = 8;

            i = operands_per_line;
            for (template.operands[0..template.opcodes.len]) |word| {
                if (i == operands_per_line) {
                    i = 0;
                    try tw.writeAll("\n            ");
                } else {
                    i += 1;
                    try tw.writeByte(' ');
                }
                try tw.print("0x{X},", .{ @as(u32, @bitCast(word)) });
            }

            try tw.writeAll("\n        });\n");
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

        for (cache.files.values()) |file| {
            if (std.mem.indexOfScalar(u8, file.realpath, '#') == null) {
                try dw.print(" \"{s}\"", .{ file.realpath });
            }
        }
    }
}

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Resource_File = @import("Resource_File.zig");
const Template = @import("zkittle");
const std = @import("std");
