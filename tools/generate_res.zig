/// usage:
///    generate_res <templates_dir> <metadata_dir> <output_file> <template_string_data_output_file> <depfile_path> [[-t <extension>]... <search_path>]...

pub fn main(init: std.process.Init) !void {
    var stderr_buf: [64]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    var cache: Resource_File.Cache = .{
        .arena = init.arena.allocator(),
        .gpa = init.gpa,
        .io = init.io,
        .diagnostic_writer = &stderr.interface,
    };
    defer cache.deinit();

    var arg_iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // exe name
    const template_dir_path = arg_iter.next() orelse return error.ExpectedTemplateDir;
    const metadata_dir_path = arg_iter.next() orelse return error.ExpectedMetadataDir;
    const out_path = arg_iter.next() orelse return error.ExpectedOutputPath;
    const template_string_data_out_path = arg_iter.next() orelse return error.ExpectedTemplateStringDataOutputPath;
    const depfile_path = arg_iter.next() orelse return error.ExpectedDepfilePath;

    var template_extensions: std.ArrayList([]const u8) = .empty;
    defer template_extensions.deinit(init.gpa);

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            const ext = arg_iter.next() orelse return error.ExpectedTemplateExtension;
            try template_extensions.append(init.gpa, ext);
        } else {
            try cache.add_dir(arg, template_extensions.items);
            template_extensions.clearRetainingCapacity();
        }
    }

    const out_file = try std.Io.Dir.cwd().createFile(init.io, out_path, .{});
    defer out_file.close(init.io);

    var out_buf: [8192]u8 = undefined;
    var out_writer = out_file.writer(init.io, &out_buf);
    var out = &out_writer.interface;

    var temp: std.ArrayList(u8) = .empty;
    defer temp.deinit(init.gpa);

    { // Templates
        try out.print(
            \\const tempora = @import("tempora");
            \\const Template = @import("zkittle");
            \\
            \\pub const build_time = tempora.Date_Time.With_Offset.from_timestamp_s({}, null).dt;
            \\
            \\pub const templates = struct {{
            \\
            , .{ std.Io.Clock.real.now(init.io).toSeconds() });

        var parser: Template.Parser = .{
            .gpa = init.gpa,
            .callback_context = &cache,
            .include_callback = Resource_File.template_include,
            .resource_callback = Resource_File.template_resource,
            .diagnostic_writer = &stderr.interface,
        };
        defer parser.deinit();

        var temp_writer = std.Io.Writer.Allocating.fromArrayList(init.gpa, &temp);
        const tw = &temp_writer.writer;
        
        var template_dir = try std.Io.Dir.cwd().openDir(init.io, template_dir_path, .{ .iterate = true });
        defer template_dir.close(init.io);

        var walker = try template_dir.walk(init.gpa);
        defer walker.deinit();

        while (try walker.next(init.io)) |entry| {
            if (entry.kind != .file) continue;

            const source = try Template.Source.init_file(init.arena.allocator(), init.io, template_dir, entry.path);

            var path_buf: [std.Io.Dir.max_path_bytes + 100]u8 = undefined;
            var path_buf_frag: [std.Io.Dir.max_path_bytes + 100]u8 = undefined;
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
                    try out.print("    pub const {f}: Template = .{{ .opcodes = data.{f}[{d}..], .operands = data.{f}[{d}..].ptr, .literal_data = data.strings }};\n", .{
                        std.zig.fmtId(template_name),
                        std.zig.fmtId(opcodes_name),
                        frag_info.first_instruction,
                        std.zig.fmtId(operands_name),
                        frag_info.first_instruction,
                    });
                } else {
                    try out.print("    pub const {f}: Template = .{{ .opcodes = data.{f}[{d}..{d}], .operands = data.{f}[{d}..].ptr, .literal_data = data.strings }};\n", .{
                        std.zig.fmtId(template_name),
                        std.zig.fmtId(opcodes_name),
                        frag_info.first_instruction,
                        frag_info.first_instruction + frag_info.instruction_count,
                        std.zig.fmtId(operands_name),
                        frag_info.first_instruction,
                    });
                }
            }

            var template = try parser.finish(init.gpa, false);
            defer template.deinit(init.gpa);

            try out.print("    pub const {f}: Template = .{{ .opcodes = data.{f}, .operands = data.{f}.ptr, .literal_data = data.strings }};\n", .{
                std.zig.fmtId(base_path),
                std.zig.fmtId(opcodes_name),
                std.zig.fmtId(operands_name),
            });


            try tw.print("\n        pub const {f}: []const Template.Opcode = @ptrCast(&[_]u8 {{", .{
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

            try tw.print("\n        }});\n        pub const {f}: []const Template.Operands = @ptrCast(&[_]u32 {{", .{
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
        try out.writeAll(temp_writer.written());
        try out.writeAll(
            \\    };
            \\};
            \\
            \\
        );

        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = template_string_data_out_path,
            .data = parser.literal_data.items,
        });

        temp = temp_writer.toArrayList();
    }

    temp.clearRetainingCapacity();

    { // Hashed resources
        var hash_dedup: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer hash_dedup.deinit(init.gpa);

        var metadata_dir = try std.Io.Dir.cwd().openDir(init.io, metadata_dir_path, .{ .iterate = true });
        defer metadata_dir.close(init.io);

        var walker = try metadata_dir.walk(init.gpa);
        defer walker.deinit();

        var temp_writer = std.Io.Writer.Allocating.fromArrayList(init.gpa, &temp);
        const tw = &temp_writer.writer;

        while (try walker.next(init.io)) |entry| {
            if (entry.kind != .file) continue;

            const f = try metadata_dir.openFile(init.io, entry.path, .{});
            defer f.close(init.io);

            var buf: [16384]u8 = undefined;
            var reader = f.reader(init.io, &buf);
            const r = &reader.interface;

            var unix_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var unix_path_writer = std.Io.Writer.fixed(&unix_path_buf);
            _ = try r.streamDelimiter(&unix_path_writer, '\n');
            const unix_path = unix_path_writer.buffered();
            std.mem.replaceScalar(u8, unix_path, '\\', '/');
            r.toss(1); // \n

            var compressed_file_path_buf: [256]u8 = undefined;
            var compressed_file_path_writer = std.Io.Writer.fixed(&compressed_file_path_buf);
            _ = try r.streamDelimiter(&compressed_file_path_writer, '\n');
            r.toss(1); // \n

            var hash_buf: [@sizeOf(Resource_File.Digest) * 2]u8 = undefined;
            var hash_writer = std.Io.Writer.fixed(&hash_buf);
            _ = try r.streamDelimiter(&hash_writer, '\n');
            r.toss(1); // \n

            const gop = try hash_dedup.getOrPut(init.gpa, hash_writer.buffered());
            if (gop.found_existing) {
                try tw.print("    pub const {f} = content.{f};\n", .{
                    std.zig.fmtId(unix_path),
                    std.zig.fmtId(gop.value_ptr.*),
                });
            } else {
                gop.key_ptr.* = try init.arena.allocator().dupe(u8, hash_writer.buffered());
                gop.value_ptr.* = try init.arena.allocator().dupe(u8, unix_path);

                try tw.print("    pub const {f} = @embedFile(\"{f}\");\n", .{
                    std.zig.fmtId(unix_path),
                    std.zig.fmtString(compressed_file_path_writer.buffered()),
                });
            }

            try out.print("pub const {f} = \"{s}\";\n", .{
                std.zig.fmtId(unix_path),
                hash_writer.buffered(),
            });
        }

        try out.writeAll(
            \\
            \\/// zlib compressed resource content
            \\pub const content = struct {
            \\
        );
        try out.writeAll(temp_writer.written());
        try out.writeAll("};\n");

        temp = temp_writer.toArrayList();
    }

    { // Depfile
        const depfile = try std.Io.Dir.cwd().createFile(init.io, depfile_path, .{});
        defer depfile.close(init.io);

        var buf: [8192]u8 = undefined;
        var depfile_writer = depfile.writer(init.io, &buf);
        const dw = &depfile_writer.interface;

        try dw.print("\"{s}\":", .{ out_path });

        for (cache.files.values()) |file| {
            if (std.mem.indexOfScalar(u8, file.realpath, '#') == null) {
                try dw.print(" \"{s}\"", .{ file.realpath });
            }
        }

        try dw.flush();
    }

    try out.flush();

    try stderr.interface.flush();
}

const Resource_File = @import("Resource_File.zig");
const Template = @import("zkittle");
const std = @import("std");
