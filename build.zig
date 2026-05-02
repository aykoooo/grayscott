const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // Shared source modules
    // ========================================================================
    const grid_mod = b.createModule(.{
        .root_source_file = b.path("src/grid.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sim_mod = b.createModule(.{
        .root_source_file = b.path("src/simulation.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("gray_scott_grid", grid_mod);

    // ========================================================================
    // WASM Build
    // ========================================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_mod.addImport("gray_scott_grid", grid_mod);
    wasm_mod.addImport("gray_scott_sim", sim_mod);

    const wasm = b.addExecutable(.{
        .name = "grayscott",
        .root_module = wasm_mod,
    });
    wasm.rdynamic = true;

    const wasm_step = b.step("wasm", "Build WASM module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // ========================================================================
    // Native CLI Build
    // ========================================================================
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("gray_scott_grid", grid_mod);
    cli_mod.addImport("gray_scott_sim", sim_mod);

    const map_mod = b.createModule(.{
        .root_source_file = b.path("src/map.zig"),
        .target = target,
        .optimize = optimize,
    });
    map_mod.addImport("gray_scott_grid", grid_mod);
    map_mod.addImport("gray_scott_sim", sim_mod);
    cli_mod.addImport("map_gen", map_mod);

    const cli = b.addExecutable(.{
        .name = "grayscott-cli",
        .root_module = cli_mod,
    });

    const cli_step = b.step("cli", "Build native CLI");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    const default_step = b.step("default", "Build both WASM and CLI");
    default_step.dependOn(wasm_step);
    default_step.dependOn(cli_step);

    // ========================================================================
    // Tests
    // ========================================================================
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/test_sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("gray_scott_grid", grid_mod);
    test_mod.addImport("gray_scott_sim", sim_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("test/bench_sim.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("gray_scott_grid", grid_mod);
    bench_mod.addImport("gray_scott_sim", sim_mod);

    const bench = b.addTest(.{
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
}
