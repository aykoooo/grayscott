const std = @import("std");
const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;
const simulation = @import("gray_scott_sim");

var g_grid: ?GrayScottGrid = null;
var g_next: ?GrayScottGrid = null;
var g_feed_row: []f32 = &.{};
var g_kill_col: []f32 = &.{};
var g_width: u32 = 0;
var g_height: u32 = 0;

var g_da: f32 = 1.0;
var g_db: f32 = 0.5;
var g_dt: f32 = 1.0;
var g_feed: f32 = 0.0545;
var g_kill: f32 = 0.0620;

fn ensureArrays(width: u32, height: u32) void {
    if (g_feed_row.len != height) {
        g_feed_row = std.heap.page_allocator.alloc(f32, height) catch @panic("OOM");
    }
    if (g_kill_col.len != width) {
        g_kill_col = std.heap.page_allocator.alloc(f32, width) catch @panic("OOM");
    }
    @memset(g_feed_row[0..height], g_feed);
    @memset(g_kill_col[0..width], g_kill);
}

export fn gs_init(width: u32, height: u32) i32 {
    const allocator = std.heap.page_allocator;

    g_grid = GrayScottGrid.init(allocator, width, height) catch return -1;
    g_next = GrayScottGrid.init(allocator, width, height) catch return -1;
    g_width = width;
    g_height = height;

    g_grid.?.fill(1.0, 0.0);
    g_grid.?.seedSquare(10, 0.5, 1.0);

    ensureArrays(width, height);

    return 0;
}

export fn gs_step() void {
    if (g_grid == null or g_next == null) return;

    simulation.stepDeterministic(&g_grid.?, &g_next.?, g_da, g_db, g_dt, g_feed_row[0..g_height], g_kill_col[0..g_width]);
    g_grid.?.swap(&g_next.?);
}

export fn gs_stepN(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        gs_step();
    }
}

export fn gs_set_params(feed: f32, kill: f32, da: f32, db: f32, dt: f32) void {
    g_feed = feed;
    g_kill = kill;
    g_da = da;
    g_db = db;
    g_dt = dt;
    if (g_width > 0 and g_height > 0) {
        ensureArrays(g_width, g_height);
    }
}

export fn gs_get_params(feed_ptr: *f32, kill_ptr: *f32, da_ptr: *f32, db_ptr: *f32, dt_ptr: *f32) void {
    feed_ptr.* = g_feed;
    kill_ptr.* = g_kill;
    da_ptr.* = g_da;
    db_ptr.* = g_db;
    dt_ptr.* = g_dt;
}

export fn gs_get_state(u_ptr: [*]f32, v_ptr: [*]f32, size: u32) void {
    if (g_grid == null) return;
    const grid = g_grid.?;
    const copy_size = @min(size, @as(u32, @intCast(grid.width * grid.height)));
    @memcpy(u_ptr[0..copy_size], grid.u[0..copy_size]);
    @memcpy(v_ptr[0..copy_size], grid.v[0..copy_size]);
}

export fn gs_get_width() u32 {
    return if (g_grid) |g| @intCast(g.width) else 0;
}

export fn gs_get_height() u32 {
    return if (g_grid) |g| @intCast(g.height) else 0;
}

export fn gs_reseed(size: u32, u_val: f32, v_val: f32) void {
    if (g_grid) |*grid| {
        grid.seedSquare(size, u_val, v_val);
    }
}

export fn gs_clear() void {
    if (g_grid) |*grid| {
        grid.fill(1.0, 0.0);
    }
}

export fn gs_destroy() void {
    if (g_grid) |*g| {
        g.deinit();
        g_grid = null;
    }
    if (g_next) |*g| {
        g.deinit();
        g_next = null;
    }
}

pub fn main() void {}
