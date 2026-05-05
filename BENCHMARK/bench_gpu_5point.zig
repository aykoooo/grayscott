const std = @import("std");
const gpu = @import("gray_scott_gpu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const w: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 256;
    const h: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 256;
    const steps: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 500;

    if (!gpu.gs_gpu_init_5point(w, h)) return error.GpuInitFailed;
    defer gpu.gs_gpu_free();

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

    var timer = try std.time.Timer.start();
    gpu.gs_gpu_steps(da, db, dt, feed, kill, steps);
    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const total_cells: f64 = @as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps));
    const cps: u64 = @intFromFloat(total_cells / elapsed_s);

    const grid_bytes = w * h * @sizeOf(f32);
    const u_back = try allocator.alloc(u8, grid_bytes);
    defer allocator.free(u_back);
    if (gpu.gs_gpu_read_result(u_back.ptr, u_back.len) != grid_bytes) return error.ReadFail;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(u_back);
    var hash_buf: [32]u8 = undefined;
    hasher.final(&hash_buf);
    var hash_str: [64]u8 = undefined;
    for (hash_buf, 0..) |byte, i| { _ = try std.fmt.bufPrint(hash_str[i * 2 ..][0..2], "{x:0>2}", .{byte}); }

    std.debug.print("{{\"variant\":\"5point\",\"cells_per_second\":{d},\"hash\":\"{s}\",\"w\":{d},\"h\":{d},\"steps\":{d}}}\n", .{ cps, hash_str[0..], w, h, steps });
}