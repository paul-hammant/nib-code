const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No quickjs-libc: it would give scripts fs/net/process access.
    const qjs_dep = b.dependency("quickjs", .{});
    const qjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    qjs.root_module.addCSourceFiles(.{
        .root = qjs_dep.path(""),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
        .flags = &.{ "-D_GNU_SOURCE", "-funsigned-char", "-fwrapv", "-fno-sanitize=undefined" },
    });
    qjs.root_module.addIncludePath(qjs_dep.path(""));
    qjs.root_module.linkSystemLibrary("m", .{});

    const qjs_c = b.addTranslateC(.{
        .root_source_file = qjs_dep.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "qjs", .module = qjs_c.createModule() },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    mod.linkLibrary(qjs);

    const exe = b.addExecutable(.{ .name = "nib", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run nib").dependOn(&run_cmd.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run tests").dependOn(&tests.step);
}
