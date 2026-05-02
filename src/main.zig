const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");
const map_gen = @import("map_gen");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "map")) {
        const width_arg = args.next() orelse "1024";
        const height_arg = args.next() orelse "1024";
        const iterations_arg = args.next() orelse "50000";

        const f_min_arg = args.next() orelse "0.01";
        const f_max_arg = args.next() orelse "0.10";
        const k_min_arg = args.next() orelse "0.045";
        const k_max_arg = args.next() orelse "0.07";

        const output = args.next() orelse "map.pgm";

        const width = std.fmt.parseInt(u32, width_arg, 10) catch 1024;
        const height = std.fmt.parseInt(u32, height_arg, 10) catch 1024;
        const iterations = std.fmt.parseInt(u32, iterations_arg, 10) catch 50000;

        const f_min = std.fmt.parseFloat(f32, f_min_arg) catch 0.01;
        const f_max = std.fmt.parseFloat(f32, f_max_arg) catch 0.10;
        const k_min = std.fmt.parseFloat(f32, k_min_arg) catch 0.045;
        const k_max = std.fmt.parseFloat(f32, k_max_arg) catch 0.07;

        try map_gen.generateMap(allocator, width, height, iterations, f_min, f_max, k_min, k_max, output);
    } else if (std.mem.eql(u8, cmd, "sim")) {
        const width_arg = args.next() orelse "256";
        const height_arg = args.next() orelse "256";
        const iterations_arg = args.next() orelse "1000";
        const output = args.next() orelse "sim.pgm";

        const width = std.fmt.parseInt(u32, width_arg, 10) catch 256;
        const height = std.fmt.parseInt(u32, height_arg, 10) catch 256;
        const iterations = std.fmt.parseInt(u32, iterations_arg, 10) catch 1000;

        try runSimulation(allocator, width, height, iterations, output);
    } else {
        printUsage();
    }
}

fn runSimulation(allocator: std.mem.Allocator, width: u32, height: u32, iterations: u32, output: []const u8) !void {
    std.debug.print("Running simulation {d}x{d} for {d} iterations...\n", .{ width, height, iterations });

    var grid = try GrayScottGrid.init(allocator, width, height);
    defer grid.deinit();

    var next = try GrayScottGrid.init(allocator, width, height);
    defer next.deinit();

    // Create uniform feed/kill arrays
    const feed_row = try allocator.alloc(f32, height);
    defer allocator.free(feed_row);
    const kill_col = try allocator.alloc(f32, width);
    defer allocator.free(kill_col);

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

    @memset(feed_row, feed);
    @memset(kill_col, kill);

    // Initialize
    grid.fill(1.0, 0.0);
    grid.seedSquare(10, 0.5, 1.0);

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        simulation.stepDeterministic(&grid, &next, da, db, dt, feed_row, kill_col);
        grid.swap(&next);

        if (i % 100 == 0) {
            std.debug.print("  Iteration {d}\n", .{i});
        }
    }

    const file = try std.fs.cwd().createFile(output, .{});
    defer file.close();

    try file.writeAll("P5\n");
    try file.writeAll(try std.fmt.allocPrint(allocator, "{d} {d}\n", .{ width, height }));
    try file.writeAll("255\n");

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const val = @as(u8, @intFromFloat(@min(@max(grid.v[idx], 0.0), 1.0) * 255.0));
            try file.writeAll(&.{val});
        }
    }

    std.debug.print("Saved to {s}\n", .{output});
}

fn printUsage() void {
    std.debug.print(
        \\Usage: grayscott-cli <command> [options]
        \\
        \\Commands:
        \\  map [w h iter [f_min f_max k_min k_max] output]
        \\      Generate Pearson parameter map
        \\      Feed varies with Y (rows), Kill varies with X (cols)
        \\      Defaults: 1024x1024, 50000 iter,
        \\         f:0.01-0.10, k:0.045-0.07, output: map.pgm
        \\
        \\  sim [w h iter output]
        \\      Run single simulation (coral params)
        \\      Defaults: 256x256, 1000 iter, output: sim.pgm
        \\
    , .{});
}
