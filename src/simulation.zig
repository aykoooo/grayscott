const GrayScottGrid = @import("gray_scott_grid").GrayScottGrid;

/// Single-threaded, deterministic step function.
/// Uses 9-point stencil Laplacian (matching nabla-type-lite / Karl Sims)
/// with periodic boundary conditions.
/// feed_row[y] gives feed rate for row y; kill_col[x] gives kill rate for column x.
/// Iterates in strict row-major order for determinism.
pub fn stepDeterministic(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    da: f32,
    db: f32,
    dt: f32,
    feed_row: []const f32,
    kill_col: []const f32,
) void {
    const width = grid.width;
    const height = grid.height;

    var y: usize = 1;
    while (y < height - 1) : (y += 1) {
        const feed = feed_row[y];
        var x: usize = 1;
        while (x < width - 1) : (x += 1) {
            const kill = kill_col[x];
            const idx = y * width + x;
            const u = grid.u[idx];
            const v = grid.v[idx];

            const u_left = grid.u[idx - 1];
            const u_right = grid.u[idx + 1];
            const u_up = grid.u[(y - 1) * width + x];
            const u_down = grid.u[(y + 1) * width + x];
            const u_ne = grid.u[(y - 1) * width + (x + 1)];
            const u_nw = grid.u[(y - 1) * width + (x - 1)];
            const u_se = grid.u[(y + 1) * width + (x + 1)];
            const u_sw = grid.u[(y + 1) * width + (x - 1)];

            const v_left = grid.v[idx - 1];
            const v_right = grid.v[idx + 1];
            const v_up = grid.v[(y - 1) * width + x];
            const v_down = grid.v[(y + 1) * width + x];
            const v_ne = grid.v[(y - 1) * width + (x + 1)];
            const v_nw = grid.v[(y - 1) * width + (x - 1)];
            const v_se = grid.v[(y + 1) * width + (x + 1)];
            const v_sw = grid.v[(y + 1) * width + (x - 1)];

            const lap_u = 0.2 * (u_left + u_right + u_up + u_down) + 0.05 * (u_ne + u_nw + u_se + u_sw) - 1.0 * u;
            const lap_v = 0.2 * (v_left + v_right + v_up + v_down) + 0.05 * (v_ne + v_nw + v_se + v_sw) - 1.0 * v;

            const uvv = u * v * v;

            next.u[idx] = @max(0.0, @min(1.0, u + dt * (da * lap_u - uvv + feed * (1.0 - u))));

            next.v[idx] = @max(0.0, @min(1.0, v + dt * (db * lap_v + uvv - (feed + kill) * v)));
        }
    }

    handleBoundaries(grid, next, da, db, dt, feed_row, kill_col);
}

fn handleBoundaries(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    da: f32,
    db: f32,
    dt: f32,
    feed_row: []const f32,
    kill_col: []const f32,
) void {
    const width = grid.width;
    const height = grid.height;

    var x: usize = 1;
    while (x < width - 1) : (x += 1) {
        processCell(grid, next, x, 0, da, db, dt, feed_row[0], kill_col[x]);
    }
    x = 1;
    while (x < width - 1) : (x += 1) {
        processCell(grid, next, x, height - 1, da, db, dt, feed_row[height - 1], kill_col[x]);
    }

    var y: usize = 1;
    while (y < height - 1) : (y += 1) {
        processCell(grid, next, 0, y, da, db, dt, feed_row[y], kill_col[0]);
    }
    y = 1;
    while (y < height - 1) : (y += 1) {
        processCell(grid, next, width - 1, y, da, db, dt, feed_row[y], kill_col[width - 1]);
    }

    processCell(grid, next, 0, 0, da, db, dt, feed_row[0], kill_col[0]);
    processCell(grid, next, width - 1, 0, da, db, dt, feed_row[0], kill_col[width - 1]);
    processCell(grid, next, 0, height - 1, da, db, dt, feed_row[height - 1], kill_col[0]);
    processCell(grid, next, width - 1, height - 1, da, db, dt, feed_row[height - 1], kill_col[width - 1]);
}

fn processCell(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    x: usize,
    y: usize,
    da: f32,
    db: f32,
    dt: f32,
    feed: f32,
    kill: f32,
) void {
    const width = grid.width;
    const height = grid.height;

    const idx = y * width + x;
    const u = grid.u[idx];
    const v = grid.v[idx];

    const x_l = if (x == 0) width - 1 else x - 1;
    const x_r = if (x == width - 1) 0 else x + 1;
    const y_t = if (y == 0) height - 1 else y - 1;
    const y_b = if (y == height - 1) 0 else y + 1;

    const u_left = grid.u[y * width + x_l];
    const u_right = grid.u[y * width + x_r];
    const u_up = grid.u[y_t * width + x];
    const u_down = grid.u[y_b * width + x];
    const u_ne = grid.u[y_t * width + x_r];
    const u_nw = grid.u[y_t * width + x_l];
    const u_se = grid.u[y_b * width + x_r];
    const u_sw = grid.u[y_b * width + x_l];

    const v_left = grid.v[y * width + x_l];
    const v_right = grid.v[y * width + x_r];
    const v_up = grid.v[y_t * width + x];
    const v_down = grid.v[y_b * width + x];
    const v_ne = grid.v[y_t * width + x_r];
    const v_nw = grid.v[y_t * width + x_l];
    const v_se = grid.v[y_b * width + x_r];
    const v_sw = grid.v[y_b * width + x_l];

    const lap_u = 0.2 * (u_left + u_right + u_up + u_down) + 0.05 * (u_ne + u_nw + u_se + u_sw) - 1.0 * u;
    const lap_v = 0.2 * (v_left + v_right + v_up + v_down) + 0.05 * (v_ne + v_nw + v_se + v_sw) - 1.0 * v;

    const uvv = u * v * v;

    next.u[idx] = @max(0.0, @min(1.0, u + dt * (da * lap_u - uvv + feed * (1.0 - u))));

    next.v[idx] = @max(0.0, @min(1.0, v + dt * (db * lap_v + uvv - (feed + kill) * v)));
}

pub fn stepNeumann(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    da: f32,
    db: f32,
    dt: f32,
    feed_row: []const f32,
    kill_col: []const f32,
) void {
    const width = grid.width;
    const height = grid.height;

    var y: usize = 1;
    while (y < height - 1) : (y += 1) {
        const feed = feed_row[y];
        var x: usize = 1;
        while (x < width - 1) : (x += 1) {
            const kill = kill_col[x];
            const idx = y * width + x;
            const u = grid.u[idx];
            const v = grid.v[idx];

            const u_left = grid.u[idx - 1];
            const u_right = grid.u[idx + 1];
            const u_up = grid.u[(y - 1) * width + x];
            const u_down = grid.u[(y + 1) * width + x];
            const u_ne = grid.u[(y - 1) * width + (x + 1)];
            const u_nw = grid.u[(y - 1) * width + (x - 1)];
            const u_se = grid.u[(y + 1) * width + (x + 1)];
            const u_sw = grid.u[(y + 1) * width + (x - 1)];

            const v_left = grid.v[idx - 1];
            const v_right = grid.v[idx + 1];
            const v_up = grid.v[(y - 1) * width + x];
            const v_down = grid.v[(y + 1) * width + x];
            const v_ne = grid.v[(y - 1) * width + (x + 1)];
            const v_nw = grid.v[(y - 1) * width + (x - 1)];
            const v_se = grid.v[(y + 1) * width + (x + 1)];
            const v_sw = grid.v[(y + 1) * width + (x - 1)];

            const lap_u = 0.2 * (u_left + u_right + u_up + u_down) + 0.05 * (u_ne + u_nw + u_se + u_sw) - 1.0 * u;
            const lap_v = 0.2 * (v_left + v_right + v_up + v_down) + 0.05 * (v_ne + v_nw + v_se + v_sw) - 1.0 * v;

            const uvv = u * v * v;

            next.u[idx] = @max(0.0, @min(1.0, u + dt * (da * lap_u - uvv + feed * (1.0 - u))));

            next.v[idx] = @max(0.0, @min(1.0, v + dt * (db * lap_v + uvv - (feed + kill) * v)));
        }
    }

    handleNeumannBounds(grid, next, da, db, dt, feed_row, kill_col);
}

fn handleNeumannBounds(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    da: f32,
    db: f32,
    dt: f32,
    feed_row: []const f32,
    kill_col: []const f32,
) void {
    const w = grid.width;
    const h = grid.height;

    var x: usize = 1;
    while (x < w - 1) : (x += 1) {
        processCellNeumann(grid, next, x, 0, da, db, dt, feed_row[0], kill_col[x]);
    }
    x = 1;
    while (x < w - 1) : (x += 1) {
        processCellNeumann(grid, next, x, h - 1, da, db, dt, feed_row[h - 1], kill_col[x]);
    }
    var y: usize = 1;
    while (y < h - 1) : (y += 1) {
        processCellNeumann(grid, next, 0, y, da, db, dt, feed_row[y], kill_col[0]);
    }
    y = 1;
    while (y < h - 1) : (y += 1) {
        processCellNeumann(grid, next, w - 1, y, da, db, dt, feed_row[y], kill_col[w - 1]);
    }
    processCellNeumann(grid, next, 0, 0, da, db, dt, feed_row[0], kill_col[0]);
    processCellNeumann(grid, next, w - 1, 0, da, db, dt, feed_row[0], kill_col[w - 1]);
    processCellNeumann(grid, next, 0, h - 1, da, db, dt, feed_row[h - 1], kill_col[0]);
    processCellNeumann(grid, next, w - 1, h - 1, da, db, dt, feed_row[h - 1], kill_col[w - 1]);
}

fn processCellNeumann(
    grid: *GrayScottGrid,
    next: *GrayScottGrid,
    x: usize,
    y: usize,
    da: f32,
    db: f32,
    dt: f32,
    feed: f32,
    kill: f32,
) void {
    const w = grid.width;
    const h = grid.height;

    const idx = y * w + x;
    const u = grid.u[idx];
    const v = grid.v[idx];

    const x_l = if (x == 0) 0 else x - 1;
    const x_r = if (x >= w - 1) w - 1 else x + 1;
    const y_t = if (y == 0) 0 else y - 1;
    const y_b = if (y >= h - 1) h - 1 else y + 1;

    const u_left = grid.u[y * w + x_l];
    const u_right = grid.u[y * w + x_r];
    const u_up = grid.u[y_t * w + x];
    const u_down = grid.u[y_b * w + x];
    const u_ne = grid.u[y_t * w + x_r];
    const u_nw = grid.u[y_t * w + x_l];
    const u_se = grid.u[y_b * w + x_r];
    const u_sw = grid.u[y_b * w + x_l];

    const v_left = grid.v[y * w + x_l];
    const v_right = grid.v[y * w + x_r];
    const v_up = grid.v[y_t * w + x];
    const v_down = grid.v[y_b * w + x];
    const v_ne = grid.v[y_t * w + x_r];
    const v_nw = grid.v[y_t * w + x_l];
    const v_se = grid.v[y_b * w + x_r];
    const v_sw = grid.v[y_b * w + x_l];

    const lap_u = 0.2 * (u_left + u_right + u_up + u_down) + 0.05 * (u_ne + u_nw + u_se + u_sw) - 1.0 * u;
    const lap_v = 0.2 * (v_left + v_right + v_up + v_down) + 0.05 * (v_ne + v_nw + v_se + v_sw) - 1.0 * v;

    const uvv = u * v * v;

    next.u[idx] = @max(0.0, @min(1.0, u + dt * (da * lap_u - uvv + feed * (1.0 - u))));

    next.v[idx] = @max(0.0, @min(1.0, v + dt * (db * lap_v + uvv - (feed + kill) * v)));
}
