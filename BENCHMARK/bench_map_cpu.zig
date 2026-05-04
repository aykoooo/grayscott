const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const w: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 256;
    const h: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 256;
    const steps: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 500;

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

    // Uniform feed/kill arrays matching GPU periodic behavior
    const feed_row = try allocator.alloc(f32, h);
    defer allocator.free(feed_row);
    const kill_col = try allocator.alloc(f32, w);
    defer allocator.free(kill_col);
    @memset(feed_row, feed);
    @memset(kill_col, kill);

    var timer = try std.time.Timer.start();

    // Init grids (matching GPU init path)
    var grid = try GrayScottGrid.init(allocator, w, h);
    defer grid.deinit();
    var next = try GrayScottGrid.init(allocator, w, h);
    defer next.deinit();

    grid.fill(1.0, 0.0);

    // Seed matching GPU deterministic seed (RNG seed = 42)
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const num_seeds: usize = if (w * h > 10000) 20 else 5;
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, w - 5);
        const cy = rand.intRangeLessThan(usize, 5, h - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        grid.seedSquareAt(cx, cy, sz, 0.5, 1.0);
    }
    const init_ns = timer.read();

    // Run all steps
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        simulation.stepDeterministic(&grid, &next, da, db, dt, feed_row, kill_col);
        grid.swap(&next);
    }
    const after_step_ns = timer.read();

    const total_ns = timer.read();

    // Timing breakdown
    const init_s = @as(f64, @floatFromInt(init_ns)) / 1e9;
    const step_s = @as(f64, @floatFromInt(after_step_ns - init_ns)) / 1e9;
    const total_s = @as(f64, @floatFromInt(total_ns)) / 1e9;
    const total_cells: f64 = @as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps));

    // Hash the U grid
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.sliceAsBytes(grid.u));
    var hash_buf: [32]u8 = undefined;
    hasher.final(&hash_buf);
    var hash_str: [64]u8 = undefined;
    for (hash_buf, 0..) |byte, j| {
        _ = try std.fmt.bufPrint(hash_str[j * 2 ..][0..2], "{x:0>2}", .{byte});
    }

    std.debug.print(
        \\{{"cells_per_second":{d},"pipeline_cells_per_second":{d},
        \\"hash":"{s}","width":{d},"height":{d},"steps":{d},
        \\"init_ms":{d:.3},"step_ms":{d:.3},"total_ms":{d:.3}}}
        \\
    , .{
        @as(u64, @intFromFloat(total_cells / step_s)),
        @as(u64, @intFromFloat(total_cells / total_s)),
        hash_str[0..],
        w,
        h,
        steps,
        init_s * 1000.0,
        step_s * 1000.0,
        total_s * 1000.0,
    });
}
