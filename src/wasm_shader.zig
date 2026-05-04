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
    pearson = 4,
};

const FEATURE_SUBGROUPS: u32 = 1;
const FEATURE_F16: u32 = 2;

var g_buf: [16384]u8 = undefined;

fn buildWgsl(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgsl(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
    return .{ .ptr = &g_buf, .len = @intCast(result.len) };
}

fn buildWgslSubgroups(width: u32, height: u32, tile_x: u32, tile_y: u32) BufResult {
    const result = wgsl.generateWgslSubgroups(&g_buf, width, height, tile_x, tile_y) catch return .{ .ptr = &g_buf, .len = 0 };
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
    var best_tx: u32 = 16;
    var best_ty: u32 = 4;
    var best_waste: u64 = @as(u64, width % 16) + @as(u64, height % 4);

    for (CANDIDATE_TILES) |shape| {
        const tx = shape[0];
        const ty = shape[1];
        const waste = @as(u64, width % tx) + @as(u64, height % ty);
        if (waste < best_waste) {
            best_waste = waste;
            best_tx = tx;
            best_ty = ty;
        } else if (waste == best_waste) {
            const new_disp = @as(u64, (width + tx - 1) / tx) * @as(u64, (height + ty - 1) / ty);
            const old_disp = @as(u64, (width + best_tx - 1) / best_tx) * @as(u64, (height + best_ty - 1) / best_ty);
            if (new_disp > old_disp) {
                best_tx = tx;
                best_ty = ty;
            }
        }
    }

    return .{ .tile_x = best_tx, .tile_y = best_ty };
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
    if (width >= height * 2) {
        return .{ 32, 2 };
    }
    if (height >= width * 2) {
        return .{ 4, 16 };
    }
    return .{ 16, 4 };
}

export fn gs_wasm_get_best(width: u32, height: u32, features: u32) BestResult {
    const wg = selectWorkgroup(width, height);
    const tile_x = wg[0];
    const tile_y = wg[1];

    if ((features & FEATURE_SUBGROUPS) != 0) {
        const result = buildWgslSubgroups(width, height, tile_x, tile_y);
        const dx = (width + tile_x - 1) / tile_x;
        const dy = (height + tile_y - 1) / tile_y;
        return .{
            .shader_ptr = result.ptr,
            .shader_len = result.len,
            .tile_x = tile_x,
            .tile_y = tile_y,
            .dispatch_x = dx,
            .dispatch_y = dy,
            .variant_tag = @intFromEnum(VariantTag.subgroups),
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

pub fn main() void {}