const std = @import("std");
const c = @import("webgpu.zig").c;

// =============================================================================
// Global GPU state
// =============================================================================

const GpuState = struct {
    width: u32 = 0,
    height: u32 = 0,
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
    current_u: u32 = 0, // 0 = u0 has latest, 1 = u1 has latest
    step_count: u32 = 0,
    initialized: bool = false,
};

var g: GpuState = .{};

// =============================================================================
// Async callback state (global because callbacks are C functions)
// =============================================================================

var g_cb_adapter: c.WGPUAdapter = null;
var g_cb_device: c.WGPUDevice = null;

fn adapterCallback(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = message; _ = ud1; _ = ud2;
    if (status == c.WGPURequestAdapterStatus_Success) {
        g_cb_adapter = adapter;
    }
}

fn deviceCallback(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.WGPUStringView, ud1: ?*anyopaque, ud2: ?*anyopaque) callconv(.c) void {
    _ = message; _ = ud1; _ = ud2;
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
    var attempts: u32 = 0;
    while (attempts < 100000) : (attempts += 1) {
        c.wgpuInstanceProcessEvents(inst);
        if (g_cb_adapter != null or g_cb_device != null) return true;
        // busy spin — events should fire inside ProcessEvents
    }
    return false;
}

fn makeBuffer(device: c.WGPUDevice, usage: u64, size: u64, label: []const u8) c.WGPUBuffer {
    const desc: c.WGPUBufferDescriptor = .{
        .nextInChain = null,
        .label = strv(label),
        .usage = usage,
        .size = size,
        .mappedAtCreation = c.WGPU_FALSE,
    };
    return c.wgpuDeviceCreateBuffer(device, &desc);
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

// =============================================================================
// WGSL shader generation (runtime width/height substitution)
// =============================================================================

fn generateWgsl(buf: []u8, w: u32, h: u32) ![]const u8 {
    return std.fmt.bufPrint(buf,
        "struct Params {{\n" ++
        "    da: f32,\n" ++
        "    db: f32,\n" ++
        "    dt: f32,\n" ++
        "    feed: f32,\n" ++
        "    kill: f32,\n" ++
        "}}\n" ++
        "@group(0) @binding(0) var<storage, read> u_in: array<f32>;\n" ++
        "@group(0) @binding(1) var<storage, read> v_in: array<f32>;\n" ++
        "@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;\n" ++
        "@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;\n" ++
        "@group(0) @binding(4) var<uniform> params: Params;\n" ++
        "const WIDTH: u32 = {d}u;\n" ++
        "const HEIGHT: u32 = {d}u;\n" ++
        "const TILE: u32 = 16u;\n" ++
        "const STRIDE: u32 = 18u;\n" ++
        "var<workgroup> tile_u: array<f32, 324>;\n" ++
        "var<workgroup> tile_v: array<f32, 324>;\n" ++
        "@compute @workgroup_size(16, 16)\n" ++
        "fn main(@builtin(global_invocation_id) id: vec3<u32>,\n" ++
        "        @builtin(local_invocation_id) lid: vec3<u32>) {{\n" ++
        "    let x = id.x;\n" ++
        "    let y = id.y;\n" ++
        "    if (x >= WIDTH || y >= HEIGHT) {{ return; }}\n" ++
        "    let ti = (lid.y + 1u) * STRIDE + (lid.x + 1u);\n" ++
        "    tile_u[ti] = u_in[y * WIDTH + x];\n" ++
        "    tile_v[ti] = v_in[y * WIDTH + x];\n" ++
        "    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);\n" ++
        "    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);\n" ++
        "    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);\n" ++
        "    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);\n" ++
        "    if (lid.x == 0u) {{\n" ++
        "        let hi = (lid.y + 1u) * STRIDE;\n" ++
        "        tile_u[hi] = u_in[y * WIDTH + x_l];\n" ++
        "        tile_v[hi] = v_in[y * WIDTH + x_l];\n" ++
        "    }}\n" ++
        "    if (lid.x == TILE - 1u) {{\n" ++
        "        let hi = (lid.y + 1u) * STRIDE + (TILE + 1u);\n" ++
        "        tile_u[hi] = u_in[y * WIDTH + x_r];\n" ++
        "        tile_v[hi] = v_in[y * WIDTH + x_r];\n" ++
        "    }}\n" ++
        "    if (lid.y == 0u) {{\n" ++
        "        let hi = lid.x + 1u;\n" ++
        "        tile_u[hi] = u_in[y_t * WIDTH + x];\n" ++
        "        tile_v[hi] = v_in[y_t * WIDTH + x];\n" ++
        "    }}\n" ++
        "    if (lid.y == TILE - 1u) {{\n" ++
        "        let hi = (TILE + 1u) * STRIDE + (lid.x + 1u);\n" ++
        "        tile_u[hi] = u_in[y_b * WIDTH + x];\n" ++
        "        tile_v[hi] = v_in[y_b * WIDTH + x];\n" ++
        "    }}\n" ++
        "    if (lid.x == 0u && lid.y == 0u) {{\n" ++
        "        tile_u[0] = u_in[y_t * WIDTH + x_l];\n" ++
        "        tile_v[0] = v_in[y_t * WIDTH + x_l];\n" ++
        "    }}\n" ++
        "    if (lid.x == TILE - 1u && lid.y == 0u) {{\n" ++
        "        let ci = TILE + 1u;\n" ++
        "        tile_u[ci] = u_in[y_t * WIDTH + x_r];\n" ++
        "        tile_v[ci] = v_in[y_t * WIDTH + x_r];\n" ++
        "    }}\n" ++
        "    if (lid.x == 0u && lid.y == TILE - 1u) {{\n" ++
        "        let ci = (TILE + 1u) * STRIDE;\n" ++
        "        tile_u[ci] = u_in[y_b * WIDTH + x_l];\n" ++
        "        tile_v[ci] = v_in[y_b * WIDTH + x_l];\n" ++
        "    }}\n" ++
        "    if (lid.x == TILE - 1u && lid.y == TILE - 1u) {{\n" ++
        "        let ci = (TILE + 1u) * STRIDE + (TILE + 1u);\n" ++
        "        tile_u[ci] = u_in[y_b * WIDTH + x_r];\n" ++
        "        tile_v[ci] = v_in[y_b * WIDTH + x_r];\n" ++
        "    }}\n" ++
        "    workgroupBarrier();\n" ++
        "    let u_c = tile_u[ti];\n" ++
        "    let v_c = tile_v[ti];\n" ++
        "    let u_center = u_c;\n" ++
        "    let u_left   = tile_u[(lid.y + 1u) * STRIDE + (lid.x    )];\n" ++
        "    let u_right  = tile_u[(lid.y + 1u) * STRIDE + (lid.x + 2u)];\n" ++
        "    let u_up     = tile_u[(lid.y    ) * STRIDE + (lid.x + 1u)];\n" ++
        "    let u_down   = tile_u[(lid.y + 2u) * STRIDE + (lid.x + 1u)];\n" ++
        "    let u_ne     = tile_u[(lid.y    ) * STRIDE + (lid.x + 2u)];\n" ++
        "    let u_nw     = tile_u[(lid.y    ) * STRIDE + (lid.x    )];\n" ++
        "    let u_se     = tile_u[(lid.y + 2u) * STRIDE + (lid.x + 2u)];\n" ++
        "    let u_sw     = tile_u[(lid.y + 2u) * STRIDE + (lid.x    )];\n" ++
        "    let lap_u = 0.2 * (u_left + u_right + u_up + u_down)\n" ++
        "            + 0.05 * (u_ne + u_nw + u_se + u_sw)\n" ++
        "            - 1.0 * u_center;\n" ++
        "    let v_center = v_c;\n" ++
        "    let v_left   = tile_v[(lid.y + 1u) * STRIDE + (lid.x    )];\n" ++
        "    let v_right  = tile_v[(lid.y + 1u) * STRIDE + (lid.x + 2u)];\n" ++
        "    let v_up     = tile_v[(lid.y    ) * STRIDE + (lid.x + 1u)];\n" ++
        "    let v_down   = tile_v[(lid.y + 2u) * STRIDE + (lid.x + 1u)];\n" ++
        "    let v_ne     = tile_v[(lid.y    ) * STRIDE + (lid.x + 2u)];\n" ++
        "    let v_nw     = tile_v[(lid.y    ) * STRIDE + (lid.x    )];\n" ++
        "    let v_se     = tile_v[(lid.y + 2u) * STRIDE + (lid.x + 2u)];\n" ++
        "    let v_sw     = tile_v[(lid.y + 2u) * STRIDE + (lid.x    )];\n" ++
        "    let lap_v = 0.2 * (v_left + v_right + v_up + v_down)\n" ++
        "            + 0.05 * (v_ne + v_nw + v_se + v_sw)\n" ++
        "            - 1.0 * v_center;\n" ++
        "    let uvv = u_c * v_c * v_c;\n" ++
        "    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));\n" ++
        "    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);\n" ++
        "    let out_idx = y * WIDTH + x;\n" ++
        "    u_out[out_idx] = clamp(u_next, 0.0, 1.0);\n" ++
        "    v_out[out_idx] = clamp(v_next, 0.0, 1.0);\n" ++
        "}}\n",
        .{ w, h }
    );
}

// =============================================================================
// Exported API
// =============================================================================

pub export fn gs_gpu_init(width: u32, height: u32) bool {
    if (g.initialized) gs_gpu_free();
    if (width == 0 or height == 0) return false;

    g.width = width;
    g.height = height;

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

    // ---- Device (async + wait) ----
    g_cb_device = null;
    const device_cb_info: c.WGPURequestDeviceCallbackInfo = .{
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .callback = deviceCallback,
        .userdata1 = null,
        .userdata2 = null,
    };
    const device_fut = c.wgpuAdapterRequestDevice(g.adapter, null, device_cb_info);
    if (!waitFuture(g.instance, device_fut)) return false;
    g.device = g_cb_device;
    if (g.device == null) return false;

    g.queue = c.wgpuDeviceGetQueue(g.device);
    if (g.queue == null) return false;

    // ---- Shader ----
    var wgsl_buf: [8192]u8 = undefined;
    const wgsl_src = generateWgsl(&wgsl_buf, width, height) catch return false;

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
        .{
            .nextInChain = null,
            .binding = 0,
            .visibility = c.WGPUShaderStage_Compute,
            .bindingArraySize = 0,
            .buffer = .{ .nextInChain = null, .type = c.WGPUBufferBindingType_ReadOnlyStorage, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = c.WGPUSamplerBindingType_BindingNotUsed },
            .texture = .{ .nextInChain = null, .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
            .storageTexture = .{ .nextInChain = null, .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 1,
            .visibility = c.WGPUShaderStage_Compute,
            .bindingArraySize = 0,
            .buffer = .{ .nextInChain = null, .type = c.WGPUBufferBindingType_ReadOnlyStorage, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = c.WGPUSamplerBindingType_BindingNotUsed },
            .texture = .{ .nextInChain = null, .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
            .storageTexture = .{ .nextInChain = null, .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 2,
            .visibility = c.WGPUShaderStage_Compute,
            .bindingArraySize = 0,
            .buffer = .{ .nextInChain = null, .type = c.WGPUBufferBindingType_Storage, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = c.WGPUSamplerBindingType_BindingNotUsed },
            .texture = .{ .nextInChain = null, .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
            .storageTexture = .{ .nextInChain = null, .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 3,
            .visibility = c.WGPUShaderStage_Compute,
            .bindingArraySize = 0,
            .buffer = .{ .nextInChain = null, .type = c.WGPUBufferBindingType_Storage, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = c.WGPUSamplerBindingType_BindingNotUsed },
            .texture = .{ .nextInChain = null, .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
            .storageTexture = .{ .nextInChain = null, .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
        },
        .{
            .nextInChain = null,
            .binding = 4,
            .visibility = c.WGPUShaderStage_Compute,
            .bindingArraySize = 0,
            .buffer = .{ .nextInChain = null, .type = c.WGPUBufferBindingType_Uniform, .hasDynamicOffset = c.WGPU_FALSE, .minBindingSize = 0 },
            .sampler = .{ .nextInChain = null, .type = c.WGPUSamplerBindingType_BindingNotUsed },
            .texture = .{ .nextInChain = null, .sampleType = c.WGPUTextureSampleType_BindingNotUsed, .viewDimension = c.WGPUTextureViewDimension_Undefined, .multisampled = c.WGPU_FALSE },
            .storageTexture = .{ .nextInChain = null, .access = c.WGPUStorageTextureAccess_BindingNotUsed, .format = c.WGPUTextureFormat_Undefined, .viewDimension = c.WGPUTextureViewDimension_Undefined },
        },
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

    const params = ParamsGpu{ .da = da, .db = db, .dt = dt, .feed = feed, .kill = kill };
    c.wgpuQueueWriteBuffer(g.queue, g.buf_params, 0, &params, @sizeOf(ParamsGpu));

    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return;

    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, null);
    c.wgpuComputePassEncoderSetPipeline(pass, g.pipeline);

    const bg = if (g.current_u == 0) g.bind_group_even else g.bind_group_odd;
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, null);

    const wg_x = (g.width + 15) / 16;
    const wg_y = (g.height + 15) / 16;
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, wg_x, wg_y, 1);
    c.wgpuComputePassEncoderEnd(pass);

    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return;

    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    // Wait for GPU to finish this step (ensures deterministic behavior)
    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);

    g.current_u = 1 - g.current_u;
    g.step_count += 1;
}

pub export fn gs_gpu_read_result(buf_ptr: [*]u8, buf_len: usize) u32 {
    if (!g.initialized) return 0;
    const grid_bytes: u64 = @as(u64, g.width) * @as(u64, g.height) * @sizeOf(f32);
    if (buf_len < grid_bytes) return 0;

    const src_u = if (g.current_u == 0) g.buf_u0 else g.buf_u1;

    // Copy from storage buffer to readback buffer
    const encoder = c.wgpuDeviceCreateCommandEncoder(g.device, null);
    if (encoder == null) return 0;
    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, src_u, 0, g.buf_u_readback, 0, grid_bytes);
    const cmd_buf = c.wgpuCommandEncoderFinish(encoder, null);
    c.wgpuCommandEncoderRelease(encoder);
    if (cmd_buf == null) return 0;
    c.wgpuQueueSubmit(g.queue, 1, &cmd_buf);
    c.wgpuCommandBufferRelease(cmd_buf);

    // Wait for copy to complete before mapping
    _ = c.wgpuDevicePoll(g.device, c.WGPU_TRUE, null);

    // Map readback buffer
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
        .callback = mapCallback,
        .userdata1 = &ctx,
        .userdata2 = null,
    };
    _ = c.wgpuBufferMapAsync(g.buf_u_readback, c.WGPUMapMode_Read, 0, grid_bytes, map_info);

    // Poll until map completes
    var poll_attempts: u32 = 0;
    while (poll_attempts < 100000 and !map_completed) : (poll_attempts += 1) {
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
    if (g.buf_u_readback != null) { c.wgpuBufferDestroy(g.buf_u_readback); c.wgpuBufferRelease(g.buf_u_readback); }
    if (g.buf_params != null) { c.wgpuBufferDestroy(g.buf_params); c.wgpuBufferRelease(g.buf_params); }
    if (g.buf_u0 != null) { c.wgpuBufferDestroy(g.buf_u0); c.wgpuBufferRelease(g.buf_u0); }
    if (g.buf_u1 != null) { c.wgpuBufferDestroy(g.buf_u1); c.wgpuBufferRelease(g.buf_u1); }
    if (g.buf_v0 != null) { c.wgpuBufferDestroy(g.buf_v0); c.wgpuBufferRelease(g.buf_v0); }
    if (g.buf_v1 != null) { c.wgpuBufferDestroy(g.buf_v1); c.wgpuBufferRelease(g.buf_v1); }
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
