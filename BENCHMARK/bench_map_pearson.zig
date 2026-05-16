const std = @import("std");
const gpu = @import("gray_scott_gpu");

const MapHeader = extern struct {
    width: u32,
    height: u32,
    f_min: f32,
    f_max: f32,
    k_min: f32,
    k_max: f32,
};

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
    const f_max: f32 = if (args.len > 5) try std.fmt.parseFloat(f32, args[5]) else 0.08;
    const k_min: f32 = if (args.len > 6) try std.fmt.parseFloat(f32, args[6]) else 0.03;
    const k_max: f32 = if (args.len > 7) try std.fmt.parseFloat(f32, args[7]) else 0.07;

    const output_bin = if (args.len > 8) args[8] else "pearson_map.bin";

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
            step_count, iterations,
            total_s,    rate,
            eta_s,      eta_s / 60.0,
        });
    }

    const after_step_ns = timer.read();

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

    // Write binary: 24-byte header + raw u8 pixel data
    const bin_file = try std.fs.cwd().createFile(output_bin, .{});
    defer bin_file.close();

    const header = MapHeader{
        .width = w,
        .height = h,
        .f_min = f_min,
        .f_max = f_max,
        .k_min = k_min,
        .k_max = k_max,
    };
    // Write header as raw bytes (assumes little-endian, safe for x86+WASM+ARM)
    const header_bytes: [@sizeOf(MapHeader)]u8 = @bitCast(header);
    try bin_file.writeAll(&header_bytes);

    // Write pixel data (V-channel, 0-255)
    const v_floats = @as([*]const f32, @ptrCast(@alignCast(v_back.ptr)))[0 .. w * h];
    const bin_buf = try allocator.alloc(u8, w * h);
    defer allocator.free(bin_buf);
    for (v_floats, 0..) |v, i| {
        bin_buf[i] = @intFromFloat(@min(@max(v, 0.0), 1.0) * 255.0);
    }
    try bin_file.writeAll(bin_buf);
    const bin_size = try bin_file.getEndPos();
    std.debug.print("Saved: {s} ({d} bytes = 24 header + {d} pixels)\n", .{ output_bin, bin_size, w * h });
}
