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
    // WASM Builds
    // ========================================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wgsl_gen_mod = b.createModule(.{
        .root_source_file = b.path("src/wgsl_gen.zig"),
        .target = wasm_target,
        .optimize = optimize,
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

    const wasm_shader_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_shader.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_shader_mod.addImport("gray_scott_wgsl", wgsl_gen_mod);

    const wasm_shader = b.addExecutable(.{
        .name = "gray_scott_shader",
        .root_module = wasm_shader_mod,
    });
    wasm_shader.rdynamic = true;

    const wasm_shader_step = b.step("wasm-shader", "Build WASM WGSL shader export module");
    wasm_shader_step.dependOn(&b.addInstallArtifact(wasm_shader, .{}).step);

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
    gpu_bench_mod.linkSystemLibrary("wgpu_native", .{});

    const gpu_bench_run = b.addRunArtifact(gpu_bench_exe);
    const lib_path = b.pathJoin(&.{ b.build_root.path.?, "vendor", "wgpu-native", "lib" });
    const path_sep = if (builtin.os.tag == .windows) ";" else ":";
    const env_path = if (@hasDecl(std.process, "getEnvVarOwned"))
        std.process.getEnvVarOwned(b.allocator, "PATH") catch ""
    else blk: {
        const ptr = std.os.getenv("PATH") orelse @as([*:0]const u8, @ptrCast("."));
        break :blk b.allocator.dupe(u8, std.mem.sliceTo(ptr, 0)) catch @panic("OOM");
    };
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

    // f16 variant benchmarks
    var gpu_f16_256 = b.addRunArtifact(gpu_bench_exe);
    gpu_f16_256.addArgs(&.{ "--f16", "256", "256", "500" });
    gpu_f16_256.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-f16", "GPU f16 benchmark at 256^2, 500 steps").dependOn(&gpu_f16_256.step);

    var gpu_f16_512 = b.addRunArtifact(gpu_bench_exe);
    gpu_f16_512.addArgs(&.{ "--f16", "512", "512", "500" });
    gpu_f16_512.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-f16-512", "GPU f16 benchmark at 512^2, 500 steps").dependOn(&gpu_f16_512.step);

    var gpu_f16_1024 = b.addRunArtifact(gpu_bench_exe);
    gpu_f16_1024.addArgs(&.{ "--f16", "1024", "1024", "100" });
    gpu_f16_1024.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-f16-1024", "GPU f16 benchmark at 1024^2, 100 steps").dependOn(&gpu_f16_1024.step);

    // 16x16 tile benchmarks (Phase 18 diagnostic)
    var gpu_t16_256 = b.addRunArtifact(gpu_bench_exe);
    gpu_t16_256.addArgs(&.{ "--tile", "16", "16" });
    gpu_t16_256.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-t16", "GPU 16x16 tile at 256^2, 500 steps").dependOn(&gpu_t16_256.step);

    var gpu_t16_512 = b.addRunArtifact(gpu_bench_exe);
    gpu_t16_512.addArgs(&.{ "--tile", "16", "16", "512", "512", "500" });
    gpu_t16_512.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-t16-512", "GPU 16x16 tile at 512^2, 500 steps").dependOn(&gpu_t16_512.step);

    var gpu_t16_1024 = b.addRunArtifact(gpu_bench_exe);
    gpu_t16_1024.addArgs(&.{ "--tile", "16", "16", "1024", "1024", "100" });
    gpu_t16_1024.setEnvironmentVariable("PATH", new_path);
    b.step("bench-gpu-t16-1024", "GPU 16x16 tile at 1024^2, 100 steps").dependOn(&gpu_t16_1024.step);

    // ====================================================================
    // Map-Bench (end-to-end pipeline: init + seeded fill + steps + readback)
    // ====================================================================
    const map_bench_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_map.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    map_bench_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    map_bench_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    map_bench_mod.link_libc = true;
    map_bench_mod.addImport("gray_scott_gpu", gpu_mod);

    const map_bench_exe = b.addExecutable(.{
        .name = "bench-map",
        .root_module = map_bench_mod,
    });
    map_bench_mod.linkSystemLibrary("wgpu_native", .{});

    const map_bench_run = b.addRunArtifact(map_bench_exe);
    map_bench_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map", "Map-bench: full GPU pipeline (init+seed+steps+readback) at 256^2, 5000 steps").dependOn(&map_bench_run.step);

    var map_bench_512 = b.addRunArtifact(map_bench_exe);
    map_bench_512.addArgs(&.{ "512", "512", "5000" });
    map_bench_512.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map-512", "Map-bench at 512^2, 5000 steps").dependOn(&map_bench_512.step);

    var map_bench_1024 = b.addRunArtifact(map_bench_exe);
    map_bench_1024.addArgs(&.{ "1024", "1024", "1000" });
    map_bench_1024.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map-1024", "Map-bench at 1024^2, 1000 steps").dependOn(&map_bench_1024.step);

    // ====================================================================
    // Map-Bench CPU (for GPU vs CPU pipeline comparison)
    // ====================================================================
    const map_cpu_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_map_cpu.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    map_cpu_mod.addImport("gray_scott_grid", grid_mod);
    map_cpu_mod.addImport("gray_scott_sim", sim_mod);

    const map_cpu_exe = b.addExecutable(.{
        .name = "bench-map-cpu",
        .root_module = map_cpu_mod,
    });

    const map_cpu_run = b.addRunArtifact(map_cpu_exe);
    b.step("bench-map-cpu", "CPU map-bench: full pipeline at 256^2, 500 steps (GPU-comparable)").dependOn(&map_cpu_run.step);

    var map_cpu_5000 = b.addRunArtifact(map_cpu_exe);
    map_cpu_5000.addArgs(&.{ "256", "256", "5000" });
    b.step("bench-map-cpu-5k", "CPU map-bench at 256^2, 5000 steps").dependOn(&map_cpu_5000.step);

    var map_cpu_512 = b.addRunArtifact(map_cpu_exe);
    map_cpu_512.addArgs(&.{ "512", "512", "500" });
    b.step("bench-map-cpu-512", "CPU map-bench at 512^2, 500 steps").dependOn(&map_cpu_512.step);

    var map_cpu_512_5k = b.addRunArtifact(map_cpu_exe);
    map_cpu_512_5k.addArgs(&.{ "512", "512", "5000" });
    b.step("bench-map-cpu-512-5k", "CPU map-bench at 512^2, 5000 steps").dependOn(&map_cpu_512_5k.step);

    var map_cpu_1024 = b.addRunArtifact(map_cpu_exe);
    map_cpu_1024.addArgs(&.{ "1024", "1024", "100" });
    b.step("bench-map-cpu-1024", "CPU map-bench at 1024^2, 100 steps").dependOn(&map_cpu_1024.step);

    // ====================================================================
    // Pearson Map (GPU Neumann + spatial f/k gradient → PGM output)
    // ====================================================================
    const pearson_mod = b.createModule(.{
        .root_source_file = b.path("BENCHMARK/bench_map_pearson.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    pearson_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    pearson_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    pearson_mod.link_libc = true;
    pearson_mod.addImport("gray_scott_gpu", gpu_mod);

    const pearson_exe = b.addExecutable(.{
        .name = "bench-map-pearson",
        .root_module = pearson_mod,
    });
    pearson_mod.linkSystemLibrary("wgpu_native", .{});

    const pearson_run = b.addRunArtifact(pearson_exe);
    pearson_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map-pearson", "GPU Pearson map: spatial f/k gradient, Neumann boundaries, PGM output (default 1024^2, 50000 iters)").dependOn(&pearson_run.step);

    var pearson_2048 = b.addRunArtifact(pearson_exe);
    pearson_2048.addArgs(&.{ "2048", "2048", "50000" });
    pearson_2048.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map-pearson-2k", "GPU Pearson map at 2048^2, 50000 iters").dependOn(&pearson_2048.step);

    var pearson_4096 = b.addRunArtifact(pearson_exe);
    pearson_4096.addArgs(&.{ "4096", "4096", "50000" });
    pearson_4096.setEnvironmentVariable("PATH", new_path);
    b.step("bench-map-pearson-4k", "GPU Pearson map at 4096^2, 50000 iters").dependOn(&pearson_4096.step);

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
    debug_mod.linkSystemLibrary("wgpu_native", .{});
    const debug_run = b.addRunArtifact(debug_exe);
    b.step("debug-compare", "Compare CPU vs GPU first step").dependOn(&debug_run.step);

    const bench_ph_mod = b.createModule(.{ .root_source_file = b.path("BENCHMARK/bench_phase_b.zig"), .target = target, .optimize = .ReleaseFast });
    bench_ph_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    bench_ph_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    bench_ph_mod.link_libc = true;
    bench_ph_mod.addImport("gray_scott_gpu", gpu_mod);
    const bench_ph_exe = b.addExecutable(.{ .name = "bench-phase-b", .root_module = bench_ph_mod });
    bench_ph_mod.linkSystemLibrary("wgpu_native", .{});
    var bench_ph_run = b.addRunArtifact(bench_ph_exe);
    bench_ph_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-phase-b", "Phase B: interleaved + early-sum instruction scheduling").dependOn(&bench_ph_run.step);

    const bench_all_mod = b.createModule(.{ .root_source_file = b.path("BENCHMARK/bench_all_variants.zig"), .target = target, .optimize = .ReleaseFast });
    bench_all_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    bench_all_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    bench_all_mod.link_libc = true;
    bench_all_mod.addImport("gray_scott_gpu", gpu_mod);
    const bench_all_exe = b.addExecutable(.{ .name = "bench-all", .root_module = bench_all_mod });
    bench_all_mod.linkSystemLibrary("wgpu_native", .{});
    var bench_all_run = b.addRunArtifact(bench_all_exe);
    bench_all_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-all", "All variants sweep: baseline/FMA/interleaved/earlysum/5point (same-process)").dependOn(&bench_all_run.step);

    const loop_parse_mod = b.createModule(.{
        .root_source_file = b.path("src/loop_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const loop_parse_tests = b.addTest(.{
        .root_module = loop_parse_mod,
    });
    const run_loop_parse_tests = b.addRunArtifact(loop_parse_tests);
    b.step("test-loop-parse", "Run loop parser tests").dependOn(&run_loop_parse_tests.step);

    const bench_shape_mod = b.createModule(.{ .root_source_file = b.path("BENCHMARK/bench_shape_sweep.zig"), .target = target, .optimize = .ReleaseFast });
    bench_shape_mod.addIncludePath(b.path("vendor/wgpu-native/include"));
    bench_shape_mod.addLibraryPath(b.path("vendor/wgpu-native/lib"));
    bench_shape_mod.link_libc = true;
    bench_shape_mod.addImport("gray_scott_gpu", gpu_mod);
    const bench_shape_exe = b.addExecutable(.{ .name = "bench-shape-sweep", .root_module = bench_shape_mod });
    bench_shape_mod.linkSystemLibrary("wgpu_native", .{});
    var bench_shape_run = b.addRunArtifact(bench_shape_exe);
    bench_shape_run.setEnvironmentVariable("PATH", new_path);
    b.step("bench-shape-sweep", "Workgroup shape sweep: 16x4, 8x8, 16x8, 4x16, 32x2 at 128/256/512^2").dependOn(&bench_shape_run.step);
}
