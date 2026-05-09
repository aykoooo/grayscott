const std = @import("std");
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

pub const TileResult = extern struct {
    tile_x: u32,
    tile_y: u32,
};

const CANDIDATE_TILES = [_][2]u32{
    .{ 16, 4 },
    .{ 8, 8 },
    .{ 32, 4 },
    .{ 16, 8 },
    .{ 32, 2 },
    .{ 4, 16 },
};

pub const VariantTag = enum(u32) {
    standard = 0,
    subgroups = 1,
    f16 = 2,
    subgroup_shuffle = 8,
    pearson = 4,
};

const FEATURE_SUBGROUPS: u32 = 1;
const FEATURE_F16: u32 = 2;

var g_buf: [16384]u8 = undefined;
var g_init_info: InitInfo = undefined;

fn buildWgsl(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    _ = width; _ = height;
    const result = wgsl.generateWgsl(&g_buf, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

fn buildWgslSubgroups(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslSubgroups(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

fn buildWgslSubgroupShuffle(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslSubgroupShuffle(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

fn buildWgslF16(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslF16(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_build_periodic(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    return buildWgsl(width, height, tile_x, tile_y);
}

export fn gs_wasm_build_pearson(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslPearson(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_build_subgroups(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    return buildWgslSubgroups(width, height, tile_x, tile_y);
}

export fn gs_wasm_build_subgroup_shuffle(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslSubgroupShuffle(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_build_vec2(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslVec2(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

export fn gs_wasm_build_f16(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslF16(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
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

pub const BindingDesc = extern struct {
    binding: u32,
    kind: u32,
};

pub const BindGroupLayout = extern struct {
    count: u32,
    bindings: [8]BindingDesc,
};

const BINDING_STORAGE_RO: u32 = 0;
const BINDING_STORAGE_RW: u32 = 1;
const BINDING_UNIFORM: u32 = 2;

const PERIODIC_LAYOUT = BindGroupLayout{
    .count = 5,
    .bindings = [_]BindingDesc{
        .{ .binding = 0, .kind = BINDING_STORAGE_RO },
        .{ .binding = 1, .kind = BINDING_STORAGE_RO },
        .{ .binding = 2, .kind = BINDING_STORAGE_RW },
        .{ .binding = 3, .kind = BINDING_STORAGE_RW },
        .{ .binding = 4, .kind = BINDING_UNIFORM },
        .{ .binding = 0, .kind = 0 },
        .{ .binding = 0, .kind = 0 },
        .{ .binding = 0, .kind = 0 },
    },
};

const PEARSON_LAYOUT = BindGroupLayout{
    .count = 7,
    .bindings = [_]BindingDesc{
        .{ .binding = 0, .kind = BINDING_STORAGE_RO },
        .{ .binding = 1, .kind = BINDING_STORAGE_RO },
        .{ .binding = 2, .kind = BINDING_STORAGE_RW },
        .{ .binding = 3, .kind = BINDING_STORAGE_RW },
        .{ .binding = 4, .kind = BINDING_UNIFORM },
        .{ .binding = 5, .kind = BINDING_STORAGE_RO },
        .{ .binding = 6, .kind = BINDING_STORAGE_RO },
        .{ .binding = 0, .kind = 0 },
    },
};

export fn gs_wasm_bind_group_layout(variant: u32) BindGroupLayout {
    return switch (variant) {
        0 => PERIODIC_LAYOUT,
        1 => PEARSON_LAYOUT,
        else => PERIODIC_LAYOUT,
    };
}

pub const InitInfo = extern struct {
    tile_x: u32,
    tile_y: u32,
    workgroup_x: u32,
    workgroup_y: u32,
    dispatch_x: u32,
    dispatch_y: u32,
    buffer_size: u32,
    grid_width: u32,
    grid_height: u32,
};

export fn gs_wasm_optimal_tile(width: u32, height: u32) TileResult {
    const wg = selectWorkgroup(width, height);
    return .{ .tile_x = wg[0], .tile_y = wg[1] };
}

export fn gs_wasm_init_ptr(width: u32, height: u32) u32 {
    const tile = gs_wasm_optimal_tile(width, height);
    g_init_info = .{
        .tile_x = tile.tile_x,
        .tile_y = tile.tile_y,
        .workgroup_x = tile.tile_x,
        .workgroup_y = tile.tile_y,
        .dispatch_x = (width + tile.tile_x - 1) / tile.tile_x,
        .dispatch_y = (height + tile.tile_y - 1) / tile.tile_y,
        .buffer_size = width * height * 4,
        .grid_width = width,
        .grid_height = height,
    };
    return g_init_info.buffer_size;
}

export fn gs_wasm_init_tile_x() u32 { return g_init_info.tile_x; }
export fn gs_wasm_init_tile_y() u32 { return g_init_info.tile_y; }
export fn gs_wasm_init_dispatch_x() u32 { return g_init_info.dispatch_x; }
export fn gs_wasm_init_dispatch_y() u32 { return g_init_info.dispatch_y; }

export fn gs_wasm_build_standard_shader(width: u32, height: u32, tile_x: u32, tile_y: u32) u32 {
    const result = buildWgsl(width, height, tile_x, tile_y);
    return result.len;
}

export fn gs_wasm_build_subgroups_shader(width: u32, height: u32, tile_x: u32, tile_y: u32) u32 {
    const result = buildWgslSubgroups(width, height, tile_x, tile_y);
    return result.len;
}

export fn gs_wasm_shader_ptr() u32 {
    return @intFromPtr(&g_buf);
}

export fn gs_wasm_init(width: u32, height: u32) InitInfo {
    const tile = gs_wasm_optimal_tile(width, height);
    const dx = (width + tile.tile_x - 1) / tile.tile_x;
    const dy = (height + tile.tile_y - 1) / tile.tile_y;
    return .{
        .tile_x = tile.tile_x,
        .tile_y = tile.tile_y,
        .workgroup_x = tile.tile_x,
        .workgroup_y = tile.tile_y,
        .dispatch_x = dx,
        .dispatch_y = dy,
        .buffer_size = width * height * 4,
        .grid_width = width,
        .grid_height = height,
    };
}

pub const BestResult = extern struct {
    shader_ptr: [*]const u8,
    shader_len: u32,
    tile_x: u32,
    tile_y: u32,
    dispatch_x: u32,
    dispatch_y: u32,
    variant_tag: u32,
};

fn selectWorkgroup(width: u32, height: u32) [2]u32 {
    const cells = @as(u64, width) * @as(u64, height);
    if (width >= height * 2) {
        return .{ 32, 2 };
    }
    if (height >= width * 2) {
        return .{ 4, 16 };
    }
    if (cells <= 200 * 200) {
        return .{ 16, 8 };
    }
    if (width >= 250 and width <= 260 and height >= 250 and height <= 260) {
        return .{ 32, 2 };
    }
    if (cells >= 400 * 400) {
        return .{ 16, 8 };
    }
    return .{ 16, 4 };
}

export fn gs_wasm_get_best(width: u32, height: u32, features: u32) BestResult {
    const wg = selectWorkgroup(width, height);
    const tile_x = wg[0];
    const tile_y = wg[1];

    if ((features & FEATURE_F16) != 0) {
        const result = buildWgslF16(width, height, tile_x, tile_y);
        const dx = (width + tile_x - 1) / tile_x;
        const dy = (height + tile_y - 1) / tile_y;
        return .{
            .shader_ptr = result.ptr,
            .shader_len = result.len,
            .tile_x = tile_x,
            .tile_y = tile_y,
            .dispatch_x = dx,
            .dispatch_y = dy,
            .variant_tag = @intFromEnum(VariantTag.f16),
        };
    }

    if ((features & FEATURE_SUBGROUPS) != 0) {
        const result = buildWgslSubgroupShuffle(width, height, tile_x, tile_y);
        const dx = (width + tile_x - 1) / tile_x;
        const dy = (height + tile_y - 1) / tile_y;
        return .{
            .shader_ptr = result.ptr,
            .shader_len = result.len,
            .tile_x = tile_x,
            .tile_y = tile_y,
            .dispatch_x = dx,
            .dispatch_y = dy,
            .variant_tag = @intFromEnum(VariantTag.subgroup_shuffle),
        };
    }

    const result = buildWgsl(width, height, tile_x, tile_y);
    const dx = (width + tile_x - 1) / tile_x;
    const dy = (height + tile_y - 1) / tile_y;
    return .{
        .shader_ptr = result.ptr,
        .shader_len = result.len,
        .tile_x = tile_x,
        .tile_y = tile_y,
        .dispatch_x = dx,
        .dispatch_y = dy,
        .variant_tag = @intFromEnum(VariantTag.standard),
    };
}

const MAX_SEEDS: usize = 20;

var g_seed_cx: [MAX_SEEDS]u32 align(16) = [_]u32{0} ** MAX_SEEDS;
var g_seed_cy: [MAX_SEEDS]u32 align(16) = [_]u32{0} ** MAX_SEEDS;
var g_seed_sz: [MAX_SEEDS]u32 align(16) = [_]u32{0} ** MAX_SEEDS;
var g_seed_n: u32 = 0;

export fn gs_wasm_generate_seeds(width: u32, height: u32) u32 {
    @memset(&g_seed_cx, 0);
    @memset(&g_seed_cy, 0);
    @memset(&g_seed_sz, 0);

    const n_cells = @as(usize, width) * @as(usize, height);
    const num_seeds: usize = if (n_cells > 10000) 20 else 5;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const w_usize = @as(usize, width);
    const h_usize = @as(usize, height);

    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        g_seed_cx[s] = @intCast(rand.intRangeLessThan(usize, 5, w_usize - 5));
        g_seed_cy[s] = @intCast(rand.intRangeLessThan(usize, 5, h_usize - 5));
        g_seed_sz[s] = @intCast(rand.intRangeAtMost(usize, 2, 5));
    }

    g_seed_n = @intCast(num_seeds);
    return g_seed_n;
}

export fn gs_wasm_seed_cx() [*]const u32 { return &g_seed_cx; }
export fn gs_wasm_seed_cy() [*]const u32 { return &g_seed_cy; }
export fn gs_wasm_seed_sz() [*]const u32 { return &g_seed_sz; }
export fn gs_wasm_seed_count() u32 { return g_seed_n; }

pub fn main() void {}