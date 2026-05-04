const wgsl = @import("gray_scott_wgsl");

pub const ShaderMeta = extern struct {
    workgroup_x: u32,
    workgroup_y: u32,
    dispatch_count_x: u32,
    dispatch_count_y: u32,
};

pub const BufResult = extern struct {
    ptr: [*]const u8,
    len: u32,
};

var g_buf: [8192]u8 = undefined;

fn buildWgsl(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgsl(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_build_periodic(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    return buildWgsl(width, height, tile_x, tile_y);
}

export fn gs_wasm_build_pearson(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslPearson(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_meta(width: u32, height: u32, tile_x: u32, tile_y: u32) ShaderMeta {
    const dx = (width + tile_x - 1) / tile_x;
    const dy = (height + tile_y - 1) / tile_y;
    return .{
        .workgroup_x = tile_x,
        .workgroup_y = tile_y,
        .dispatch_count_x = dx,
        .dispatch_count_y = dy,
    };
}

pub fn main() void {}