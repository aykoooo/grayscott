const std = @import("std");

pub fn build(b: *std.Build) void {
    const builtin = @import("builtin");
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

    // ========================================================================
    // Correctness Benchmark (for GPU verification)
    // ========================================================================
    const verify_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    verify_mod.addImport("gray_scott_grid", grid_mod);
    verify_mod.addImport("gray_scott_sim", sim_mod);

    const verify_exe = b.addExecutable(.{
        .name = "verify",
        .root_module = verify_mod,
    });
    const verify_run = b.addRunArtifact(verify_exe);
    b.step("verify", "Run correctness benchmark (256^2, 500 steps)").dependOn(&verify_run.step);

    // Scale validation benchmarks
    const bench128_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_128.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench128_mod.addImport("gray_scott_grid", grid_mod);
    bench128_mod.addImport("gray_scott_sim", sim_mod);

    const bench128_exe = b.addExecutable(.{ .name = "verify-128", .root_module = bench128_mod });
    const bench128_run = b.addRunArtifact(bench128_exe);
    b.step("verify-128", "Scale check: 128^2, 200 steps").dependOn(&bench128_run.step);

    const bench512_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_512.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench512_mod.addImport("gray_scott_grid", grid_mod);
    bench512_mod.addImport("gray_scott_sim", sim_mod);

    const bench512_exe = b.addExecutable(.{ .name = "verify-512", .root_module = bench512_mod });
    const bench512_run = b.addRunArtifact(bench512_exe);
    b.step("verify-512", "Scale check: 512^2, 100 steps").dependOn(&bench512_run.step);

    // ========================================================================
    // GPU Benchmark (native WebGPU via wgpu-native)
    // ========================================================================
    const gpu_bench_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_gpu.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    gpu_bench_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    gpu_bench_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    gpu_bench_mod.link_libc = true;

    const gpu_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu/gpu.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    gpu_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    gpu_bench_mod.addImport("gray_scott_gpu", gpu_mod);

    const gpu_bench_exe = b.addExecutable(.{
        .name = "bench-gpu",
        .root_module = gpu_bench_mod,
    });
    gpu_bench_exe.linkSystemLibrary("wgpu_native");

    const gpu_bench_run = b.addRunArtifact(gpu_bench_exe);
    const lib_path = b.pathJoin(&.{ b.build_root.path.?, "vendor", "wgpu-native", "lib" });
    const path_sep = if (builtin.os.tag == .windows) ";" else ":";
    const env_path = std.process.getEnvVarOwned(b.allocator, "PATH") catch "";
    defer b.allocator.free(env_path);
    const new_path = b.fmt("{s}{s}{s}", .{ env_path, path_sep, lib_path });
    gpu_bench_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu", "Run GPU benchmark (256^2, 500 steps)").dependOn(&gpu_bench_run.step);

    var gpu_bench_512 = b.addRunArtifact(gpu_bench_exe);
    gpu_bench_512.addArgs(&.{ "512", "512", "500" });
    gpu_bench_512.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-512", "GPU benchmark at 512^2, 500 steps").dependOn(&gpu_bench_512.step);

    var gpu_bench_1024 = b.addRunArtifact(gpu_bench_exe);
    gpu_bench_1024.addArgs(&.{ "1024", "1024", "100" });
    gpu_bench_1024.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-1024", "GPU benchmark at 1024^2, 100 steps").dependOn(&gpu_bench_1024.step);

    // Debug compare target
    const debug_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/debug_compare.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mod.addImport("gray_scott_gpu", gpu_mod);
    debug_mod.addImport("gray_scott_grid", grid_mod);
    debug_mod.addImport("gray_scott_sim", sim_mod);
    debug_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    debug_mod.link_libc = true;

    const debug_exe = b.addExecutable(.{
        .name = "debug-compare",
        .root_module = debug_mod,
    });
    debug_exe.linkSystemLibrary("wgpu_native");
    const debug_run = b.addRunArtifact(debug_exe);
    b.step("debug-compare", "Compare CPU vs GPU first step").dependOn(&debug_run.step);
}
