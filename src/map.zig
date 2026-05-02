const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

const DA: f32 = 1.0;
const DB: f32 = 0.5;
const DT: f32 = 1.0;

pub fn generateMap(
    allocator: std.mem.Allocator,
    w: u32,
    h: u32,
    iterations: u32,
    f_min: f32,
    f_max: f32,
    k_min: f32,
    k_max: f32,
    output_path: []const u8,
) !void {
    const wf = @as(f32, @floatFromInt(w));
    const hf = @as(f32, @floatFromInt(h));

    std.debug.print("Generating {d}x{d} Pearson map\n", .{ w, h });
    std.debug.print("  Feed: {d:.4}->{d:.4} (Y)  Kill: {d:.4}->{d:.4} (X)  Iters: {d}\n", .{ f_min, f_max, k_min, k_max, iterations });

    const feed_row = try allocator.alloc(f32, h);
    defer allocator.free(feed_row);
    const kill_col = try allocator.alloc(f32, w);
    defer allocator.free(kill_col);

    var i: u32 = 0;
    while (i < h) : (i += 1) {
        feed_row[i] = f_min + (@as(f32, @floatFromInt(i)) / hf) * (f_max - f_min);
    }
    i = 0;
    while (i < w) : (i += 1) {
        kill_col[i] = k_min + (@as(f32, @floatFromInt(i)) / wf) * (k_max - k_min);
    }

    var grid = try GrayScottGrid.init(allocator, w, h);
    defer grid.deinit();
    var next = try GrayScottGrid.init(allocator, w, h);
    defer next.deinit();

    grid.fill(1.0, 0.0);

    // Random seed spots per Karl Sims spec: B=1 in small regions
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand = prng.random();
    const num_seeds: usize = (w *| h) / 500; // scale with grid area
    const actual_seeds = @min(num_seeds, 800);

    var s: usize = 0;
    while (s < actual_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, w - 5);
        const cy = rand.intRangeLessThan(usize, 5, h - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        grid.seedSquareAt(cx, cy, sz, 0.5, 1.0);
    }

    // Run with Neumann boundaries (no periodic wrap)
    const t0 = std.time.milliTimestamp();
    var iter: u32 = 0;
    const chk: u32 = if (iterations <= 5000) 1000 else 5000;

    while (iter < iterations) : (iter += 1) {
        simulation.stepNeumann(&grid, &next, DA, DB, DT, feed_row, kill_col);
        grid.swap(&next);

        if (iter > 0 and iter % chk == 0) {
            const t = std.time.milliTimestamp() - t0;
            const rate: f32 = @as(f32, @floatFromInt(iter)) / (@as(f32, @floatFromInt(t)) / 1000.0);
            const remain = iterations - iter;
            const eta = if (rate > 0) @as(i64, @intFromFloat(@as(f32, @floatFromInt(remain)) / rate)) else 0;
            std.debug.print("  Iter {d}/{d} | {d}s | {d:.0}/s | ETA {d}s = {d}m\n", .{
                iter,           iterations,
                @divTrunc(t,    1000),
                rate,
                eta,            @divTrunc(eta, 60),
            });
        }
    }

    const t = std.time.milliTimestamp() - t0;
    const rate: f32 = if (t > 0) @as(f32, @floatFromInt(iterations)) / (@as(f32, @floatFromInt(t)) / 1000.0) else 0;
    std.debug.print("Sim done: {}s ({}/s)\n", .{ @divTrunc(t, 1000), @as(i64, @intFromFloat(rate)) });

    // Write PGM (v channel = grayscale)
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try file.writeAll("P5\n");
    try file.writeAll(try std.fmt.allocPrint(allocator, "{d} {d}\n", .{ w, h }));
    try file.writeAll("255\n");

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const si = y * w + x;
            const val = @as(u8, @intFromFloat(@min(@max(grid.v[si], 0.0), 1.0) * 255.0));
            try file.writeAll(&.{val});
        }
    }

    std.debug.print("Saved: {s}\n", .{output_path});
}
