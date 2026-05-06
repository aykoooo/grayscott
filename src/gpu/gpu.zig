const std = @import("std");
const c = @import("webgpu.zig").c;

const WGSL_BUF_SIZE: usize = 8192;
const POLL_MAX_ATTEMPTS: u32 = 100_000;

fn selectBestWorkgroup(width: u32, height: u32) void {
    const cells = @as(u64, width) * @as(u64, height);
    if (width >= height * 2) { g.wg_x = 32; g.wg_y = 2; return; }
    if (height >= width * 2) { g.wg_x = 4; g.wg_y = 16; return; }
    if (cells <= 200 * 200) { g.wg_x = 16; g.wg_y = 8; return; }
    if (width >= 250 and width <= 260 and height >= 250 and height <= 260) { g.wg_x = 32; g.wg_y = 2; return; }
    if (cells >= 400 * 400) { g.wg_x = 16; g.wg_y = 8; return; }
}

fn generateWgslCoarseSMEM(buf: []u8, w: u32, h: u32) ![]const u8 {
    const tx: u32 = 16;
    const ty: u32 = 4;
    const stride: u32 = tx * 2 + 2;
    const rows: u32 = ty + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\struct Params {{
        \\    da: f32,
        \\    db: f32,
        \\    dt: f32,
        \\    feed: f32,
        \\    kill: f32,
        \\}}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
\\const WIDTH: u32 = {0d}u;
        \\const HEIGHT: u32 = {1d}u;
        \\const TX: u32 = 16u;
        \\const TY: u32 = 4u;
        \\const STRIDE: u32 = {2d}u;
        \\var<workgroup> tile_u: array<f32, {3d}>;
        \\var<workgroup> tile_v: array<f32, {3d}>;
        \\@compute @workgroup_size(16, 4)
        \\fn main(@builtin(workgroup_id) gid: vec3<u32>,
        \\        @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = gid.x * 32u + lid.x;
        \\    let y = gid.y * TY + lid.y;
        \\    if (y >= HEIGHT) {{ return; }}
        \\    let xl = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let xr = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let yt = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let yb = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    if (x < WIDTH) {{
        \\        tile_u[ti] = u_in[y * WIDTH + x];
        \\        tile_v[ti] = v_in[y * WIDTH + x];
        \\    }}
        \\    let tiB = (lid.y + 1u) * STRIDE + (lid.x + 1u + TX);
        \\    let xB = x + TX;
        \\    if (xB < WIDTH) {{
        \\        tile_u[tiB] = u_in[y * WIDTH + xB];
        \\        tile_v[tiB] = v_in[y * WIDTH + xB];
        \\    }}
\\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + xl];
        \\        tile_v[hi] = v_in[y * WIDTH + xl];
        \\        if (lid.y == 0u) {{
        \\            tile_u[0] = u_in[yt * WIDTH + xl];
        \\            tile_v[0] = v_in[yt * WIDTH + xl];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE;
        \\            tile_u[ci] = u_in[yb * WIDTH + xl];
        \\            tile_v[ci] = v_in[yb * WIDTH + xl];
        \\        }}
        \\    }}
        \\    if (lid.x == TX - 1u) {{
        \\        let xB = x + TX;
        \\        let xBr = select(xB + 1u, 0u, xB + 1u >= WIDTH);
        \\        let hi = (lid.y + 1u) * STRIDE + (TX * 2u + 1u);
        \\        tile_u[hi] = u_in[y * WIDTH + xBr];
        \\        tile_v[hi] = v_in[y * WIDTH + xBr];
        \\        if (lid.y == 0u) {{
        \\            tile_u[TX * 2u + 1u] = u_in[yt * WIDTH + xBr];
        \\            tile_v[TX * 2u + 1u] = v_in[yt * WIDTH + xBr];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE + (TX * 2u + 1u);
        \\            tile_u[ci] = u_in[yb * WIDTH + xBr];
        \\            tile_v[ci] = v_in[yb * WIDTH + xBr];
        \\        }}
        \\    }}
        \\    if (lid.y == 0u) {{
        \\        tile_u[lid.x + 1u] = u_in[yt * WIDTH + x];
        \\        tile_v[lid.x + 1u] = v_in[yt * WIDTH + x];
        \\        tile_u[lid.x + 1u + TX] = u_in[yt * WIDTH + xB];
        \\        tile_v[lid.x + 1u + TX] = v_in[yt * WIDTH + xB];
        \\    }}
        \\    if (lid.y == TY - 1u) {{
        \\        let oh = (TY + 1u) * STRIDE + (lid.x + 1u);
        \\        tile_u[oh] = u_in[yb * WIDTH + x];
        \\        tile_v[oh] = v_in[yb * WIDTH + x];
        \\        tile_u[oh + TX] = u_in[yb * WIDTH + xB];
        \\        tile_v[oh + TX] = v_in[yb * WIDTH + xB];
        \\    }}
        \\    workgroupBarrier();
        \\    if (x < WIDTH) {{
        \\        let u_c = tile_u[ti]; let v_c = tile_v[ti];
\\    let card_u = tile_u[(lid.y+1u)*STRIDE+(lid.x)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)] + tile_u[(lid.y)*STRIDE+(lid.x+1u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)];
        \\    let card_v = tile_v[(lid.y+1u)*STRIDE+(lid.x)] + tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)] + tile_v[(lid.y)*STRIDE+(lid.x+1u)] + tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)];
        \\        let lap_u = fma(tile_u[(lid.y)*STRIDE+(lid.x+2u)]+tile_u[(lid.y)*STRIDE+(lid.x)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_u, 0.2, -u_c));
        \\        let lap_v = fma(tile_v[(lid.y)*STRIDE+(lid.x+2u)]+tile_v[(lid.y)*STRIDE+(lid.x)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_v, 0.2, -v_c));
        \\        let uvv = u_c * v_c * v_c;
        \\        let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\        let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\        let out_idx = y * WIDTH + x;
        \\        u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\        v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\    }}
\\    if (xB < WIDTH) {{
        \\        let u_cB = tile_u[tiB]; let v_cB = tile_v[tiB];
        \\        let cB_u = tile_u[(lid.y+1u)*STRIDE+(lid.x+TX)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u+TX)] + tile_u[(lid.y)*STRIDE+(lid.x+1u+TX)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u+TX)];
        \\        let cB_v = tile_v[(lid.y+1u)*STRIDE+(lid.x+TX)] + tile_v[(lid.y+1u)*STRIDE+(lid.x+2u+TX)] + tile_v[(lid.y)*STRIDE+(lid.x+1u+TX)] + tile_v[(lid.y+2u)*STRIDE+(lid.x+1u+TX)];
        \\        let lp_uB = fma(tile_u[(lid.y)*STRIDE+(lid.x+2u+TX)]+tile_u[(lid.y)*STRIDE+(lid.x+TX)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u+TX)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+TX)], 0.05, fma(cB_u, 0.2, -u_cB));
        \\        let lp_vB = fma(tile_v[(lid.y)*STRIDE+(lid.x+2u+TX)]+tile_v[(lid.y)*STRIDE+(lid.x+TX)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u+TX)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+TX)], 0.05, fma(cB_v, 0.2, -v_cB));
        \\        let uvvB = u_cB * v_cB * v_cB;
        \\        let u_nextB = u_cB + params.dt * (params.da * lp_uB - uvvB + params.feed * (1.0 - u_cB));
        \\        let v_nextB = v_cB + params.dt * (params.db * lp_vB + uvvB - (params.feed + params.kill) * v_cB);
        \\        let out_idxB = y * WIDTH + xB;
        \\        u_out[out_idxB] = clamp(u_nextB, 0.0, 1.0);
        \\        v_out[out_idxB] = clamp(v_nextB, 0.0, 1.0);
        \\    }}
        \\}}
    , .{ w, h, stride, tile_n });
}

// =============================================================================
// Global GPU state
// =============================================================================

const GpuState = struct {
    width: u32 = 0,
    height: u32 = 0,
    wg_x: u32 = 16,
    wg_y: u32 = 4,
    instance: c.WGPUInstance = null,
    adapter: c.WGPUAdapter = null,
    device: c.WGPUDevice = null,
    queue: c.WGPUQueue = null,
    shader_module: c.WGPUShaderModule = null,
    pipeline: c.WGPUComputePipeline = null,
    bind_group_layout: c.WGPUBindGroupLayout = null,
    pipeline_layout: c.WGPUPipelineLayout = null,
    buf_u0: c.WGPUBuffer = null,
    buf_u1: c.WGPUBuffer = null,
    buf_v0: c.WGPUBuffer = null,
    buf_v1: c.WGPUBuffer = null,
    buf_params: c.WGPUBuffer = null,
    buf_u_readback: c.WGPUBuffer = null,
    bind_group_even: c.WGPUBindGroup = null,
    bind_group_odd: c.WGPUBindGroup = null,
    current_u: u32 = 0,
    step_count: u32 = 0,
    initialized: bool = false,
    has_f16: bool = false,
    pearson_mode: bool = false,
    shader_flags: u32 = 0,
    buf_feed_map: c.WGPUBuffer = null,
    buf_kill_map: c.WGPUBuffer = null,
    coarse_factor: u32 = 1,
};

const SHADER_VEC2_SMEM: u32 = 1;

const SHADER_F16: u32 = 2;

var g: GpuState = .{};

// =============================================================================
// Async callback state (global because callbacks are C functions)
// =============================================================================

var g_cb_adapter: c.WGPUAdapter = null;
var g_cb_device: c.WGPUDevice = null;

fn adapterCallback(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = message;
    _ = ud1;
    _ = ud2;
    if (status == c.WGPURequestAdapterStatus_Success) {
        g_cb_adapter = adapter;
    }
}

fn deviceCallback(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = message;
    _ = ud1;
    _ = ud2;
    if (status == c.WGPURequestDeviceStatus_Success) {
        g_cb_device = device;
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn strv(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

fn cstrv(s: [*:0]const u8) c.WGPUStringView {
    return .{ .data = s, .length = std.mem.len(s) };
}

fn waitFuture(inst: c.WGPUInstance, _fut: c.WGPUFuture) bool {
    _ = _fut;
    for (0..POLL_MAX_ATTEMPTS) |_| {
        c.wgpuInstanceProcessEvents(inst);
        if (g_cb_adapter != null or g_cb_device != null) return true;
    }
    return false;
}

fn makeBuffer(device: c.WGPUDevice, usage: u64, size: u64, label: []const u8) c.WGPUBuffer {
    return c.wgpuDeviceCreateBuffer(device, &.{
        .nextInChain = null,
        .label = strv(label),
        .usage = usage,
        .size = size,
        .mappedAtCreation = c.WGPU_FALSE,
    });
}

fn makeBindGroupEntry(binding: u32, buffer: c.WGPUBuffer, offset: u64, wsize: u64) c.WGPUBindGroupEntry {
    return .{
        .nextInChain = null,
        .binding = binding,
        .buffer = buffer,
        .offset = offset,
        .size = wsize,
        .sampler = null,
        .textureView = null,
    };
}

fn makeBglEntry(binding: u32, ty: c.WGPUBufferBindingType) c.WGPUBindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = c.WGPUShaderStage_Compute,
        .buffer = .{ .type = ty, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
        .sampler = .{ .type = c.WGPUSamplerBindingType_BindingNotUsed },
        .texture = .{ .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
        .storageTexture = .{ .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
    };
}

// =============================================================================
// WGSL shader generation (runtime width/height substitution)
// =============================================================================

fn generateWgsl(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
    const stride: u32 = tile_x + 2;
    const rows: u32 = tile_y + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\struct Params {{
        \\    da: f32,
        \\    db: f32,
        \\    dt: f32,
        \\    feed: f32,
        \\    kill: f32,
        \\}}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\const WIDTH: u32 = {d}u;
        \\const HEIGHT: u32 = {d}u;
        \\const TX: u32 = {d}u;
        \\const TY: u32 = {d}u;
        \\const STRIDE: u32 = {d}u;
        \\var<workgroup> tile_u: array<f32, {d}>;
        \\var<workgroup> tile_v: array<f32, {d}>;
        \\@compute @workgroup_size({d}, {d})
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>,
        \\        @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x;
        \\    let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_u[ti] = u_in[y * WIDTH + x];
        \\    tile_v[ti] = v_in[y * WIDTH + x];
        \\    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + x_l];
        \\        tile_v[hi] = v_in[y * WIDTH + x_l];
        \\        if (lid.y == 0u) {{
        \\            tile_u[0] = u_in[y_t * WIDTH + x_l];
        \\            tile_v[0] = v_in[y_t * WIDTH + x_l];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE;
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_l];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_l];
        \\        }}
        \\    }}
        \\    if (lid.x == TX - 1u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + (TX + 1u);
        \\        tile_u[hi] = u_in[y * WIDTH + x_r];
        \\        tile_v[hi] = v_in[y * WIDTH + x_r];
        \\        if (lid.y == 0u) {{
        \\            let ci = TX + 1u;
        \\            tile_u[ci] = u_in[y_t * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_t * WIDTH + x_r];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE + (TX + 1u);
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_r];
        \\        }}
        \\    }}
        \\    if (lid.y == 0u) {{
        \\        let hi = lid.x + 1u;
        \\        tile_u[hi] = u_in[y_t * WIDTH + x];
        \\        tile_v[hi] = v_in[y_t * WIDTH + x];
        \\    }}
        \\    if (lid.y == TY - 1u) {{
        \\        let hi = (TY + 1u) * STRIDE + (lid.x + 1u);
        \\        tile_u[hi] = u_in[y_b * WIDTH + x];
        \\        tile_v[hi] = v_in[y_b * WIDTH + x];
        \\    }}
\\    workgroupBarrier();
    \\    let u_c = tile_u[ti]; let v_c = tile_v[ti];
    \\    let card_u = tile_u[(lid.y+1u)*STRIDE+(lid.x)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)] + tile_u[(lid.y)*STRIDE+(lid.x+1u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)];
    \\    let card_v = tile_v[(lid.y+1u)*STRIDE+(lid.x)] + tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)] + tile_v[(lid.y)*STRIDE+(lid.x+1u)] + tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)];
    \\    let lap_u = fma(tile_u[(lid.y)*STRIDE+(lid.x+2u)]+tile_u[(lid.y)*STRIDE+(lid.x)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_u, 0.2, -u_c));
    \\    let lap_v = fma(tile_v[(lid.y)*STRIDE+(lid.x+2u)]+tile_v[(lid.y)*STRIDE+(lid.x)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_v, 0.2, -v_c));
    \\    let uvv = u_c * v_c * v_c;
    \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_n, tile_x, tile_y });
}

fn generateWgslPearson(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
    const stride: u32 = tile_x + 2;
    const rows: u32 = tile_y + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\struct Params {{
        \\    da: f32,
        \\    db: f32,
        \\    dt: f32,
        \\}}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\@group(0) @binding(5) var<storage, read> feed_map: array<f32>;
        \\@group(0) @binding(6) var<storage, read> kill_map: array<f32>;
        \\const WIDTH: u32 = {d}u;
        \\const HEIGHT: u32 = {d}u;
        \\const TX: u32 = {d}u;
        \\const TY: u32 = {d}u;
        \\const STRIDE: u32 = {d}u;
        \\var<workgroup> tile_u: array<f32, {d}>;
        \\var<workgroup> tile_v: array<f32, {d}>;
        \\@compute @workgroup_size({d}, {d})
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>,
        \\        @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x;
        \\    let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_u[ti] = u_in[y * WIDTH + x];
        \\    tile_v[ti] = v_in[y * WIDTH + x];
        \\    let x_l = max(x, 1u) - 1u;
        \\    let x_r = min(x + 1u, WIDTH - 1u);
        \\    let y_t = max(y, 1u) - 1u;
        \\    let y_b = min(y + 1u, HEIGHT - 1u);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + x_l];
        \\        tile_v[hi] = v_in[y * WIDTH + x_l];
        \\        if (lid.y == 0u) {{
        \\            tile_u[0] = u_in[y_t * WIDTH + x_l];
        \\            tile_v[0] = v_in[y_t * WIDTH + x_l];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE;
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_l];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_l];
        \\        }}
        \\    }}
        \\    if (lid.x == TX - 1u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + (TX + 1u);
        \\        tile_u[hi] = u_in[y * WIDTH + x_r];
        \\        tile_v[hi] = v_in[y * WIDTH + x_r];
        \\        if (lid.y == 0u) {{
        \\            let ci = TX + 1u;
        \\            tile_u[ci] = u_in[y_t * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_t * WIDTH + x_r];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE + (TX + 1u);
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_r];
        \\        }}
        \\    }}
        \\    if (lid.y == 0u) {{
        \\        let hi = lid.x + 1u;
        \\        tile_u[hi] = u_in[y_t * WIDTH + x];
        \\        tile_v[hi] = v_in[y_t * WIDTH + x];
        \\    }}
        \\    if (lid.y == TY - 1u) {{
        \\        let hi = (TY + 1u) * STRIDE + (lid.x + 1u);
        \\        tile_u[hi] = u_in[y_b * WIDTH + x];
        \\        tile_v[hi] = v_in[y_b * WIDTH + x];
        \\    }}
\\    workgroupBarrier();
    \\    let u_c = tile_u[ti]; let v_c = tile_v[ti];
    \\    let card_u = (tile_u[(lid.y+1u)*STRIDE+(lid.x)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)]) + (tile_u[(lid.y)*STRIDE+(lid.x+1u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)]);
    \\    let card_v = (tile_v[(lid.y+1u)*STRIDE+(lid.x)] + tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)]) + (tile_v[(lid.y)*STRIDE+(lid.x+1u)] + tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)]);
    \\    let lap_u = fma(tile_u[(lid.y)*STRIDE+(lid.x+2u)]+tile_u[(lid.y)*STRIDE+(lid.x)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_u, 0.2, -u_c));
    \\    let lap_v = fma(tile_v[(lid.y)*STRIDE+(lid.x+2u)]+tile_v[(lid.y)*STRIDE+(lid.x)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_v, 0.2, -v_c));
    \\    let f = feed_map[y];
        \\    let k = kill_map[x];
        \\    let uvv = u_c * v_c * v_c;
        \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + f * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (f + k) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_n, tile_x, tile_y });
}

fn generateWgslVec2(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
    const stride: u32 = tile_x + 2;
    const rows: u32 = tile_y + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\struct Params {{
        \\    da: f32,
        \\    db: f32,
        \\    dt: f32,
        \\    feed: f32,
        \\    kill: f32,
        \\}}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\const WIDTH: u32 = {d}u;
        \\const HEIGHT: u32 = {d}u;
        \\const TX: u32 = {d}u;
        \\const TY: u32 = {d}u;
        \\const STRIDE: u32 = {d}u;
        \\var<workgroup> tile_uv: array<vec2<f32>, {d}>;
        \\@compute @workgroup_size({d}, {d})
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>,
        \\        @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x;
        \\    let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_uv[ti] = vec2(u_in[y * WIDTH + x], v_in[y * WIDTH + x]);
        \\    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_uv[hi] = vec2(u_in[y * WIDTH + x_l], v_in[y * WIDTH + x_l]);
        \\        if (lid.y == 0u) {{
        \\            tile_uv[0] = vec2(u_in[y_t * WIDTH + x_l], v_in[y_t * WIDTH + x_l]);
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE;
        \\            tile_uv[ci] = vec2(u_in[y_b * WIDTH + x_l], v_in[y_b * WIDTH + x_l]);
        \\        }}
        \\    }}
        \\    if (lid.x == TX - 1u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + (TX + 1u);
        \\        tile_uv[hi] = vec2(u_in[y * WIDTH + x_r], v_in[y * WIDTH + x_r]);
        \\        if (lid.y == 0u) {{
        \\            let ci = TX + 1u;
        \\            tile_uv[ci] = vec2(u_in[y_t * WIDTH + x_r], v_in[y_t * WIDTH + x_r]);
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE + (TX + 1u);
        \\            tile_uv[ci] = vec2(u_in[y_b * WIDTH + x_r], v_in[y_b * WIDTH + x_r]);
        \\        }}
        \\    }}
        \\    if (lid.y == 0u) {{
        \\        let hi = lid.x + 1u;
        \\        tile_uv[hi] = vec2(u_in[y_t * WIDTH + x], v_in[y_t * WIDTH + x]);
        \\    }}
        \\    if (lid.y == TY - 1u) {{
        \\        let hi = (TY + 1u) * STRIDE + (lid.x + 1u);
        \\        tile_uv[hi] = vec2(u_in[y_b * WIDTH + x], v_in[y_b * WIDTH + x]);
        \\    }}
        \\    workgroupBarrier();
        \\    let uv_c = tile_uv[ti];
        \\    let n_l = tile_uv[(lid.y+1u)*STRIDE+(lid.x)];
        \\    let n_r = tile_uv[(lid.y+1u)*STRIDE+(lid.x+2u)];
        \\    let n_t = tile_uv[(lid.y)*STRIDE+(lid.x+1u)];
        \\    let n_b = tile_uv[(lid.y+2u)*STRIDE+(lid.x+1u)];
        \\    let n_ne = tile_uv[(lid.y)*STRIDE+(lid.x+2u)];
        \\    let n_nw = tile_uv[(lid.y)*STRIDE+(lid.x)];
        \\    let n_se = tile_uv[(lid.y+2u)*STRIDE+(lid.x+2u)];
        \\    let n_sw = tile_uv[(lid.y+2u)*STRIDE+(lid.x)];
        \\    let card_u = (n_l.x + n_r.x) + (n_t.x + n_b.x);
        \\    let lap_u = fma(n_ne.x+n_nw.x+n_se.x+n_sw.x, 0.05, fma(card_u, 0.2, -uv_c.x));
        \\    let card_v = (n_l.y + n_r.y) + (n_t.y + n_b.y);
        \\    let lap_v = fma(n_ne.y+n_nw.y+n_se.y+n_sw.y, 0.05, fma(card_v, 0.2, -uv_c.y));
        \\    let uvv = uv_c.x * uv_c.y * uv_c.y;
        \\    let u_next = uv_c.x + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - uv_c.x));
        \\    let v_next = uv_c.y + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * uv_c.y);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_x, tile_y });
}

// =============================================================================
// Exported API
// =============================================================================

fn generateWgslF16(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
    const stride: u32 = tile_x + 2;
    const rows: u32 = tile_y + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\enable f16;
        \\struct Params {{
        \\    da: f32,
        \\    db: f32,
        \\    dt: f32,
        \\    feed: f32,
        \\    kill: f32,
        \\}}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f16>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f16>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f16>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f16>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\const WIDTH: u32 = {d}u;
        \\const HEIGHT: u32 = {d}u;
        \\const TX: u32 = {d}u;
        \\const TY: u32 = {d}u;
        \\const STRIDE: u32 = {d}u;
        \\var<workgroup> tile_u: array<f16, {d}>;
        \\var<workgroup> tile_v: array<f16, {d}>;
        \\@compute @workgroup_size({d}, {d})
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>,
        \\        @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x;
        \\    let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_u[ti] = u_in[y * WIDTH + x];
        \\    tile_v[ti] = v_in[y * WIDTH + x];
        \\    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + x_l];
        \\        tile_v[hi] = v_in[y * WIDTH + x_l];
        \\        if (lid.y == 0u) {{
        \\            tile_u[0] = u_in[y_t * WIDTH + x_l];
        \\            tile_v[0] = v_in[y_t * WIDTH + x_l];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE;
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_l];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_l];
        \\        }}
        \\    }}
        \\    if (lid.x == TX - 1u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + (TX + 1u);
        \\        tile_u[hi] = u_in[y * WIDTH + x_r];
        \\        tile_v[hi] = v_in[y * WIDTH + x_r];
        \\        if (lid.y == 0u) {{
        \\            let ci = TX + 1u;
        \\            tile_u[ci] = u_in[y_t * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_t * WIDTH + x_r];
        \\        }}
        \\        if (lid.y == TY - 1u) {{
        \\            let ci = (TY + 1u) * STRIDE + (TX + 1u);
        \\            tile_u[ci] = u_in[y_b * WIDTH + x_r];
        \\            tile_v[ci] = v_in[y_b * WIDTH + x_r];
        \\        }}
        \\    }}
        \\    if (lid.y == 0u) {{
        \\        let hi = lid.x + 1u;
        \\        tile_u[hi] = u_in[y_t * WIDTH + x];
        \\        tile_v[hi] = v_in[y_t * WIDTH + x];
        \\    }}
        \\    if (lid.y == TY - 1u) {{
        \\        let hi = (TY + 1u) * STRIDE + (lid.x + 1u);
        \\        tile_u[hi] = u_in[y_b * WIDTH + x];
        \\        tile_v[hi] = v_in[y_b * WIDTH + x];
        \\    }}
        \\    workgroupBarrier();
        \\    let u_c = f32(tile_u[ti]); let v_c = f32(tile_v[ti]);
        \\    let card_u = f32(tile_u[(lid.y+1u)*STRIDE+(lid.x)]+tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)]) + f32(tile_u[(lid.y)*STRIDE+(lid.x+1u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)]);
        \\    let card_v = f32(tile_v[(lid.y+1u)*STRIDE+(lid.x)]+tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)]) + f32(tile_v[(lid.y)*STRIDE+(lid.x+1u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)]);
        \\    let lap_u = fma(f32(tile_u[(lid.y)*STRIDE+(lid.x+2u)]+tile_u[(lid.y)*STRIDE+(lid.x)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x)]), 0.05, fma(card_u, 0.2, -u_c));
        \\    let lap_v = fma(f32(tile_v[(lid.y)*STRIDE+(lid.x+2u)]+tile_v[(lid.y)*STRIDE+(lid.x)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x)]), 0.05, fma(card_v, 0.2, -v_c));
        \\    let uvv = u_c * v_c * v_c;
        \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = f16(clamp(u_next, 0.0, 1.0));
        \\    v_out[out_idx] = f16(clamp(v_next, 0.0, 1.0));
        \\}}
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_n, tile_x, tile_y });
}

pub export fn gs_gpu_init_shape(width: u32, height: u32, tile_x: u32, tile_y: u32) bool {
    g.wg_x = tile_x;
    g.wg_y = tile_y;
    return gs_gpu_init(width, height);
}

pub export fn gs_gpu_init_shape_vec2(width: u32, height: u32, tile_x: u32, tile_y: u32) bool {
    g.wg_x = tile_x;
    g.wg_y = tile_y;
    g.shader_flags |= SHADER_VEC2_SMEM;
    const ok = gs_gpu_init(width, height);
    g.shader_flags &= ~SHADER_VEC2_SMEM;
    return ok;
}

pub export fn gs_gpu_init(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;

    g.width = width;
    g.height = height;
    selectBestWorkgroup(width, height);

    // ---- Instance ----
    g.instance = c.wgpuCreateInstance(null);
    if (g.instance == null) return false;

    // ---- Adapter (async + wait) ----
    g_cb_adapter = null;
    const adapter_cb_info: c.WGPURequestAdapterCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = adapterCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const adapter_fut = c.wgpuInstanceRequestAdapter(g.instance, null, adapter_cb_info);
    if (!waitFuture(g.instance, adapter_fut)) return false;
    g.adapter = g_cb_adapter;
    if (g.adapter == null) return false;

    // ---- Query f16 support (Phase K retry) ----
    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;
    std.debug.print("f16 support: {s}\n", .{if (g.has_f16) "YES" else "NO"});

    // ---- Device (async + wait) ----
    g_cb_device = null;
    var f16_features: [1]c.WGPUFeatureName = undefined;
    var dev_desc: c.WGPUDeviceDescriptor = undefined;
    const dev_desc_ptr: ?*const c.WGPUDeviceDescriptor = if (g.has_f16) desc_ptr: {
        f16_features[0] = c.WGPUFeatureName_ShaderF16;
        dev_desc = .{
            .nextInChain = null,
            .label = strv("device"),
            .requiredFeatureCount = 1,
            .requiredFeatures = &f16_features,
            .requiredLimits = null,
            .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor),
            .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo),
            .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo),
        };
        break :desc_ptr &dev_desc;
    } else null;
    const device_cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = deviceCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const device_fut = c.wgpuAdapterRequestDevice(g.adapter, dev_desc_ptr, device_cb_info);
    if (!waitFuture(g.instance, device_fut)) return false;
    g.device = g_cb_device;
    if (g.device == null) return false;

    g.queue = c.wgpuDeviceGetQueue(g.device);
    if (g.queue == null) return false;

    // ---- Shader ----
    var wgsl_buf: [WGSL_BUF_SIZE]u8 = undefined;
    const wgsl_src = if (g.shader_flags & SHADER_VEC2_SMEM != 0)
        generateWgslVec2(&wgsl_buf, width, height, g.wg_x, g.wg_y) catch return false
    else
        generateWgsl(&wgsl_buf, width, height, g.wg_x, g.wg_y) catch return false;

    var shader_source: c.WGPUShaderSourceWGSL = undefined;
    shader_source.chain.next = null;
    shader_source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    shader_source.code = strv(wgsl_src);

    const sm_desc: c.WGPUShaderModuleDescriptor = .{
        .nextInChain = &shader_source.chain,
        .label = cstrv("gray_scott"),
    };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm_desc);
    if (g.shader_module == null) return false;

    // ---- Buffers ----
    const grid_bytes: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f32);
    const storage_usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, storage_usage, grid_bytes, "u0");
    g.buf_u1 = makeBuffer(g.device, storage_usage, grid_bytes, "u1");
    g.buf_v0 = makeBuffer(g.device, storage_usage, grid_bytes, "v0");
    g.buf_v1 = makeBuffer(g.device, storage_usage, grid_bytes, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpu), "params");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, grid_bytes, "u_readback");

    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or
        g.buf_params == null or g.buf_u_readback == null) return false;

    // ---- Initialize grid (fill 1.0 / 0.0 + seeds) ----
    var init_u = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_u);
    var init_v = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_v);

    @memset(init_u, 1.0);
    @memset(init_v, 0.0);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const num_seeds: usize = if (width * height > 10000) 20 else 5;
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, width - 5);
        const cy = rand.intRangeLessThan(usize, 5, height - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        const half = sz / 2;
        const x0 = if (cx > half) cx - half else 0;
        const x1 = @min(cx + half, width);
        const y0 = if (cy > half) cy - half else 0;
        const y1 = @min(cy + half, height);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) {
                init_u[yy * width + xx] = 0.5;
                init_v[yy * width + xx] = 1.0;
            }
        }
    }

    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, init_u.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, init_u.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, init_v.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, init_v.ptr, grid_bytes);

    // ---- Bind group layout ----
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(2, c.WGPUBufferBindingType_Storage),
        makeBglEntry(3, c.WGPUBufferBindingType_Storage),
        makeBglEntry(4, c.WGPUBufferBindingType_Uniform),
    };
    const bgl_desc: c.WGPUBindGroupLayoutDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bgl"),
        .entryCount = entries.len,
        .entries = &entries,
    };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bgl_desc);
    if (g.bind_group_layout == null) return false;

    // ---- Pipeline layout ----
    const pll_desc: c.WGPUPipelineLayoutDescriptor = .{
        .nextInChain = null,
        .label = cstrv("pll"),
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &g.bind_group_layout,
        .immediateSize = 0,
    };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pll_desc);
    if (g.pipeline_layout == null) return false;

    // ---- Compute pipeline ----
    const cs: c.WGPUComputeState = .{
        .nextInChain = null,
        .module = g.shader_module,
        .entryPoint = cstrv("main"),
        .constantCount = 0,
        .constants = null,
    };
    const cp_desc: c.WGPUComputePipelineDescriptor = .{
        .nextInChain = null,
        .label = cstrv("pipeline"),
        .layout = g.pipeline_layout,
        .compute = cs,
    };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp_desc);
    if (g.pipeline == null) return false;

    // ---- Bind groups (ping-pong) ----
    const whole_size = c.WGPU_WHOLE_SIZE;
    const bg_entries_even = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u0, 0, whole_size),
        makeBindGroupEntry(1, g.buf_v0, 0, whole_size),
        makeBindGroupEntry(2, g.buf_u1, 0, whole_size),
        makeBindGroupEntry(3, g.buf_v1, 0, whole_size),
        makeBindGroupEntry(4, g.buf_params, 0, whole_size),
    };
    const bg_desc_even: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bg_even"),
        .layout = g.bind_group_layout,
        .entryCount = bg_entries_even.len,
        .entries = &bg_entries_even,
    };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_even);

    const bg_entries_odd = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u1, 0, whole_size),
        makeBindGroupEntry(1, g.buf_v1, 0, whole_size),
        makeBindGroupEntry(2, g.buf_u0, 0, whole_size),
        makeBindGroupEntry(3, g.buf_v0, 0, whole_size),
        makeBindGroupEntry(4, g.buf_params, 0, whole_size),
    };
    const bg_desc_odd: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bg_odd"),
        .layout = g.bind_group_layout,
        .entryCount = bg_entries_odd.len,
        .entries = &bg_entries_odd,
    };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_odd);

    if (g.bind_group_even == null or g.bind_group_odd == null) return false;

    g.current_u = 0;
    g.step_count = 0;
    g.initialized = true;
    return true;
}

const ParamsGpu = extern struct {
    da: f32,
    db: f32,
    dt: f32,
    feed: f32,
    kill: f32,
};

pub export fn gs_gpu_step(da: f32, db: f32, dt: f32, feed: f32, kill: f32) void {
    if (!g.initialized) return;
    gs_gpu_steps(da, db, dt, feed, kill, 1);
}

pub export fn gs_gpu_steps(da: f32, db: f32, dt: f32, feed: f32, kill: f32, n: u32) void {
    if (!g.initialized or n == 0) return;

    const params = ParamsGpu{ .da = da, .db = db, .dt = dt, .feed = feed, .kill = kill };
    c.wgpuQueueWriteBuffer(g.queue, g.buf_params, 0, &params, @sizeOf(ParamsGpu));

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return;

    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, null);
    c.wgpuComputePassEncoderSetPipeline(pass, g.pipeline);

    const eff_x = if (g.coarse_factor > 0) g.wg_x * g.coarse_factor else g.wg_x;
    const wg_x = (g.width + eff_x - 1) / eff_x;
    const wg_y = (g.height + g.wg_y - 1) / g.wg_y;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const bg = if (g.current_u == 0) g.bind_group_even else g.bind_group_odd;
        c.wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, null);
        c.wgpuComputePassEncoderDispatchWorkgroups(pass, wg_x, wg_y, 1);

        g.current_u = 1 - g.current_u;
        g.step_count += 1;
    }

    c.wgpuComputePassEncoderEnd(pass);

    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return;

    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);
}

pub fn gs_gpu_init_pearson(width: u32, height: u32, f_min: f32, f_max: f32, k_min: f32, k_max: f32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;

    g.width = width;
    g.height = height;
    g.pearson_mode = true;

    // ---- Shared: Instance → Adapter → Device → Queue (identical to normal init) ----
    g.instance = c.wgpuCreateInstance(null);
    if (g.instance == null) return false;

    g_cb_adapter = null;
    const adapter_cb_info: c.WGPURequestAdapterCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = adapterCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const adapter_fut = c.wgpuInstanceRequestAdapter(g.instance, null, adapter_cb_info);
    if (!waitFuture(g.instance, adapter_fut)) return false;
    g.adapter = g_cb_adapter;
    if (g.adapter == null) return false;

    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;

    g_cb_device = null;
    var f16_features: [1]c.WGPUFeatureName = undefined;
    var dev_desc: c.WGPUDeviceDescriptor = undefined;
    const dev_desc_ptr: ?*const c.WGPUDeviceDescriptor = if (g.has_f16) desc_ptr: {
        f16_features[0] = c.WGPUFeatureName_ShaderF16;
        dev_desc = .{
            .nextInChain = null,
            .label = strv("device"),
            .requiredFeatureCount = 1,
            .requiredFeatures = &f16_features,
            .requiredLimits = null,
            .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor),
            .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo),
            .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo),
        };
        break :desc_ptr &dev_desc;
    } else null;
    const device_cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = deviceCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const device_fut = c.wgpuAdapterRequestDevice(g.adapter, dev_desc_ptr, device_cb_info);
    if (!waitFuture(g.instance, device_fut)) return false;
    g.device = g_cb_device;
    if (g.device == null) return false;

    g.queue = c.wgpuDeviceGetQueue(g.device);
    if (g.queue == null) return false;

    // ---- Shader (Neumann boundaries + spatial feed/kill buffers) ----
    var wgsl_buf: [WGSL_BUF_SIZE]u8 = undefined;
    const wgsl_src = generateWgslPearson(&wgsl_buf, width, height, g.wg_x, g.wg_y) catch return false;

    var shader_source: c.WGPUShaderSourceWGSL = undefined;
    shader_source.chain.next = null;
    shader_source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    shader_source.code = strv(wgsl_src);

    const sm_desc: c.WGPUShaderModuleDescriptor = .{
        .nextInChain = &shader_source.chain,
        .label = cstrv("gray_scott_pearson"),
    };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm_desc);
    if (g.shader_module == null) return false;

    // ---- Buffers (U/V grid same as normal, plus feed/kill maps) ----
    const grid_bytes: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f32);
    const storage_usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, storage_usage, grid_bytes, "u0");
    g.buf_u1 = makeBuffer(g.device, storage_usage, grid_bytes, "u1");
    g.buf_v0 = makeBuffer(g.device, storage_usage, grid_bytes, "v0");
    g.buf_v1 = makeBuffer(g.device, storage_usage, grid_bytes, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpuPearson), "params");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, grid_bytes, "u_readback");

    const feed_bytes: u64 = @as(u64, height) * @sizeOf(f32);
    const kill_bytes: u64 = @as(u64, width) * @sizeOf(f32);
    g.buf_feed_map = makeBuffer(g.device, storage_usage, feed_bytes, "feed_map");
    g.buf_kill_map = makeBuffer(g.device, storage_usage, kill_bytes, "kill_map");

    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or
        g.buf_params == null or g.buf_u_readback == null or g.buf_feed_map == null or g.buf_kill_map == null) return false;

    // ---- Upload feed/kill gradient arrays ----
    var feed_data = std.heap.page_allocator.alloc(f32, height) catch return false;
    defer std.heap.page_allocator.free(feed_data);
    var kill_data = std.heap.page_allocator.alloc(f32, width) catch return false;
    defer std.heap.page_allocator.free(kill_data);

    const hf = @as(f32, @floatFromInt(height));
    const wf = @as(f32, @floatFromInt(width));
    for (0..height) |i| {
        feed_data[i] = f_min + (@as(f32, @floatFromInt(i)) / hf) * (f_max - f_min);
    }
    for (0..width) |i| {
        kill_data[i] = k_min + (@as(f32, @floatFromInt(i)) / wf) * (k_max - k_min);
    }
    c.wgpuQueueWriteBuffer(g.queue, g.buf_feed_map, 0, feed_data.ptr, feed_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_kill_map, 0, kill_data.ptr, kill_bytes);

    // ---- Initialize grid (fill 1.0 / 0.0 + random seeds) ----
    var init_u = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_u);
    var init_v = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_v);

    @memset(init_u, 1.0);
    @memset(init_v, 0.0);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand = prng.random();
    const num_seeds: usize = @min((width * height) / 500, 800);
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, width - 5);
        const cy = rand.intRangeLessThan(usize, 5, height - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        const half = sz / 2;
        const x0 = if (cx > half) cx - half else 0;
        const x1 = @min(cx + half, width);
        const y0 = if (cy > half) cy - half else 0;
        const y1 = @min(cy + half, height);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) {
                init_u[yy * width + xx] = 0.5;
                init_v[yy * width + xx] = 1.0;
            }
        }
    }

    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, init_u.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, init_u.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, init_v.ptr, grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, init_v.ptr, grid_bytes);

    // ---- Bind group layout (7 entries: U/V in/out, params, feed_map, kill_map) ----
    const entries = [_]c.WGPUBindGroupLayoutEntry{
        makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(2, c.WGPUBufferBindingType_Storage),
        makeBglEntry(3, c.WGPUBufferBindingType_Storage),
        makeBglEntry(4, c.WGPUBufferBindingType_Uniform),
        makeBglEntry(5, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(6, c.WGPUBufferBindingType_ReadOnlyStorage),
    };
    const bgl_desc: c.WGPUBindGroupLayoutDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bgl_pearson"),
        .entryCount = entries.len,
        .entries = &entries,
    };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bgl_desc);
    if (g.bind_group_layout == null) return false;

    // ---- Pipeline layout ----
    const pll_desc: c.WGPUPipelineLayoutDescriptor = .{
        .nextInChain = null,
        .label = cstrv("pll_pearson"),
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &g.bind_group_layout,
        .immediateSize = 0,
    };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pll_desc);
    if (g.pipeline_layout == null) return false;

    // ---- Compute pipeline ----
    const cs: c.WGPUComputeState = .{
        .nextInChain = null,
        .module = g.shader_module,
        .entryPoint = cstrv("main"),
        .constantCount = 0,
        .constants = null,
    };
    const cp_desc: c.WGPUComputePipelineDescriptor = .{
        .nextInChain = null,
        .label = cstrv("pipeline_pearson"),
        .layout = g.pipeline_layout,
        .compute = cs,
    };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp_desc);
    if (g.pipeline == null) return false;

    // ---- Bind groups (ping-pong with feed/kill maps always included) ----
    const whole_size = c.WGPU_WHOLE_SIZE;
    const bg_entries_even = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u0, 0, whole_size),
        makeBindGroupEntry(1, g.buf_v0, 0, whole_size),
        makeBindGroupEntry(2, g.buf_u1, 0, whole_size),
        makeBindGroupEntry(3, g.buf_v1, 0, whole_size),
        makeBindGroupEntry(4, g.buf_params, 0, whole_size),
        makeBindGroupEntry(5, g.buf_feed_map, 0, whole_size),
        makeBindGroupEntry(6, g.buf_kill_map, 0, whole_size),
    };
    const bg_desc_even: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bg_even_pearson"),
        .layout = g.bind_group_layout,
        .entryCount = bg_entries_even.len,
        .entries = &bg_entries_even,
    };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_even);

    const bg_entries_odd = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u1, 0, whole_size),
        makeBindGroupEntry(1, g.buf_v1, 0, whole_size),
        makeBindGroupEntry(2, g.buf_u0, 0, whole_size),
        makeBindGroupEntry(3, g.buf_v0, 0, whole_size),
        makeBindGroupEntry(4, g.buf_params, 0, whole_size),
        makeBindGroupEntry(5, g.buf_feed_map, 0, whole_size),
        makeBindGroupEntry(6, g.buf_kill_map, 0, whole_size),
    };
    const bg_desc_odd: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null,
        .label = cstrv("bg_odd_pearson"),
        .layout = g.bind_group_layout,
        .entryCount = bg_entries_odd.len,
        .entries = &bg_entries_odd,
    };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_odd);

    if (g.bind_group_even == null or g.bind_group_odd == null) return false;

    g.current_u = 0;
    g.step_count = 0;
    g.initialized = true;
    return true;
}

const ParamsGpuPearson = extern struct {
    da: f32,
    db: f32,
    dt: f32,
};

pub export fn gs_gpu_steps_pearson(da: f32, db: f32, dt: f32, n: u32) void {
    if (!g.initialized or !g.pearson_mode or n == 0) return;

    const params = ParamsGpuPearson{ .da = da, .db = db, .dt = dt };
    c.wgpuQueueWriteBuffer(g.queue, g.buf_params, 0, &params, @sizeOf(ParamsGpuPearson));

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return;

    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, null);
    c.wgpuComputePassEncoderSetPipeline(pass, g.pipeline);

    const wg_x = (g.width + g.wg_x - 1) / g.wg_x;
    const wg_y = (g.height + g.wg_y - 1) / g.wg_y;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const bg = if (g.current_u == 0) g.bind_group_even else g.bind_group_odd;
        c.wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, null);
        c.wgpuComputePassEncoderDispatchWorkgroups(pass, wg_x, wg_y, 1);

        g.current_u = 1 - g.current_u;
        g.step_count += 1;
    }

    c.wgpuComputePassEncoderEnd(pass);

    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return;

    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);
}

pub fn gs_gpu_read_result_v(buf_ptr: [*]u8, buf_len: usize) u32 {
    if (!g.initialized) return 0;
    const grid_bytes: u64 = @as(u64, g.width) * @as(u64, g.height) * @sizeOf(f32);
    if (buf_len < grid_bytes) return 0;

    const src_v = if (g.current_u == 0) g.buf_v0 else g.buf_v1;

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return 0;
    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, src_v, 0, g.buf_u_readback, 0, grid_bytes);
    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return 0;
    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);

    var map_completed: bool = false;
    const MapCtx = struct { completed: *bool };
    const mapCallback = struct {
        fn cb(status: c.WGPUMapAsyncStatus, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
            _ = message;
            _ = ud2;
            const ctx = @as(*MapCtx, @ptrCast(@alignCast(ud1)));
            ctx.completed.* = (status == c.WGPUMapAsyncStatus_Success);
        }
    }.cb;

    var ctx: MapCtx = .{ .completed = &map_completed };
    const map_info: c.WGPUBufferMapCallbackInfo = .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = mapCallback,
        .userdata1 = &ctx,
        .userdata2 = null,
    };
    _ = c.wgpuBufferMapAsync(g.buf_u_readback, c.WGPUMapMode_Read, 0, grid_bytes, map_info);

    for (0..POLL_MAX_ATTEMPTS) |_| {
        if (map_completed) break;
        c.wgpuInstanceProcessEvents(g.instance);
        _ = c.wgpuDevicePoll(g.device, c.WGPU_FALSE, null);
    }
    if (!map_completed) {
        return 0;
    }

    const mapped = c.wgpuBufferGetConstMappedRange(g.buf_u_readback, 0, grid_bytes);
    if (mapped == null) {
        return 0;
    }
    const src = @as([*]const u8, @ptrCast(mapped))[0..grid_bytes];
    @memcpy(buf_ptr[0..grid_bytes], src);
    c.wgpuBufferUnmap(g.buf_u_readback);

    return @intCast(grid_bytes);
}

pub export fn gs_gpu_read_result(buf_ptr: [*]u8, buf_len: usize) u32 {
    if (!g.initialized) return 0;
    const grid_bytes: u64 = @as(u64, g.width) * @as(u64, g.height) * @sizeOf(f32);
    if (buf_len < grid_bytes) return 0;

    const src_u = if (g.current_u == 0) g.buf_u0 else g.buf_u1;

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return 0;
    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, src_u, 0, g.buf_u_readback, 0, grid_bytes);
    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return 0;
    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);

    var map_completed: bool = false;
    const MapCtx = struct { completed: *bool };
    const mapCallback = struct {
        fn cb(status: c.WGPUMapAsyncStatus, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
            _ = message;
            _ = ud2;
            const ctx = @as(*MapCtx, @ptrCast(@alignCast(ud1)));
            ctx.completed.* = (status == c.WGPUMapAsyncStatus_Success);
        }
    }.cb;

    var ctx: MapCtx = .{ .completed = &map_completed };
    const map_info: c.WGPUBufferMapCallbackInfo = .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = mapCallback,
        .userdata1 = &ctx,
        .userdata2 = null,
    };
    _ = c.wgpuBufferMapAsync(g.buf_u_readback, c.WGPUMapMode_Read, 0, grid_bytes, map_info);

    // Poll until map completes
    for (0..POLL_MAX_ATTEMPTS) |_| {
        if (map_completed) break;
        c.wgpuInstanceProcessEvents(g.instance);
        _ = c.wgpuDevicePoll(g.device, c.WGPU_FALSE, null);
    }
    if (!map_completed) {
        return 0;
    }

    const mapped = c.wgpuBufferGetConstMappedRange(g.buf_u_readback, 0, grid_bytes);
    if (mapped == null) {
        return 0;
    }
    const src = @as([*]const u8, @ptrCast(mapped))[0..grid_bytes];
    @memcpy(buf_ptr[0..grid_bytes], src);
    c.wgpuBufferUnmap(g.buf_u_readback);

    return @intCast(grid_bytes);
}

pub export fn gs_gpu_free() void {
    if (!g.initialized) return;

    // Release all buffers
    for ([_]c.WGPUBuffer{
        g.buf_u_readback,
        g.buf_params,
        g.buf_kill_map,
        g.buf_feed_map,
        g.buf_u0,
        g.buf_u1,
        g.buf_v0,
        g.buf_v1,
    }) |buf| {
        if (buf != null) {
            c.wgpuBufferDestroy(buf);
            c.wgpuBufferRelease(buf);
        }
    }

    if (g.bind_group_even != null) c.wgpuBindGroupRelease(g.bind_group_even);
    if (g.bind_group_odd != null) c.wgpuBindGroupRelease(g.bind_group_odd);
    if (g.pipeline != null) c.wgpuComputePipelineRelease(g.pipeline);
    if (g.pipeline_layout != null) c.wgpuPipelineLayoutRelease(g.pipeline_layout);
    if (g.bind_group_layout != null) c.wgpuBindGroupLayoutRelease(g.bind_group_layout);
    if (g.shader_module != null) c.wgpuShaderModuleRelease(g.shader_module);
    if (g.queue != null) c.wgpuQueueRelease(g.queue);
    if (g.device != null) c.wgpuDeviceRelease(g.device);
    if (g.adapter != null) c.wgpuAdapterRelease(g.adapter);
    if (g.instance != null) c.wgpuInstanceRelease(g.instance);

    g = .{};
}

fn generateWgslInterleaved(buf: []u8, w: u32, h: u32) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\struct Params {{ da: f32, db: f32, dt: f32, feed: f32, kill: f32, }}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\const WIDTH: u32 = {d}u; const HEIGHT: u32 = {d}u;
        \\const TX: u32 = 16u; const TY: u32 = 4u; const STRIDE: u32 = 18u;
        \\var<workgroup> tile_u: array<f32, 108>; var<workgroup> tile_v: array<f32, 108>;
        \\@compute @workgroup_size(16, 4)
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>, @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x; let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_u[ti] = u_in[y * WIDTH + x]; tile_v[ti] = v_in[y * WIDTH + x];
        \\    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + x_l]; tile_v[hi] = v_in[y * WIDTH + x_l];
        \\        if (lid.y == 0u) {{ tile_u[0] = u_in[y_t * WIDTH + x_l]; tile_v[0] = v_in[y_t * WIDTH + x_l]; }}
        \\        if (lid.y == 3u) {{ let ci = 5u * STRIDE; tile_u[ci] = u_in[y_b * WIDTH + x_l]; tile_v[ci] = v_in[y_b * WIDTH + x_l]; }}
        \\    }}
        \\    if (lid.x == 15u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + 17u;
        \\        tile_u[hi] = u_in[y * WIDTH + x_r]; tile_v[hi] = v_in[y * WIDTH + x_r];
        \\        if (lid.y == 0u) {{ tile_u[17u] = u_in[y_t * WIDTH + x_r]; tile_v[17u] = v_in[y_t * WIDTH + x_r]; }}
        \\        if (lid.y == 3u) {{ let ci = 5u * STRIDE + 17u; tile_u[ci] = u_in[y_b * WIDTH + x_r]; tile_v[ci] = v_in[y_b * WIDTH + x_r]; }}
        \\    }}
        \\    if (lid.y == 0u) {{ let oh = lid.x + 1u; tile_u[oh] = u_in[y_t * WIDTH + x]; tile_v[oh] = v_in[y_t * WIDTH + x]; }}
        \\    if (lid.y == 3u) {{ let oh = 5u * STRIDE + (lid.x + 1u); tile_u[oh] = u_in[y_b * WIDTH + x]; tile_v[oh] = v_in[y_b * WIDTH + x]; }}
        \\    workgroupBarrier();
        \\    let u_c = tile_u[ti]; let v_c = tile_v[ti];
        \\    var ca: f32 = tile_u[(lid.y+1u)*STRIDE+(lid.x)]; var cb: f32 = tile_v[(lid.y+1u)*STRIDE+(lid.x)];
        \\    ca += tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)]; cb += tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)];
        \\    ca += tile_u[(lid.y)*STRIDE+(lid.x+1u)]; cb += tile_v[(lid.y)*STRIDE+(lid.x+1u)];
        \\    ca += tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)]; cb += tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)];
        \\    let card_u = ca; let card_v = cb;
        \\    var da: f32 = tile_u[(lid.y)*STRIDE+(lid.x+2u)]; var db: f32 = tile_v[(lid.y)*STRIDE+(lid.x+2u)];
        \\    da += tile_u[(lid.y)*STRIDE+(lid.x)]; db += tile_v[(lid.y)*STRIDE+(lid.x)];
        \\    da += tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]; db += tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)];
        \\    da += tile_u[(lid.y+2u)*STRIDE+(lid.x)]; db += tile_v[(lid.y+2u)*STRIDE+(lid.x)];
        \\    let diag_u = da; let diag_v = db;
        \\    let lap_u = fma(diag_u, 0.05, fma(card_u, 0.2, -u_c));
        \\    let lap_v = fma(diag_v, 0.05, fma(card_v, 0.2, -v_c));
        \\    let uvv = u_c * v_c * v_c;
        \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h });
}

fn generateWgslEarlySum(buf: []u8, w: u32, h: u32) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\struct Params {{ da: f32, db: f32, dt: f32, feed: f32, kill: f32, }}
        \\@group(0) @binding(0) var<storage, read> u_in: array<f32>;
        \\@group(0) @binding(1) var<storage, read> v_in: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
        \\@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
        \\@group(0) @binding(4) var<uniform> params: Params;
        \\const WIDTH: u32 = {d}u; const HEIGHT: u32 = {d}u;
        \\const TX: u32 = 16u; const TY: u32 = 4u; const STRIDE: u32 = 18u;
        \\var<workgroup> tile_u: array<f32, 108>; var<workgroup> tile_v: array<f32, 108>;
        \\@compute @workgroup_size(16, 4)
        \\fn main(@builtin(global_invocation_id) id: vec3<u32>, @builtin(local_invocation_id) lid: vec3<u32>) {{
        \\    let x = id.x; let y = id.y;
        \\    if (x >= WIDTH || y >= HEIGHT) {{ return; }}
        \\    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);
        \\    tile_u[ti] = u_in[y * WIDTH + x]; tile_v[ti] = v_in[y * WIDTH + x];
        \\    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
        \\    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
        \\    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
        \\    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);
        \\    if (lid.x == 0u) {{
        \\        let hi = (lid.y + 1u) * STRIDE;
        \\        tile_u[hi] = u_in[y * WIDTH + x_l]; tile_v[hi] = v_in[y * WIDTH + x_l];
        \\        if (lid.y == 0u) {{ tile_u[0] = u_in[y_t * WIDTH + x_l]; tile_v[0] = v_in[y_t * WIDTH + x_l]; }}
        \\        if (lid.y == 3u) {{ let ci = 5u * STRIDE; tile_u[ci] = u_in[y_b * WIDTH + x_l]; tile_v[ci] = v_in[y_b * WIDTH + x_l]; }}
        \\    }}
        \\    if (lid.x == 15u) {{
        \\        let hi = (lid.y + 1u) * STRIDE + 17u;
        \\        tile_u[hi] = u_in[y * WIDTH + x_r]; tile_v[hi] = v_in[y * WIDTH + x_r];
        \\        if (lid.y == 0u) {{ tile_u[17u] = u_in[y_t * WIDTH + x_r]; tile_v[17u] = v_in[y_t * WIDTH + x_r]; }}
        \\        if (lid.y == 3u) {{ let ci = 5u * STRIDE + 17u; tile_u[ci] = u_in[y_b * WIDTH + x_r]; tile_v[ci] = v_in[y_b * WIDTH + x_r]; }}
        \\    }}
        \\    if (lid.y == 0u) {{ let oh = lid.x + 1u; tile_u[oh] = u_in[y_t * WIDTH + x]; tile_v[oh] = v_in[y_t * WIDTH + x]; }}
        \\    if (lid.y == 3u) {{ let oh = 5u * STRIDE + (lid.x + 1u); tile_u[oh] = u_in[y_b * WIDTH + x]; tile_v[oh] = v_in[y_b * WIDTH + x]; }}
        \\    workgroupBarrier();
\\    let u_c = tile_u[ti]; let v_c = tile_v[ti];
    \\    let card_u = (tile_u[(lid.y+1u)*STRIDE+(lid.x)] + tile_u[(lid.y+1u)*STRIDE+(lid.x+2u)]) + (tile_u[(lid.y)*STRIDE+(lid.x+1u)] + tile_u[(lid.y+2u)*STRIDE+(lid.x+1u)]);
    \\    let card_v = (tile_v[(lid.y+1u)*STRIDE+(lid.x)] + tile_v[(lid.y+1u)*STRIDE+(lid.x+2u)]) + (tile_v[(lid.y)*STRIDE+(lid.x+1u)] + tile_v[(lid.y+2u)*STRIDE+(lid.x+1u)]);
    \\    let lap_u = fma(tile_u[(lid.y)*STRIDE+(lid.x+2u)]+tile_u[(lid.y)*STRIDE+(lid.x)]+tile_u[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_u[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_u, 0.2, -u_c));
    \\    let lap_v = fma(tile_v[(lid.y)*STRIDE+(lid.x+2u)]+tile_v[(lid.y)*STRIDE+(lid.x)]+tile_v[(lid.y+2u)*STRIDE+(lid.x+2u)]+tile_v[(lid.y+2u)*STRIDE+(lid.x)], 0.05, fma(card_v, 0.2, -v_c));
        \\    let uvv = u_c * v_c * v_c;
        \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h });
}

pub export fn gs_gpu_init_f16(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;

    g.width = width; g.height = height; g.wg_x = 16; g.wg_y = 4;

    g.instance = c.wgpuCreateInstance(null);
    if (g.instance == null) return false;

    g_cb_adapter = null;
    const adapter_cb_info: c.WGPURequestAdapterCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = adapterCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const adapter_fut = c.wgpuInstanceRequestAdapter(g.instance, null, adapter_cb_info);
    if (!waitFuture(g.instance, adapter_fut)) return false;
    g.adapter = g_cb_adapter;
    if (g.adapter == null) return false;

    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;
    if (!g.has_f16) { std.debug.print("f16 not supported on this adapter\n", .{}); return false; }

    g_cb_device = null;
    var f16_features: [1]c.WGPUFeatureName = undefined;
    f16_features[0] = c.WGPUFeatureName_ShaderF16;
    const dev_desc: c.WGPUDeviceDescriptor = .{
        .nextInChain = null,
        .label = strv("f16"),
        .requiredFeatureCount = 1,
        .requiredFeatures = &f16_features,
        .requiredLimits = null,
        .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor),
        .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo),
        .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo),
    };
    const device_cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = deviceCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const device_fut = c.wgpuAdapterRequestDevice(g.adapter, &dev_desc, device_cb_info);
    if (!waitFuture(g.instance, device_fut)) return false;
    g.device = g_cb_device;
    if (g.device == null) return false;

    g.queue = c.wgpuDeviceGetQueue(g.device);
    if (g.queue == null) return false;

    var wgsl_buf: [WGSL_BUF_SIZE]u8 = undefined;
    const wgsl_src = generateWgslF16(&wgsl_buf, width, height, g.wg_x, g.wg_y) catch return false;

    var shader_source: c.WGPUShaderSourceWGSL = undefined;
    shader_source.chain.next = null;
    shader_source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    shader_source.code = strv(wgsl_src);

    const sm_desc: c.WGPUShaderModuleDescriptor = .{
        .nextInChain = &shader_source.chain,
        .label = cstrv("f16"),
    };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm_desc);
    if (g.shader_module == null) return false;

    const grid_bytes: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f16);
    const storage_usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, storage_usage, grid_bytes, "u0");
    g.buf_u1 = makeBuffer(g.device, storage_usage, grid_bytes, "u1");
    g.buf_v0 = makeBuffer(g.device, storage_usage, grid_bytes, "v0");
    g.buf_v1 = makeBuffer(g.device, storage_usage, grid_bytes, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpu), "params");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, grid_bytes, "u_readback");

    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or
        g.buf_params == null or g.buf_u_readback == null) return false;

    var init_u = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_u);
    var init_v = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(init_v);

    @memset(init_u, 1.0);
    @memset(init_v, 0.0);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const num_seeds: usize = if (width * height > 10000) 20 else 5;
    var s: usize = 0;
    while (s < num_seeds) : (s += 1) {
        const cx = rand.intRangeLessThan(usize, 5, width - 5);
        const cy = rand.intRangeLessThan(usize, 5, height - 5);
        const sz = rand.intRangeAtMost(usize, 2, 5);
        const half = sz / 2;
        const x0 = if (cx > half) cx - half else 0;
        const x1 = @min(cx + half, width);
        const y0 = if (cy > half) cy - half else 0;
        const y1 = @min(cy + half, height);
        var yy = y0;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) {
                init_u[yy * width + xx] = 0.5;
                init_v[yy * width + xx] = 1.0;
            }
        }
    }

    var packed_u = std.heap.page_allocator.alloc(u16, width * height) catch return false;
    defer std.heap.page_allocator.free(packed_u);
    var packed_v = std.heap.page_allocator.alloc(u16, width * height) catch return false;
    defer std.heap.page_allocator.free(packed_v);

    for (init_u, 0..) |val, i| {
        packed_u[i] = @bitCast(@as(f16, @floatCast(val)));
    }
    for (init_v, 0..) |val, i| {
        packed_v[i] = @bitCast(@as(f16, @floatCast(val)));
    }

    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, @ptrCast(packed_u.ptr), grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, @ptrCast(packed_u.ptr), grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, @ptrCast(packed_v.ptr), grid_bytes);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, @ptrCast(packed_v.ptr), grid_bytes);

    const entries = [_]c.WGPUBindGroupLayoutEntry{
        makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage),
        makeBglEntry(2, c.WGPUBufferBindingType_Storage),
        makeBglEntry(3, c.WGPUBufferBindingType_Storage),
        makeBglEntry(4, c.WGPUBufferBindingType_Uniform),
    };
    const bgl_desc: c.WGPUBindGroupLayoutDescriptor = .{
        .nextInChain = null, .label = cstrv("f16bgl"), .entryCount = entries.len, .entries = &entries,
    };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bgl_desc);
    if (g.bind_group_layout == null) return false;

    const pll_desc: c.WGPUPipelineLayoutDescriptor = .{
        .nextInChain = null, .label = cstrv("f16pll"), .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &g.bind_group_layout, .immediateSize = 0,
    };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pll_desc);
    if (g.pipeline_layout == null) return false;

    const cs: c.WGPUComputeState = .{
        .nextInChain = null, .module = g.shader_module, .entryPoint = cstrv("main"),
        .constantCount = 0, .constants = null,
    };
    const cp_desc: c.WGPUComputePipelineDescriptor = .{
        .nextInChain = null, .label = cstrv("f16pipe"), .layout = g.pipeline_layout, .compute = cs,
    };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp_desc);
    if (g.pipeline == null) return false;

    const wsz = c.WGPU_WHOLE_SIZE;
    const bg_even_entries = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u0, 0, wsz),
        makeBindGroupEntry(1, g.buf_v0, 0, wsz),
        makeBindGroupEntry(2, g.buf_u1, 0, wsz),
        makeBindGroupEntry(3, g.buf_v1, 0, wsz),
        makeBindGroupEntry(4, g.buf_params, 0, wsz),
    };
    const bg_desc_even: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null, .label = cstrv("f16bg0"), .layout = g.bind_group_layout,
        .entryCount = bg_even_entries.len, .entries = &bg_even_entries,
    };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_even);

    const bg_odd_entries = [_]c.WGPUBindGroupEntry{
        makeBindGroupEntry(0, g.buf_u1, 0, wsz),
        makeBindGroupEntry(1, g.buf_v1, 0, wsz),
        makeBindGroupEntry(2, g.buf_u0, 0, wsz),
        makeBindGroupEntry(3, g.buf_v0, 0, wsz),
        makeBindGroupEntry(4, g.buf_params, 0, wsz),
    };
    const bg_desc_odd: c.WGPUBindGroupDescriptor = .{
        .nextInChain = null, .label = cstrv("f16bg1"), .layout = g.bind_group_layout,
        .entryCount = bg_odd_entries.len, .entries = &bg_odd_entries,
    };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bg_desc_odd);

    if (g.bind_group_even == null or g.bind_group_odd == null) return false;

    g.current_u = 0; g.step_count = 0; g.pearson_mode = false;
    g.shader_flags |= SHADER_F16;
    g.initialized = true;
    return true;
}

pub fn gs_gpu_read_result_f16(buf_ptr: [*]u8, buf_len: usize) u32 {
    if (!g.initialized or (g.shader_flags & SHADER_F16) == 0) return 0;
    const grid_bytes: u64 = @as(u64, g.width) * @as(u64, g.height) * @sizeOf(f16);
    const out_bytes: u64 = @as(u64, g.width) * @as(u64, g.height) * @sizeOf(f32);
    if (buf_len < out_bytes) return 0;

    const src_u = if (g.current_u == 0) g.buf_u0 else g.buf_u1;

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return 0;
    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, src_u, 0, g.buf_u_readback, 0, grid_bytes);
    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return 0;
    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);

    var map_completed: bool = false;
    const MapCtx = struct { completed: *bool };
    const mapCallback = struct {
        fn cb(status: c.WGPUMapAsyncStatus, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
            _ = message; _ = ud2;
            const ctx = @as(*MapCtx, @ptrCast(@alignCast(ud1)));
            ctx.completed.* = (status == c.WGPUMapAsyncStatus_Success);
        }
    }.cb;

    var ctx: MapCtx = .{ .completed = &map_completed };
    const map_info: c.WGPUBufferMapCallbackInfo = .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = mapCallback, .userdata1 = &ctx, .userdata2 = null,
    };
    _ = c.wgpuBufferMapAsync(g.buf_u_readback, c.WGPUMapMode_Read, 0, grid_bytes, map_info);

    for (0..POLL_MAX_ATTEMPTS) |_| {
        if (map_completed) break;
        c.wgpuInstanceProcessEvents(g.instance);
        _ = c.wgpuDevicePoll(g.device, c.WGPU_FALSE, null);
    }
    if (!map_completed) return 0;

    const mapped = c.wgpuBufferGetConstMappedRange(g.buf_u_readback, 0, grid_bytes);
    if (mapped == null) return 0;
    const src = @as([*]const u16, @ptrCast(@alignCast(mapped)))[0 .. g.width * g.height];
    const dst = @as([*]f32, @ptrCast(@alignCast(buf_ptr)));
    for (src, 0..) |val, i| {
        const v: f16 = @bitCast(val);
        dst[i] = @floatCast(v);
    }
    c.wgpuBufferUnmap(g.buf_u_readback);

    return @intCast(out_bytes);
}

pub export fn gs_gpu_init_interleaved(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;
    g.wg_x = 16; g.wg_y = 4; g.width = width; g.height = height;
    g.instance = c.wgpuCreateInstance(null); if (g.instance == null) return false;
    g_cb_adapter = null;
    const ai: c.WGPURequestAdapterCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = adapterCallback, .userdata1 = null, .userdata2 = null };
    const af = c.wgpuInstanceRequestAdapter(g.instance, null, ai);
    if (!waitFuture(g.instance, af)) return false;
    g.adapter = g_cb_adapter; if (g.adapter == null) return false;
    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;
    g_cb_device = null;
    var dp: ?*const c.WGPUDeviceDescriptor = null;
    var fa: [1]c.WGPUFeatureName = undefined;
    var dd: c.WGPUDeviceDescriptor = undefined;
    if (g.has_f16) { fa[0] = c.WGPUFeatureName_ShaderF16; dd = .{ .nextInChain = null, .label = strv("il"), .requiredFeatureCount = 1, .requiredFeatures = &fa, .requiredLimits = null, .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor), .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo), .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo) }; dp = &dd; }
    const di: c.WGPURequestDeviceCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = deviceCallback, .userdata1 = null, .userdata2 = null };
    const df = c.wgpuAdapterRequestDevice(g.adapter, dp, di);
    if (!waitFuture(g.instance, df)) return false;
    g.device = g_cb_device; if (g.device == null) return false;
    g.queue = c.wgpuDeviceGetQueue(g.device); if (g.queue == null) return false;
    var wb: [8192]u8 = undefined;
    const ws = generateWgslInterleaved(&wb, width, height) catch return false;
    var ss: c.WGPUShaderSourceWGSL = undefined; ss.chain.next = null; ss.chain.sType = c.WGPUSType_ShaderSourceWGSL; ss.code = strv(ws);
    const sm: c.WGPUShaderModuleDescriptor = .{ .nextInChain = &ss.chain, .label = cstrv("il") };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm); if (g.shader_module == null) return false;
    const gb: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f32);
    const su = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, su, gb, "u0"); g.buf_u1 = makeBuffer(g.device, su, gb, "u1");
    g.buf_v0 = makeBuffer(g.device, su, gb, "v0"); g.buf_v1 = makeBuffer(g.device, su, gb, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpu), "p");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, gb, "rb");
    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or g.buf_params == null or g.buf_u_readback == null) return false;
    var iu = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iu);
    var iv = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iv);
    @memset(iu, 1.0); @memset(iv, 0.0);
    var rng = std.Random.DefaultPrng.init(42); const rd = rng.random();
    const ns: usize = if (width * height > 10000) 20 else 5; var k: usize = 0;
    while (k < ns) : (k += 1) {
        const cx = rd.intRangeLessThan(usize, 5, width-5); const cy = rd.intRangeLessThan(usize, 5, height-5);
        const sz = rd.intRangeAtMost(usize, 2, 5); const hf = sz / 2;
        for (if(cy>hf) cy-hf else 0..@min(cy+hf+1,height))|yy|{ for (if(cx>hf) cx-hf else 0..@min(cx+hf+1,width))|xx|{ iu[yy*width+xx]=0.5; iv[yy*width+xx]=1.0; }}
    }
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, iu.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, iu.ptr, gb);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, iv.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, iv.ptr, gb);
    const ents = [_]c.WGPUBindGroupLayoutEntry{ makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(2, c.WGPUBufferBindingType_Storage), makeBglEntry(3, c.WGPUBufferBindingType_Storage), makeBglEntry(4, c.WGPUBufferBindingType_Uniform) };
    const bl: c.WGPUBindGroupLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("il"), .entryCount = ents.len, .entries = &ents };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bl); if (g.bind_group_layout == null) return false;
    const pl: c.WGPUPipelineLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("il"), .bindGroupLayoutCount = 1, .bindGroupLayouts = &g.bind_group_layout, .immediateSize = 0 };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pl); if (g.pipeline_layout == null) return false;
    const co: c.WGPUComputeState = .{ .nextInChain = null, .module = g.shader_module, .entryPoint = cstrv("main"), .constantCount = 0, .constants = null };
    const cp: c.WGPUComputePipelineDescriptor = .{ .nextInChain = null, .label = cstrv("il"), .layout = g.pipeline_layout, .compute = co };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp); if (g.pipeline == null) return false;
    const wsz = c.WGPU_WHOLE_SIZE;
    const be = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u0,0,wsz), makeBindGroupEntry(1,g.buf_v0,0,wsz), makeBindGroupEntry(2,g.buf_u1,0,wsz), makeBindGroupEntry(3,g.buf_v1,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bde: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("il"),.layout=g.bind_group_layout,.entryCount=be.len,.entries=&be };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bde);
    const bo = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u1,0,wsz), makeBindGroupEntry(1,g.buf_v1,0,wsz), makeBindGroupEntry(2,g.buf_u0,0,wsz), makeBindGroupEntry(3,g.buf_v0,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bdo: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("il"),.layout=g.bind_group_layout,.entryCount=bo.len,.entries=&bo };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bdo);
    if (g.bind_group_even==null or g.bind_group_odd==null) return false;
    g.current_u=0; g.step_count=0; g.initialized=true; return true;
}

pub export fn gs_gpu_init_earlysum(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;
    g.wg_x = 16; g.wg_y = 4; g.width = width; g.height = height;
    g.instance = c.wgpuCreateInstance(null); if (g.instance == null) return false;
    g_cb_adapter = null;
    const ai: c.WGPURequestAdapterCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = adapterCallback, .userdata1 = null, .userdata2 = null };
    const af = c.wgpuInstanceRequestAdapter(g.instance, null, ai);
    if (!waitFuture(g.instance, af)) return false;
    g.adapter = g_cb_adapter; if (g.adapter == null) return false;
    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;
    g_cb_device = null;
    var dp: ?*const c.WGPUDeviceDescriptor = null;
    var fa: [1]c.WGPUFeatureName = undefined;
    var dd: c.WGPUDeviceDescriptor = undefined;
    if (g.has_f16) { fa[0] = c.WGPUFeatureName_ShaderF16; dd = .{ .nextInChain = null, .label = strv("es"), .requiredFeatureCount = 1, .requiredFeatures = &fa, .requiredLimits = null, .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor), .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo), .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo) }; dp = &dd; }
    const di: c.WGPURequestDeviceCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = deviceCallback, .userdata1 = null, .userdata2 = null };
    const df = c.wgpuAdapterRequestDevice(g.adapter, dp, di);
    if (!waitFuture(g.instance, df)) return false;
    g.device = g_cb_device; if (g.device == null) return false;
    g.queue = c.wgpuDeviceGetQueue(g.device); if (g.queue == null) return false;
    var wb: [8192]u8 = undefined;
    const ws = generateWgslEarlySum(&wb, width, height) catch return false;
    var ss: c.WGPUShaderSourceWGSL = undefined; ss.chain.next = null; ss.chain.sType = c.WGPUSType_ShaderSourceWGSL; ss.code = strv(ws);
    const sm: c.WGPUShaderModuleDescriptor = .{ .nextInChain = &ss.chain, .label = cstrv("es") };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm); if (g.shader_module == null) return false;
    const gb: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f32);
    const su = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, su, gb, "u0"); g.buf_u1 = makeBuffer(g.device, su, gb, "u1");
    g.buf_v0 = makeBuffer(g.device, su, gb, "v0"); g.buf_v1 = makeBuffer(g.device, su, gb, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpu), "p");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, gb, "rb");
    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or g.buf_params == null or g.buf_u_readback == null) return false;
    var iu = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iu);
    var iv = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iv);
    @memset(iu, 1.0); @memset(iv, 0.0);
    var rng = std.Random.DefaultPrng.init(42); const rd = rng.random();
    const ns: usize = if (width * height > 10000) 20 else 5; var k: usize = 0;
    while (k < ns) : (k += 1) {
        const cx = rd.intRangeLessThan(usize, 5, width-5); const cy = rd.intRangeLessThan(usize, 5, height-5);
        const sz = rd.intRangeAtMost(usize, 2, 5); const hf = sz / 2;
        for (if(cy>hf) cy-hf else 0..@min(cy+hf+1,height))|yy|{ for (if(cx>hf) cx-hf else 0..@min(cx+hf+1,width))|xx|{ iu[yy*width+xx]=0.5; iv[yy*width+xx]=1.0; }}
    }
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, iu.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, iu.ptr, gb);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, iv.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, iv.ptr, gb);
    const ents = [_]c.WGPUBindGroupLayoutEntry{ makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(2, c.WGPUBufferBindingType_Storage), makeBglEntry(3, c.WGPUBufferBindingType_Storage), makeBglEntry(4, c.WGPUBufferBindingType_Uniform) };
    const bl: c.WGPUBindGroupLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("es"), .entryCount = ents.len, .entries = &ents };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bl); if (g.bind_group_layout == null) return false;
    const pl: c.WGPUPipelineLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("es"), .bindGroupLayoutCount = 1, .bindGroupLayouts = &g.bind_group_layout, .immediateSize = 0 };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pl); if (g.pipeline_layout == null) return false;
    const co: c.WGPUComputeState = .{ .nextInChain = null, .module = g.shader_module, .entryPoint = cstrv("main"), .constantCount = 0, .constants = null };
    const cp: c.WGPUComputePipelineDescriptor = .{ .nextInChain = null, .label = cstrv("es"), .layout = g.pipeline_layout, .compute = co };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp); if (g.pipeline == null) return false;
    const wsz = c.WGPU_WHOLE_SIZE;
    const be = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u0,0,wsz), makeBindGroupEntry(1,g.buf_v0,0,wsz), makeBindGroupEntry(2,g.buf_u1,0,wsz), makeBindGroupEntry(3,g.buf_v1,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bde: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("es"),.layout=g.bind_group_layout,.entryCount=be.len,.entries=&be };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bde);
    const bo = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u1,0,wsz), makeBindGroupEntry(1,g.buf_v1,0,wsz), makeBindGroupEntry(2,g.buf_u0,0,wsz), makeBindGroupEntry(3,g.buf_v0,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bdo: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("es"),.layout=g.bind_group_layout,.entryCount=bo.len,.entries=&bo };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bdo);
    if (g.bind_group_even==null or g.bind_group_odd==null) return false;
    g.current_u=0; g.step_count=0; g.initialized=true; return true;
}
pub export fn gs_gpu_init_coarse(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    g.width = width; g.height = height; g.wg_x = 16; g.wg_y = 4; g.coarse_factor = 2;
    g.instance = c.wgpuCreateInstance(null); if (g.instance == null) return false;
    g_cb_adapter = null;
    const ai: c.WGPURequestAdapterCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = adapterCallback, .userdata1 = null, .userdata2 = null };
    const af = c.wgpuInstanceRequestAdapter(g.instance, null, ai);
    if (!waitFuture(g.instance, af)) return false;
    g.adapter = g_cb_adapter; if (g.adapter == null) return false;
    g.has_f16 = c.wgpuAdapterHasFeature(g.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE;
    g_cb_device = null;
    var dp: ?*const c.WGPUDeviceDescriptor = null;
    var fa: [1]c.WGPUFeatureName = undefined;
    var dd: c.WGPUDeviceDescriptor = undefined;
    if (g.has_f16) { fa[0] = c.WGPUFeatureName_ShaderF16; dd = .{ .nextInChain = null, .label = strv("co"), .requiredFeatureCount = 1, .requiredFeatures = &fa, .requiredLimits = null, .defaultQueue = std.mem.zeroes(c.WGPUQueueDescriptor), .deviceLostCallbackInfo = std.mem.zeroes(c.WGPUDeviceLostCallbackInfo), .uncapturedErrorCallbackInfo = std.mem.zeroes(c.WGPUUncapturedErrorCallbackInfo) }; dp = &dd; }
    const di: c.WGPURequestDeviceCallbackInfo = .{ .mode = c.WGPUCallbackMode_WaitAnyOnly, .callback = deviceCallback, .userdata1 = null, .userdata2 = null };
    const df = c.wgpuAdapterRequestDevice(g.adapter, dp, di);
    if (!waitFuture(g.instance, df)) return false;
    g.device = g_cb_device; if (g.device == null) return false;
    g.queue = c.wgpuDeviceGetQueue(g.device); if (g.queue == null) return false;
    var wb: [WGSL_BUF_SIZE]u8 = undefined;
    const ws = generateWgslCoarseSMEM(&wb, width, height) catch return false;
    var ss: c.WGPUShaderSourceWGSL = undefined; ss.chain.next = null; ss.chain.sType = c.WGPUSType_ShaderSourceWGSL; ss.code = strv(ws);
    const sm: c.WGPUShaderModuleDescriptor = .{ .nextInChain = &ss.chain, .label = cstrv("co") };
    g.shader_module = c.wgpuDeviceCreateShaderModule(g.device, &sm); if (g.shader_module == null) return false;
    const gb: u64 = @as(u64, width) * @as(u64, height) * @sizeOf(f32);
    const su = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_CopySrc;
    g.buf_u0 = makeBuffer(g.device, su, gb, "u0"); g.buf_u1 = makeBuffer(g.device, su, gb, "u1");
    g.buf_v0 = makeBuffer(g.device, su, gb, "v0"); g.buf_v1 = makeBuffer(g.device, su, gb, "v1");
    g.buf_params = makeBuffer(g.device, c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(ParamsGpu), "p");
    g.buf_u_readback = makeBuffer(g.device, c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, gb, "rb");
    if (g.buf_u0 == null or g.buf_u1 == null or g.buf_v0 == null or g.buf_v1 == null or g.buf_params == null or g.buf_u_readback == null) return false;
    var iu = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iu);
    var iv = std.heap.page_allocator.alloc(f32, width * height) catch return false;
    defer std.heap.page_allocator.free(iv);
    @memset(iu, 1.0); @memset(iv, 0.0);
    var rng = std.Random.DefaultPrng.init(42); const rd = rng.random();
    const ns: usize = if (width * height > 10000) 20 else 5; var k: usize = 0;
    while (k < ns) : (k += 1) {
        const cx = rd.intRangeLessThan(usize, 5, width-5); const cy = rd.intRangeLessThan(usize, 5, height-5);
        const sz = rd.intRangeAtMost(usize, 2, 5); const hf = sz / 2;
        for (if(cy>hf) cy-hf else 0..@min(cy+hf+1,height))|yy|{ for (if(cx>hf) cx-hf else 0..@min(cx+hf+1,width))|xx|{ iu[yy*width+xx]=0.5; iv[yy*width+xx]=1.0; }}
    }
    c.wgpuQueueWriteBuffer(g.queue, g.buf_u0, 0, iu.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_u1, 0, iu.ptr, gb);
    c.wgpuQueueWriteBuffer(g.queue, g.buf_v0, 0, iv.ptr, gb); c.wgpuQueueWriteBuffer(g.queue, g.buf_v1, 0, iv.ptr, gb);
    const ents = [_]c.WGPUBindGroupLayoutEntry{ makeBglEntry(0, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(1, c.WGPUBufferBindingType_ReadOnlyStorage), makeBglEntry(2, c.WGPUBufferBindingType_Storage), makeBglEntry(3, c.WGPUBufferBindingType_Storage), makeBglEntry(4, c.WGPUBufferBindingType_Uniform) };
    const bl: c.WGPUBindGroupLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("co"), .entryCount = ents.len, .entries = &ents };
    g.bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(g.device, &bl); if (g.bind_group_layout == null) return false;
    const pl: c.WGPUPipelineLayoutDescriptor = .{ .nextInChain = null, .label = cstrv("co"), .bindGroupLayoutCount = 1, .bindGroupLayouts = &g.bind_group_layout, .immediateSize = 0 };
    g.pipeline_layout = c.wgpuDeviceCreatePipelineLayout(g.device, &pl); if (g.pipeline_layout == null) return false;
    const co: c.WGPUComputeState = .{ .nextInChain = null, .module = g.shader_module, .entryPoint = cstrv("main"), .constantCount = 0, .constants = null };
    const cp: c.WGPUComputePipelineDescriptor = .{ .nextInChain = null, .label = cstrv("co"), .layout = g.pipeline_layout, .compute = co };
    g.pipeline = c.wgpuDeviceCreateComputePipeline(g.device, &cp); if (g.pipeline == null) return false;
    const wsz = c.WGPU_WHOLE_SIZE;
    const be = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u0,0,wsz), makeBindGroupEntry(1,g.buf_v0,0,wsz), makeBindGroupEntry(2,g.buf_u1,0,wsz), makeBindGroupEntry(3,g.buf_v1,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bde: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("co"),.layout=g.bind_group_layout,.entryCount=be.len,.entries=&be };
    g.bind_group_even = c.wgpuDeviceCreateBindGroup(g.device, &bde);
    const bo = [_]c.WGPUBindGroupEntry{ makeBindGroupEntry(0,g.buf_u1,0,wsz), makeBindGroupEntry(1,g.buf_v1,0,wsz), makeBindGroupEntry(2,g.buf_u0,0,wsz), makeBindGroupEntry(3,g.buf_v0,0,wsz), makeBindGroupEntry(4,g.buf_params,0,wsz) };
    const bdo: c.WGPUBindGroupDescriptor = .{ .nextInChain=null,.label=cstrv("co"),.layout=g.bind_group_layout,.entryCount=bo.len,.entries=&bo };
    g.bind_group_odd = c.wgpuDeviceCreateBindGroup(g.device, &bdo);
    if (g.bind_group_even==null or g.bind_group_odd==null) return false;
    g.current_u=0; g.step_count=0; g.pearson_mode=false; g.initialized=true; return true;
}
