const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "memory-map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // NOTE: Link macOS system frameworks needed for Mach kernel APIs
    exe.linkFramework("CoreFoundation");
    exe.linkSystemLibrary("ncurses");
    exe.linkSystemLibrary("c");

    b.installArtifact(exe);

    const codesign = b.addSystemCommand(&.{
        "codesign",
        "--entitlements",
        "resources/entitlements.plist",
        "--force",
        "-s",
        "-",
    });
    codesign.addArtifactArg(exe);
    codesign.step.dependOn(b.getInstallStep());
    const sign_step = b.step("sign", "Codesign the binary with entitlements");
    sign_step.dependOn(&codesign.step);
}
