const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const divide_module = b.addModule("divide", .{
        .source_file = std.Build.FileSource.relative("divide.zig"),
    });

    const params: ExeParams = .{
        .target = target,
        .optimize = optimize,
        .divide_module = divide_module,
    };

    _ = build_exe(b, "test", "Run the tests", params);
    _ = build_exe(b, "bench", "Run benchmarks", params);
}

const ExeParams = struct {
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    divide_module: *std.Build.Module,
};

fn build_exe(
    b: *std.Build,
    comptime name: []const u8,
    comptime description: []const u8,
    params: ExeParams,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = "src/" ++ name ++ ".zig" },
        .target = params.target,
        .optimize = params.optimize,
    });
    exe.addModule("divide", params.divide_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);

    return exe;
}
