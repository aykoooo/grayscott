const std = @import("std");
const gpu = @import("gray_scott_gpu");

fn bench(w: u32, h: u32, steps: u32, tag: []const u8, initFn: *const fn (u32, u32) callconv(.c) bool) void {
    if (!initFn(w, h)) return;
    defer gpu.gs_gpu_free();
    var t = std.time.Timer.start() catch return;
    gpu.gs_gpu_steps(1.0, 0.5, 1.0, 0.0545, 0.0620, steps);
    const ns = t.read();
    const s = @as(f64, @floatFromInt(ns)) / 1e9;
    const cps: u64 = @intFromFloat(@as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps)) / s);
    const back = std.heap.page_allocator.alloc(u8, w * h * 4) catch return;
    defer std.heap.page_allocator.free(back);
    _ = gpu.gs_gpu_read_result(back.ptr, back.len);
    hashAndPrint(tag, cps, back);
}

fn bench_f16(w: u32, h: u32, steps: u32, tag: []const u8, initFn: *const fn (u32, u32) callconv(.c) bool) void {
    if (!initFn(w, h)) return;
    defer gpu.gs_gpu_free();
    var t = std.time.Timer.start() catch return;
    gpu.gs_gpu_steps(1.0, 0.5, 1.0, 0.0545, 0.0620, steps);
    const ns = t.read();
    const s = @as(f64, @floatFromInt(ns)) / 1e9;
    const cps: u64 = @intFromFloat(@as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps)) / s);
    const back = std.heap.page_allocator.alloc(u8, w * h * 4) catch return;
    defer std.heap.page_allocator.free(back);
    _ = gpu.gs_gpu_read_result_f16(back.ptr, back.len);
    hashAndPrint(tag, cps, back);
}

fn hashAndPrint(tag: []const u8, cps: u64, data: []const u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var hb: [32]u8 = undefined;
    hasher.final(&hb);
    var hs: [64]u8 = undefined;
    for (hb, 0..) |b, i| {
        _ = std.fmt.bufPrint(hs[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    }
    std.debug.print("{{\"variant\":\"{s}\",\"cells_per_second\":{d},\"hash\":\"{s}\"}}\n", .{ tag, cps, hs[0..] });
}

pub fn main() !void {
    // Global GPU warm-up to stabilize clocks before timed runs
    {
        _ = gpu.gs_gpu_init(256, 256);
        defer gpu.gs_gpu_free();
        gpu.gs_gpu_steps(1.0, 0.5, 1.0, 0.0545, 0.0620, 50);
    }
    bench(256, 256, 500, "baseline", &gpu.gs_gpu_init);
    bench(256, 256, 500, "earlysum", &gpu.gs_gpu_init_earlysum);
    bench(256, 256, 500, "interleaved", &gpu.gs_gpu_init_interleaved);
    bench(256, 256, 500, "coarse", &gpu.gs_gpu_init_coarse);
    bench_f16(256, 256, 500, "f16", &gpu.gs_gpu_init_f16);
    // bench(256, 256, 500, "earlysum", &gpu.gs_gpu_init_earlysum);
    // bench(256, 256, 500, "interleaved", &gpu.gs_gpu_init_interleaved);
    // bench(256, 256, 500, "coarse", &gpu.gs_gpu_init_coarse);
    // bench_f16(256, 256, 500, "f16", &gpu.gs_gpu_init_f16);
}
