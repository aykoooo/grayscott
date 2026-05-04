const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const w: u32 = 128;
    const h: u32 = 128;
    const steps: u32 = 200;
    const seed: u64 = 42;
    const num_seeds: usize = 5;

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

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

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 3, w - 3);
        const cy = rand.intRangeLessThan(usize, 3, h - 3);
        const sz: usize = 3;
        grid.seedSquareAt(@intCast(cx), @intCast(cy), @intCast(sz), 0.5, 1.0);
    }

    var timer = try std.time.Timer.start();
    var iter: u32 = 0;
    while (iter < steps) : (iter += 1) {
        simulation.stepDeterministic(&grid, &next, da, db, dt, feed_row, kill_col);
        grid.swap(&next);
    }
    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const total_cells: f64 = @as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps));
    const cells_per_second: u64 = @intFromFloat(total_cells / elapsed_s);

    std.debug.print(
        \\{{"cells_per_second":{d},"width":{d},"height":{d},"steps":{d}}}
        \\
    , .{
        cells_per_second, w, h, steps,
    });
}
