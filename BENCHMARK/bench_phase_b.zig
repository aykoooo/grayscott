const std = @import("std");
const gpu = @import("gray_scott_gpu");

const ParamsGpu = extern struct { da: f32, db: f32, dt: f32, feed: f32, kill: f32 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const w: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 256;
    const h: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 256;
    const steps: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 500;
    const params = ParamsGpu{ .da = 1.0, .db = 0.5, .dt = 1.0, .feed = 0.0545, .kill = 0.0620 };
    const grid_bytes = w * h * @sizeOf(f32);

    runBench(alloc, w, h, steps, params, grid_bytes, "baseline", &gpu.gs_gpu_init);
    runBench(alloc, w, h, steps, params, grid_bytes, "interleaved", &gpu.gs_gpu_init_interleaved);
    runBench(alloc, w, h, steps, params, grid_bytes, "earlysum", &gpu.gs_gpu_init_earlysum);
}

fn runBench(
    alloc: std.mem.Allocator,
    w: u32,
    h: u32,
    steps: u32,
    params: ParamsGpu,
    grid_bytes: usize,
    tag: []const u8,
    initFn: *const fn (u32, u32) callconv(.c) bool,
) void {
    std.debug.print("\n--- {s} ---\n", .{tag});

    if (!initFn(w, h)) {
        std.debug.print("INIT FAILED\n", .{});
        return;
    }
    defer gpu.gs_gpu_free();

    var timer = std.time.Timer.start() catch {
        std.debug.print("TIMER FAILED\n", .{});
        return;
    };
    gpu.gs_gpu_steps(params.da, params.db, params.dt, params.feed, params.kill, steps);
    const ns = timer.read();
    const s = @as(f64, @floatFromInt(ns)) / 1e9;
    const cps: u64 = @intFromFloat(@as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps)) / s);

    const back = alloc.alloc(u8, grid_bytes) catch {
        std.debug.print("ALLOC FAILED\n", .{});
        return;
    };
    defer alloc.free(back);
    if (gpu.gs_gpu_read_result(back.ptr, back.len) != grid_bytes) {
        std.debug.print("READ FAILED\n", .{});
        return;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(back);
    var hb: [32]u8 = undefined;
    hasher.final(&hb);
    var hs: [64]u8 = undefined;
    for (hb, 0..) |b, i| {
        _ = std.fmt.bufPrint(hs[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
    }

    std.debug.print("{{\"variant\":\"{s}\",\"cells_per_second\":{d},\"hash\":\"{s}\",\"w\":{d},\"h\":{d},\"steps\":{d}}}\n", .{
        tag, cps, hs[0..], w, h, steps,
    });
}
