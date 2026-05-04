const std = @import("std");
const gpu = @import("gray_scott_gpu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const w: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 1024;
    const h: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 1024;
    const iterations: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 50000;

    const f_min: f32 = if (args.len > 4) try std.fmt.parseFloat(f32, args[4]) else 0.01;
    const f_max: f32 = if (args.len > 5) try std.fmt.parseFloat(f32, args[5]) else 0.10;
    const k_min: f32 = if (args.len > 6) try std.fmt.parseFloat(f32, args[6]) else 0.045;
    const k_max: f32 = if (args.len > 7) try std.fmt.parseFloat(f32, args[7]) else 0.07;

    const output_path = if (args.len > 8) args[8] else "map.pgm";

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;

    std.debug.print("GPU Pearson Map: {d}x{d}  [{d} iters]  f:[{d:.4},{d:.4}]  k:[{d:.4},{d:.4}]\n", .{
        w, h, iterations, f_min, f_max, k_min, k_max,
    });

    var timer = try std.time.Timer.start();

    if (!gpu.gs_gpu_init_pearson(w, h, f_min, f_max, k_min, k_max)) {
        std.debug.print("GPU init failed\n", .{});
        return error.GpuInitFailed;
    }
    defer gpu.gs_gpu_free();
    const init_ns = timer.read();
    std.debug.print("  Init: {d:.2}s\n", .{@as(f64, @floatFromInt(init_ns)) / 1e9});

    // Run simulation in chunks with progress reporting
    const chunk_size: u32 = 5000;
    var remaining: u32 = iterations;
    var step_count: u32 = 0;
    while (remaining > 0) : (remaining -= @min(remaining, chunk_size)) {
        const n = @min(remaining, chunk_size);
        const before_ns = timer.read();
        gpu.gs_gpu_steps_pearson(da, db, dt, n);
        step_count += n;
        const elapsed_ns = timer.read() - before_ns;
        const rate: f32 = if (elapsed_ns > 0)
            @floatCast(@as(f64, @floatFromInt(@as(u64, w) * @as(u64, h) * n)) / @as(f64, @floatFromInt(elapsed_ns)) * 1e9)
        else
            0;

        const total_s = @as(f64, @floatFromInt(timer.read())) / 1e9;
        const remain_iters = iterations - step_count;
        const eta_s = if (rate > 0)
            @as(f32, @floatFromInt(@as(u64, w) * @as(u64, h) * remain_iters)) / rate
        else
            0;

        std.debug.print("  Iter {d}/{d} | {d:.1}s | {d:.0} cells/s | ETA {d:.0}s = {d:.1}m\n", .{
            step_count,  iterations,
            total_s,
            rate,
            eta_s,
            eta_s / 60.0,
        });
    }

    const after_step_ns = timer.read();

    // Read back V channel for PGM output
    const grid_bytes: usize = w * h * @sizeOf(f32);
    const v_back = try allocator.alloc(u8, grid_bytes);
    defer allocator.free(v_back);
    const read_bytes = gpu.gs_gpu_read_result_v(v_back.ptr, v_back.len);
    if (read_bytes != grid_bytes) {
        std.debug.print("GPU readback failed: expected {d}, got {d}\n", .{ grid_bytes, read_bytes });
        return error.GpuReadFailed;
    }
    const total_ns = timer.read();

    const sim_s = @as(f64, @floatFromInt(after_step_ns - init_ns)) / 1e9;
    const total_s = @as(f64, @floatFromInt(total_ns)) / 1e9;
    const total_cells: f64 = @as(f64, @floatFromInt(@as(u64, w) * @as(u64, h))) * @as(f64, @floatFromInt(iterations));
    const rate = @as(u64, @intFromFloat(total_cells / sim_s));

    std.debug.print("Done: {d:.1}s ({d}B cells -> {d} cells/sec)\n", .{ total_s, @as(u64, @intFromFloat(total_cells)) / 1_000_000_000, rate });

    // Write PGM (P5 binary grayscale from V channel, same as CPU map.zig)
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    const w_header = try std.fmt.allocPrint(allocator, "P5\n{d} {d}\n255\n", .{ w, h });
    defer allocator.free(w_header);
    try file.writeAll(w_header);

    const v_floats = @as([*]const f32, @ptrCast(@alignCast(v_back.ptr)))[0 .. w * h];
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const val: u8 = @intFromFloat(@min(@max(v_floats[y * w + x], 0.0), 1.0) * 255.0);
            try file.writeAll(&.{val});
        }
    }

    std.debug.print("Saved: {s}\n", .{output_path});
}