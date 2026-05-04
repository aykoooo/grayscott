const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

fn benchmarkStep(comptime name: []const u8, grid_size: usize, iterations: u32) void {
    const allocator = std.testing.allocator;

    var grid = GrayScottGrid.init(allocator, grid_size, grid_size) catch return;
    defer grid.deinit();
    var next = GrayScottGrid.init(allocator, grid_size, grid_size) catch return;
    defer next.deinit();

    const feed_row = allocator.alloc(f32, grid_size) catch return;
    defer allocator.free(feed_row);
    const kill_col = allocator.alloc(f32, grid_size) catch return;
    defer allocator.free(kill_col);
    @memset(feed_row, 0.0545);
    @memset(kill_col, 0.0620);

    grid.fill(1.0, 0.0);
    grid.seedSquare(10, 0.5, 1.0);

    simulation.stepDeterministic(&grid, &next, 1.0, 0.5, 1.0, feed_row, kill_col);
    grid.swap(&next);

    const t0 = std.time.milliTimestamp();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        simulation.stepDeterministic(&grid, &next, 1.0, 0.5, 1.0, feed_row, kill_col);
        grid.swap(&next);
    }
    const elapsed_ms = std.time.milliTimestamp() - t0;

    const ms_per_iter = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(iterations));
    const cells_per_sec = if (elapsed_ms > 0)
        (@as(f64, @floatFromInt(grid_size * grid_size)) * @as(f64, @floatFromInt(iterations))) /
            (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)
    else
        0;

    std.debug.print("{s}: {d:.3} ms/step, {d:.2}M cells/sec\n", .{ name, ms_per_iter, cells_per_sec / 1e6 });
}

test "benchmark_scalar_64" {
    benchmarkStep("Scalar 64x64", 64, 1000);
}
test "benchmark_scalar_128" {
    benchmarkStep("Scalar 128x128", 128, 500);
}
test "benchmark_scalar_256" {
    benchmarkStep("Scalar 256x256", 256, 200);
}
test "benchmark_scalar_512" {
    benchmarkStep("Scalar 512x512", 512, 100);
}
