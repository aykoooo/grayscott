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
    if (!gpu.gs_gpu_init_fma(w, h)) return error.InitFail;
    defer gpu.gs_gpu_free();
    var timer = try std.time.Timer.start();
    gpu.gs_gpu_steps(1.0, 0.5, 1.0, 0.0545, 0.0620, steps);
    const ns = timer.read();
    const s = @as(f64, @floatFromInt(ns)) / 1e9;
    const cps: u64 = @intFromFloat(@as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps)) / s);
    const gb = w * h * @sizeOf(f32);
    const back = try allocator.alloc(u8, gb);
    defer allocator.free(back);
    if (gpu.gs_gpu_read_result(back.ptr, back.len) != gb) return error.ReadFail;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(back);
    var hb: [32]u8 = undefined;
    hasher.final(&hb);
    var hs: [64]u8 = undefined;
    for (hb, 0..) |b, i| {
        _ = try std.fmt.bufPrint(hs[i * 2 ..][0..2], "{x:0>2}", .{b});
    }
    std.debug.print("{{\"variant\":\"fma\",\"cells_per_second\":{d},\"hash\":\"{s}\",\"w\":{d},\"h\":{d},\"steps\":{d}}}\n", .{ cps, hs[0..], w, h, steps });
}
