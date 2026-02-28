const std = @import("std");

pub fn build(b: *std.Build) void {
    const ext = .{
        .Temp_Allocator = b.dependency("Temp_Allocator", .{}).module("Temp_Allocator"),
        .fmt = b.dependency("fmt_helper", .{}).module("fmt"),
        .tempora = b.dependency("tempora", .{}).module("tempora"),
        .dizzy = b.dependency("dizzy", .{}).module("dizzy"),
        .zkittle = b.dependency("zkittle", .{}).module("zkittle"),
        .percent_encoding = b.dependency("percent_encoding", .{}).module("percent_encoding"),
    };

    const http = b.addModule("http", .{
        .root_source_file = b.path("src/http.zig"),
        .imports = &.{
            .{ .name = "Temp_Allocator", .module = ext.Temp_Allocator },
            .{ .name = "fmt", .module = ext.fmt },
            .{ .name = "tempora", .module = ext.tempora },
            .{ .name = "dizzy", .module = ext.dizzy },
            .{ .name = "zkittle", .module = ext.zkittle },
            .{ .name = "percent_encoding", .module = ext.percent_encoding },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .optimize = b.standardOptimizeOption(.{}),
            .target = b.standardTargetOptions(.{}),
            .imports = &.{
                .{ .name = "http", .module = http },
            },
        }),
    });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
    b.installArtifact(tests);

    const citests = b.addTest(.{
        .root_source_file = b.path("ci_test.zig"),
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    });
    tests.root_module.addImport("http", http);
    b.step("citest", "Run all tests").dependOn(&b.addRunArtifact(citests).step);

    inline for ([_]std.builtin.OptimizeMode { .Debug, .ReleaseFast }) |mode| {
        const suffix = switch (mode) {
            .Debug => "_debug",
            .ReleaseFast => "",
            else => unreachable,
        };

        b.installArtifact(b.addExecutable(.{
            .name = "process_static_template" ++ suffix,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/process_static_template.zig"),
                .target = b.graph.host,
                .optimize = mode,
                .imports = &.{
                    .{ .name = "zkittle", .module = ext.zkittle },
                },
            }),
        }));

        b.installArtifact(b.addExecutable(.{
            .name = "hash_file" ++ suffix,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/hash_file.zig"),
                .target = b.graph.host,
                .optimize = mode,
            }),
        }));

        b.installArtifact(b.addExecutable(.{
            .name = "generate_res" ++ suffix,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/generate_res.zig"),
                .target = b.graph.host,
                .optimize = mode,
                .imports = &.{
                    .{ .name = "tempora", .module = ext.tempora },
                    .{ .name = "zkittle", .module = ext.zkittle },
                },
            }),
        }));
    }
}

pub const Resource_Path = struct {
    path: []const u8,
    ignored_extensions: []const[]const u8 = &.{ ".zig" },
    template_extensions: []const[]const u8 = &.{ ".htm", ".html", ".zk" },
    static_template_extensions: []const[]const u8 = &.{ ".css", ".szk" },
};
pub const Resource_Options = struct {
    shittip: ?*std.Build.Dependency = null,
    tempora: ?*std.Build.Module = null,
    zkittle: ?*std.Build.Module = null,
    debug: bool = false,
};

pub fn resources(b: *std.Build, paths: []const Resource_Path, options: Resource_Options) *std.Build.Module {
    var files: Resource_Files = .{
        .allocator = b.allocator,
    };

    for (paths) |path_options| {
        var dir = b.build_root.handle.createDirPathOpen(b.graph.io, path_options.path, .{ .open_options = .{ .iterate = true } }) catch |err| report_path_err(b.allocator, path_options.path, err);
        defer dir.close(b.graph.io);

        var iter = dir.walk(b.allocator) catch @panic("OOM");
        defer iter.deinit();

        while (iter.next(b.graph.io) catch |err| report_path_err(b.allocator, path_options.path, err)) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                files.maybe_add(entry.path, path_options);
            }
        }
    }

    const shittip = options.shittip orelse b.dependency("shittip", .{});
    const process_static_template_exe = shittip.artifact(if (options.debug) "process_static_template_debug" else "process_static_template");
    const hash_file_exe = shittip.artifact(if (options.debug) "hash_file_debug" else "hash_file");
    const generate_res_exe = shittip.artifact(if (options.debug) "generate_res_debug" else "generate_res");

    const metadata_dir = b.addWriteFiles();
    const templates_dir = b.addWriteFiles();

    for (files.template_files.items) |entry| {
        _ = templates_dir.addCopyFile(b.path(entry.base).path(b, entry.subpath), entry.subpath);
    }

    const module_dir = b.addWriteFiles();
    const generate_res = b.addRunArtifact(generate_res_exe);
    generate_res.addDirectoryArg(templates_dir.getDirectory());
    generate_res.addDirectoryArg(metadata_dir.getDirectory());
    const res_source = module_dir.addCopyFile(generate_res.addOutputFileArg("res.zig"), "res.zig");
    _ = module_dir.addCopyFile(generate_res.addOutputFileArg("template_string_data"), "template_string_data");
    _ = generate_res.addDepFileOutputArg("deps.d");
    for (paths) |path_options| {
        for (path_options.template_extensions) |ext| {
            generate_res.addArgs(&.{ "-t", ext });
        }
        for (path_options.static_template_extensions) |ext| {
            generate_res.addArgs(&.{ "-t", ext });
        }
        generate_res.addDirectoryArg(b.path(path_options.path));
    }

    var n: usize = 0;

    for (files.raw_files.items) |entry| {
        const compute_hash = b.addRunArtifact(hash_file_exe);
        compute_hash.addArg(entry.subpath);
        compute_hash.addFileArg(b.path(entry.base).path(b, entry.subpath));

        const f = b.fmt("f{}", .{ n });
        const h = b.fmt("h{}", .{ n });

        const compressed_out = compute_hash.addOutputFileArg(f);
        const hash_out = compute_hash.addOutputFileArg(h);

        _ = module_dir.addCopyFile(compressed_out, f);
        _ = metadata_dir.addCopyFile(hash_out, h);
        n += 1;
    }

    for (files.static_template_files.items) |entry| {
        const process = b.addRunArtifact(process_static_template_exe);
        process.addFileArg(b.path(entry.base).path(b, entry.subpath));
        const template_out = process.addOutputFileArg(std.Io.Dir.path.basename(entry.subpath));
        _ = process.addDepFileOutputArg("deps.d");
        for (paths) |path_options| {
            for (path_options.static_template_extensions) |ext| {
                process.addArgs(&.{ "-t", ext });
            }
            process.addDirectoryArg(b.path(path_options.path));
        }

        const compute_hash = b.addRunArtifact(hash_file_exe);
        compute_hash.addArg(entry.subpath);
        compute_hash.addFileArg(template_out);

        const f = b.fmt("f{}", .{ n });
        const h = b.fmt("h{}", .{ n });

        const compressed_out = compute_hash.addOutputFileArg(f);
        const hash_out = compute_hash.addOutputFileArg(h);

        _ = module_dir.addCopyFile(compressed_out, f);
        _ = metadata_dir.addCopyFile(hash_out, h);
        n += 1;
    }

    const res_module = b.createModule(.{ .root_source_file = res_source });
    res_module.addImport("tempora", options.tempora orelse b.dependency("tempora", .{}).module("tempora"));
    res_module.addImport("zkittle", options.zkittle orelse b.dependency("zkittle", .{}).module("zkittle"));

    return res_module;
}

const Resource_File = struct {
    base: []const u8,
    subpath: []const u8,
};

const Resource_Files = struct {
    allocator: std.mem.Allocator,
    raw_files: std.ArrayListUnmanaged(Resource_File) = .{},
    template_files: std.ArrayListUnmanaged(Resource_File) = .{},
    static_template_files: std.ArrayListUnmanaged(Resource_File) = .{},

    pub fn maybe_add(self: *Resource_Files, subpath: []const u8, options: Resource_Path) void {
        const owned_subpath = self.allocator.dupe(u8, subpath) catch @panic("OOM");
        const ext = std.Io.Dir.path.extension(owned_subpath);

        for (options.ignored_extensions) |ignored_ext| {
            if (std.mem.eql(u8, ignored_ext, ext)) return;
        }

        for (options.template_extensions) |template_ext| {
            if (std.mem.eql(u8, template_ext, ext)) {
                self.template_files.append(self.allocator, .{ .base = options.path, .subpath = owned_subpath }) catch @panic("OOM");
                return;
            }
        }

        for (options.static_template_extensions) |template_ext| {
            if (std.mem.eql(u8, template_ext, ext)) {
                self.static_template_files.append(self.allocator, .{ .base = options.path, .subpath = owned_subpath }) catch @panic("OOM");
                return;
            }
        }

        self.raw_files.append(self.allocator, .{ .base = options.path, .subpath = owned_subpath }) catch @panic("OOM");
    }
};

fn report_path_err(allocator: std.mem.Allocator, path: []const u8, err: anyerror) noreturn {
    @panic(std.fmt.allocPrint(allocator, "Failed to access path {s}: {s}", .{
        path,
        @errorName(err),
    }) catch "OOM");
}
