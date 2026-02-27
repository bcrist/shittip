pub fn build(b: *std.Build) void {
    const resources = shittip.resources(b, &.{
        .{ .path = "resources" },
    }, .{});

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .imports = &.{
                .{ .name = "http", .module = b.dependency("shittip", .{}).module("http") },
                .{ .name = "resources", .module = resources },
            },
        }),
    });
    b.installArtifact(exe);
    b.step("run", "run demo server").dependOn(&b.addRunArtifact(exe).step);
}

const shittip = @import("shittip");
const std = @import("std");
