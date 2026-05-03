const std = @import("std");
const gpu = @import("gray_scott_gpu");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const w: u32 = 256;
    const h: u32 = 256;
    const steps: u32 = 1;

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

    // ========== CPU init ==========
    const feed_row = try allocator.alloc(f32, h);
    defer allocator.free(feed_row);
    @memset(feed_row, feed);
    const kill_col = try allocator.alloc(f32, w);
    defer allocator.free(kill_col);
    @memset(kill_col, kill);

    var grid = try GrayScottGrid.init(allocator, w, h);
    defer grid.deinit();
    var next = try GrayScottGrid.init(allocator, w, h);
    defer next.deinit();
    grid.fill(1.0, 0.0);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const num_seeds: usize = if (w * h > 10000) 20 else 5;
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, w - 5);
        const cy = rand.intRangeLessThan(usize, 5, h - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        grid.seedSquareAt(@intCast(cx), @intCast(cy), @intCast(sz), 0.5, 1.0);
    }

    // Run CPU step(s)
    var iter: u32 = 0;
    while (iter < steps) : (iter += 1) {
        simulation.stepDeterministic(&grid, &next, da, db, dt, feed_row, kill_col);
        grid.swap(&next);
    }

    // ========== GPU init ==========
    if (!gpu.gs_gpu_init(w, h)) {
        std.debug.print("GPU init failed\n", .{});
        return error.GpuInitFailed;
    }
    defer gpu.gs_gpu_free();

    iter = 0;
    while (iter < steps) : (iter += 1) {
        gpu.gs_gpu_step(da, db, dt, feed, kill);
    }

    const grid_bytes = w * h * @sizeOf(f32);
    const u_gpu = try allocator.alloc(u8, grid_bytes);
    defer allocator.free(u_gpu);
    const read_bytes = gpu.gs_gpu_read_result(u_gpu.ptr, u_gpu.len);
    if (read_bytes != grid_bytes) {
        std.debug.print("GPU readback failed\n", .{});
        return error.GpuReadFailed;
    }
    const gpu_f32 = @as([*]const f32, @ptrCast(@alignCast(u_gpu.ptr)))[0 .. w * h];

    // Compare first 20 cells
    std.debug.print("Comparing first 20 cells after {d} step(s):\n", .{steps});
    for (0..20) |i| {
        const diff = @abs(grid.u[i] - gpu_f32[i]);
        if (diff > 1e-6) {
            std.debug.print("  idx {d}: CPU={e}, GPU={e}, diff={e} ***\n", .{ i, grid.u[i], gpu_f32[i], diff });
        } else {
            std.debug.print("  idx {d}: CPU={e}, GPU={e}, diff={e}\n", .{ i, grid.u[i], gpu_f32[i], diff });
        }
    }

    // Min/max
    var cpu_min = grid.u[0];
    var cpu_max = grid.u[0];
    for (grid.u) |v| { cpu_min = @min(cpu_min, v); cpu_max = @max(cpu_max, v); }
    var gpu_min = gpu_f32[0];
    var gpu_max = gpu_f32[0];
    for (gpu_f32) |v| { gpu_min = @min(gpu_min, v); gpu_max = @max(gpu_max, v); }
    std.debug.print("CPU U min={e}, max={e}\n", .{cpu_min, cpu_max});
    std.debug.print("GPU U min={e}, max={e}\n", .{gpu_min, gpu_max});

    // Hash comparison
    var cpu_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    cpu_hasher.update(@as([*]const u8, @ptrCast(grid.u.ptr))[0..grid_bytes]);
    var cpu_hash: [32]u8 = undefined;
    cpu_hasher.final(&cpu_hash);
    var gpu_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    gpu_hasher.update(u_gpu);
    var gpu_hash: [32]u8 = undefined;
    gpu_hasher.final(&gpu_hash);
    std.debug.print("CPU hash: ", .{});
    for (cpu_hash) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\nGPU hash: ", .{});
    for (gpu_hash) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    // Scan ALL cells for differences
    var diff_count: usize = 0;
    var first_diff_idx: usize = 0;
    var first_diff_val_cpu: f32 = 0;
    var first_diff_val_gpu: f32 = 0;
    for (0..grid.u.len) |i| {
        if (@abs(grid.u[i] - gpu_f32[i]) > 1e-9) {
            if (diff_count == 0) {
                first_diff_idx = i;
                first_diff_val_cpu = grid.u[i];
                first_diff_val_gpu = gpu_f32[i];
            }
            diff_count += 1;
        }
    }
    std.debug.print("Total differing cells: {d}\n", .{diff_count});
    if (diff_count > 0) {
        std.debug.print("First diff at idx {d}: CPU={e}, GPU={e}\n", .{first_diff_idx, first_diff_val_cpu, first_diff_val_gpu});
    }
}
