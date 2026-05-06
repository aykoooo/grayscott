const std = @import("std");
const gpu = @import("gray_scott_gpu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var use_f16: bool = false;
    var arg_idx: u32 = 1;

    if (args.len > 1 and std.mem.eql(u8, args[1], "--f16")) {
        use_f16 = true;
        arg_idx += 1;
    }

    const w: u32 = if (args.len > arg_idx) try std.fmt.parseInt(u32, args[@intCast(arg_idx)], 10) else 256;
    const h: u32 = if (args.len > arg_idx + 1) try std.fmt.parseInt(u32, args[@intCast(arg_idx + 1)], 10) else 256;
    const steps: u32 = if (args.len > arg_idx + 2) try std.fmt.parseInt(u32, args[@intCast(arg_idx + 2)], 10) else 500;

    const da: f32 = 1.0;
    const db: f32 = 0.5;
    const dt: f32 = 1.0;
    const feed: f32 = 0.0545;
    const kill: f32 = 0.0620;

    if (use_f16) {
        if (!gpu.gs_gpu_init_f16(w, h)) {
            std.debug.print("GPU f16 init failed\n", .{});
            return error.GpuInitFailed;
        }
    } else {
        if (!gpu.gs_gpu_init(w, h)) {
            std.debug.print("GPU init failed\n", .{});
            return error.GpuInitFailed;
        }
    }
    defer gpu.gs_gpu_free();

    std.Thread.sleep(10 * std.time.ns_per_s);

    var timer = try std.time.Timer.start();
    gpu.gs_gpu_steps(da, db, dt, feed, kill, steps);
    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const total_cells: f64 = @as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps));
    const cells_per_second: u64 = @intFromFloat(total_cells / elapsed_s);

    const grid_bytes = w * h * @sizeOf(f32);
    const u_back = try allocator.alloc(u8, grid_bytes);
    defer allocator.free(u_back);

    const read_bytes = if (use_f16)
        gpu.gs_gpu_read_result_f16(u_back.ptr, u_back.len)
    else
        gpu.gs_gpu_read_result(u_back.ptr, u_back.len);

    if (read_bytes != grid_bytes) {
        std.debug.print("GPU readback failed: expected {d}, got {d}\n", .{ grid_bytes, read_bytes });
        return error.GpuReadFailed;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(u_back);
    var hash_buf: [32]u8 = undefined;
    hasher.final(&hash_buf);

    var hash_str: [64]u8 = undefined;
    for (hash_buf, 0..) |byte, i| {
        _ = try std.fmt.bufPrint(hash_str[i * 2 ..][0..2], "{x:0>2}", .{byte});
    }

    const variant_tag = if (use_f16) "f16" else "f32";
    std.debug.print(
        \\{{"cells_per_second":{d},"hash":"{s}","width":{d},"height":{d},"steps":{d},"variant":"{s}"}}
        \\
    , .{
        cells_per_second,
        hash_str[0..],
        w,
        h,
        steps,
        variant_tag,
    });
}