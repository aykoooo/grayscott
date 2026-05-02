const std = @import("std");
const testing = std.testing;
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

fn makeUniformArrays(allocator: std.mem.Allocator, w: usize, h: usize, feed: f32, kill: f32) !struct { feed_row: []f32, kill_col: []f32 } {
    const fr = try allocator.alloc(f32, h);
    @memset(fr, feed);
    const kc = try allocator.alloc(f32, w);
    @memset(kc, kill);
    return .{ .feed_row = fr, .kill_col = kc };
}

test "GrayScottGrid initialization" {
    var grid = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid.deinit();
    try testing.expectEqual(64, grid.width);
    try testing.expectEqual(64, grid.height);
    try testing.expectEqual(4096, grid.u.len);
    try testing.expectEqual(4096, grid.v.len);
}

test "GrayScottGrid fill and seed" {
    var grid = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid.deinit();

    grid.fill(1.0, 0.0);
    for (grid.u) |u| try testing.expectApproxEqAbs(1.0, u, 1e-6);
    for (grid.v) |v| try testing.expectApproxEqAbs(0.0, v, 1e-6);

    grid.seedSquare(10, 0.5, 1.0);
    var y: usize = 27;
    while (y < 37) : (y += 1) {
        var x: usize = 27;
        while (x < 37) : (x += 1) {
            const idx = grid.idx(x, y);
            try testing.expectApproxEqAbs(0.5, grid.u[idx], 1e-6);
            try testing.expectApproxEqAbs(1.0, grid.v[idx], 1e-6);
        }
    }
}

test "GrayScottGrid swap" {
    var grid1 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid1.deinit();
    var grid2 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid2.deinit();

    grid1.fill(1.0, 0.0);
    grid2.fill(0.0, 1.0);
    grid1.swap(&grid2);

    try testing.expectApproxEqAbs(0.0, grid1.u[0], 1e-6);
    try testing.expectApproxEqAbs(1.0, grid1.v[0], 1e-6);
    try testing.expectApproxEqAbs(1.0, grid2.u[0], 1e-6);
    try testing.expectApproxEqAbs(0.0, grid2.v[0], 1e-6);
}

test "Deterministic step produces same result" {
    const fr1 = try makeUniformArrays(testing.allocator, 64, 64, 0.0545, 0.0620);
    defer testing.allocator.free(fr1.feed_row);
    defer testing.allocator.free(fr1.kill_col);
    const fr2 = try makeUniformArrays(testing.allocator, 64, 64, 0.0545, 0.0620);
    defer testing.allocator.free(fr2.feed_row);
    defer testing.allocator.free(fr2.kill_col);

    var grid1 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid1.deinit();
    var next1 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer next1.deinit();
    grid1.fill(1.0, 0.0);
    grid1.seedSquare(10, 0.5, 1.0);

    var grid2 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid2.deinit();
    var next2 = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer next2.deinit();
    grid2.fill(1.0, 0.0);
    grid2.seedSquare(10, 0.5, 1.0);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        simulation.stepDeterministic(&grid1, &next1, 1.0, 0.5, 1.0, fr1.feed_row, fr1.kill_col);
        grid1.swap(&next1);
        simulation.stepDeterministic(&grid2, &next2, 1.0, 0.5, 1.0, fr2.feed_row, fr2.kill_col);
        grid2.swap(&next2);
    }

    for (grid1.u, grid2.u) |a1, a2| try testing.expectApproxEqRel(a1, a2, 1e-10);
    for (grid1.v, grid2.v) |b1, b2| try testing.expectApproxEqRel(b1, b2, 1e-10);
}

test "Simulation stays bounded [0, 1]" {
    const fr = try makeUniformArrays(testing.allocator, 64, 64, 0.0545, 0.0620);
    defer testing.allocator.free(fr.feed_row);
    defer testing.allocator.free(fr.kill_col);

    var grid = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer grid.deinit();
    var next = try GrayScottGrid.init(testing.allocator, 64, 64);
    defer next.deinit();

    grid.fill(1.0, 0.0);
    grid.seedSquare(10, 0.5, 1.0);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        simulation.stepDeterministic(&grid, &next, 1.0, 0.5, 1.0, fr.feed_row, fr.kill_col);
        grid.swap(&next);
    }

    for (grid.u) |u| try testing.expect(u >= 0.0 and u <= 1.0);
    for (grid.v) |v| try testing.expect(v >= 0.0 and v <= 1.0);
}

test "Coral preset produces pattern" {
    const fr = try makeUniformArrays(testing.allocator, 128, 128, 0.0545, 0.0620);
    defer testing.allocator.free(fr.feed_row);
    defer testing.allocator.free(fr.kill_col);

    var grid = try GrayScottGrid.init(testing.allocator, 128, 128);
    defer grid.deinit();
    var next = try GrayScottGrid.init(testing.allocator, 128, 128);
    defer next.deinit();

    grid.fill(1.0, 0.0);
    grid.seedSquare(10, 0.5, 1.0);

    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        simulation.stepDeterministic(&grid, &next, 1.0, 0.5, 1.0, fr.feed_row, fr.kill_col);
        grid.swap(&next);
    }

    var min_u: f32 = 1e10;
    var max_u: f32 = -1e10;
    for (grid.u) |u| {
        if (u < min_u) min_u = u;
        if (u > max_u) max_u = u;
    }
    try testing.expect(max_u - min_u > 0.1);
}
