const std = @import("std");
const gpu = @import("gray_scott_gpu");

fn sweep(w: u32, h: u32, steps: u32) void {
    const shapes = [_]struct { tag: []const u8, tx: u32, ty: u32, vec2: bool }{
        .{ .tag = "16x4", .tx = 16, .ty = 4, .vec2 = false },
        .{ .tag = "8x8", .tx = 8, .ty = 8, .vec2 = false },
        .{ .tag = "16x8", .tx = 16, .ty = 8, .vec2 = false },
        .{ .tag = "4x16", .tx = 4, .ty = 16, .vec2 = false },
        .{ .tag = "32x2", .tx = 32, .ty = 2, .vec2 = false },
        .{ .tag = "vec2_16x4", .tx = 16, .ty = 4, .vec2 = true },
        .{ .tag = "vec2_16x8", .tx = 16, .ty = 8, .vec2 = true },
    };
    for (shapes) |sh| {
        const ok = if (sh.vec2) gpu.gs_gpu_init_shape_vec2(w, h, sh.tx, sh.ty) else gpu.gs_gpu_init_shape(w, h, sh.tx, sh.ty);
        if (!ok) {
            std.debug.print("init failed for {s}\n", .{sh.tag});
            continue;
        }
        defer gpu.gs_gpu_free();
        var t = std.time.Timer.start() catch continue;
        gpu.gs_gpu_steps(1.0, 0.5, 1.0, 0.0545, 0.0620, steps);
        const ns = t.read();
        const s = @as(f64, @floatFromInt(ns)) / 1e9;
        const cps: u64 = @intFromFloat(@as(f64, @floatFromInt(w * h)) * @as(f64, @floatFromInt(steps)) / s);
        const back = std.heap.page_allocator.alloc(u8, w * h * 4) catch continue;
        defer std.heap.page_allocator.free(back);
        _ = gpu.gs_gpu_read_result(back.ptr, back.len);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(back);
        var hb: [32]u8 = undefined;
        hasher.final(&hb);
        var hs: [64]u8 = undefined;
        for (hb, 0..) |b, i| {
            _ = std.fmt.bufPrint(hs[i * 2 ..][0..2], "{x:0>2}", .{b}) catch {};
        }
        std.debug.print("{{\"shape\":\"{s}\",\"cells_per_second\":{d},\"hash\":\"{s}\",\"w\":{d},\"h\":{d}}}\n", .{ sh.tag, cps, hs[0..], w, h });
    }
}

pub fn main() !void {
    sweep(128, 128, 500);
    sweep(256, 256, 500);
    sweep(512, 512, 500);
}
