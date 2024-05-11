const std = @import("std");

pub fn build(b: *std.Build) void {
    const ext = .{
        .Temp_Allocator = b.dependency("Zig-TempAllocator", .{}).module("Temp_Allocator"),
        .tempora = b.dependency("tempora", .{}).module("tempora"),
        .dizzy = b.dependency("dizzy", .{}).module("dizzy"),
        .zkittle = b.dependency("zkittle", .{}).module("zkittle"),
    };

    const http = b.addModule("http", .{
        .root_source_file = .{ .path = "src/http.zig" },
    });
    http.addImport("Temp_Allocator", ext.Temp_Allocator);
    http.addImport("tempora", ext.tempora);
    http.addImport("dizzy", ext.dizzy);
    http.addImport("zkittle", ext.zkittle);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test.zig"},
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    });
    tests.root_module.addImport("http", http);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    const index_resources_exe = b.addExecutable(.{
        .name = "index_resources",
        .root_source_file = .{ .path = "src/index_resources.zig" },
        .target = b.host,
        .optimize = .ReleaseFast,
    });
    index_resources_exe.root_module.addImport("tempora", ext.tempora);
    index_resources_exe.root_module.addImport("zkittle", ext.zkittle);
    b.installArtifact(index_resources_exe);
}

pub const Resources_Options = struct {
    root_path: std.Build.LazyPath,
    ignored_extensions: []const[]const u8 = &.{ ".zig" },
    template_extensions: []const[]const u8 = &.{ ".htm", ".html", ".zk" },
    static_template_extensions: []const[]const u8 = &.{ ".css", ".szk" },
    shittip: ?*std.Build.Dependency = null,
    tempora: ?*std.Build.Module = null,
    zkittle: ?*std.Build.Module = null,
};
pub fn resources(b: *std.Build, options: Resources_Options) *std.Build.Module {
    const self = options.shittip orelse b.dependency("shittip", .{});
    const exe = self.artifact("index_resources");

    var index_resources = b.addRunArtifact(exe);

    index_resources.addArg("-s");
    index_resources.addDirectoryArg(options.root_path);

    index_resources.addArg("-o");
    const res_source = index_resources.addOutputFileArg("res.zig");

    index_resources.addArg("-D");
    _ = index_resources.addDepFileOutputArg("res.zig.d");

    for (options.ignored_extensions) |ext| {
        index_resources.addArgs(&.{ "-i", ext });
    }

    for (options.template_extensions) |ext| {
        index_resources.addArgs(&.{ "-t", ext });
    }

    for (options.static_template_extensions) |ext| {
        index_resources.addArgs(&.{ "-s", ext });
    }

    const res_module = b.createModule(.{ .root_source_file = res_source });
    res_module.addImport("tempora", options.tempora orelse b.dependency("tempora", .{}).module("tempora"));
    res_module.addImport("zkittle", options.zkittle orelse b.dependency("zkittle", .{}).module("zkittle"));

    return res_module;
}
