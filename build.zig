const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c.h"),
    });
    translate_c.linkSystemLibrary("usb-1.0", .{});

    const pci_generator = b.addExecutable(.{
        .name = "pci_generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_generator = b.addRunArtifact(pci_generator);
    b.getInstallStep().dependOn(&run_generator.step);

    run_generator.addPrefixedFileArg("--input-file=", b.path("pci.ids"));
    const output = run_generator.addPrefixedOutputFileArg("--output-file=", "pci.zig");

    const exe = b.addExecutable(.{
        .name = "flux-pro-display",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = translate_c.createModule() },
                .{ .name = "pci", .module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = output,
                }) },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.linkSystemLibrary("usb-1.0", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
