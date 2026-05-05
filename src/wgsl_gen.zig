const std = @import("std");

pub fn generateWgsl(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
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
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_n, tile_x, tile_y });
}

pub fn generateWgslVec2(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
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

pub fn generateWgslSubgroups(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
    const stride: u32 = tile_x + 2;
    const rows: u32 = tile_y + 2;
    const tile_n: u32 = stride * rows;
    return std.fmt.bufPrint(buf,
        \\enable subgroups;
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
        \\    let u_c = tile_u[ti];
        \\    let v_c = tile_v[ti];
        \\    let interior_col = lid.x > 0u && lid.x < TX - 1u;
        \\    let interior_row = lid.y > 0u && lid.y < TY - 1u;
        \\    if (interior_col && interior_row) {{
        \\        let u_l = subgroupShuffleUp(u_c, 1u);
        \\        let u_r = subgroupShuffleDown(u_c, 1u);
        \\        let u_sh_up = subgroupShuffleUp(u_c, 16u);
        \\        let u_sh_dn = subgroupShuffleDown(u_c, 16u);
        \\        let u_ne = subgroupShuffleDown(u_sh_up, 1u);
        \\        let u_nw = subgroupShuffleUp(u_sh_up, 1u);
        \\        let u_se = subgroupShuffleDown(u_sh_dn, 1u);
        \\        let u_sw = subgroupShuffleUp(u_sh_dn, 1u);
        \\        let lap_u = 0.2 * (u_l + u_r + u_sh_up + u_sh_dn)
        \\            + 0.05 * (u_ne + u_nw + u_se + u_sw)
        \\            - 1.0 * u_c;
        \\        let v_l = subgroupShuffleUp(v_c, 1u);
        \\        let v_r = subgroupShuffleDown(v_c, 1u);
        \\        let v_sh_up = subgroupShuffleUp(v_c, 16u);
        \\        let v_sh_dn = subgroupShuffleDown(v_c, 16u);
        \\        let v_ne = subgroupShuffleDown(v_sh_up, 1u);
        \\        let v_nw = subgroupShuffleUp(v_sh_up, 1u);
        \\        let v_se = subgroupShuffleDown(v_sh_dn, 1u);
        \\        let v_sw = subgroupShuffleUp(v_sh_dn, 1u);
        \\        let lap_v = 0.2 * (v_l + v_r + v_sh_up + v_sh_dn)
        \\            + 0.05 * (v_ne + v_nw + v_se + v_sw)
        \\            - 1.0 * v_c;
        \\        let uvv = u_c * v_c * v_c;
        \\        let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\        let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\        let out_idx = y * WIDTH + x;
        \\        u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\        v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\        return;
        \\    }}
        \\    let u_left   = tile_u[(lid.y + 1u) * STRIDE + (lid.x    )];
        \\    let u_right  = tile_u[(lid.y + 1u) * STRIDE + (lid.x + 2u)];
        \\    let u_up     = tile_u[(lid.y    ) * STRIDE + (lid.x + 1u)];
        \\    let u_down   = tile_u[(lid.y + 2u) * STRIDE + (lid.x + 1u)];
        \\    let u_ne     = tile_u[(lid.y    ) * STRIDE + (lid.x + 2u)];
        \\    let u_nw     = tile_u[(lid.y    ) * STRIDE + (lid.x    )];
        \\    let u_se     = tile_u[(lid.y + 2u) * STRIDE + (lid.x + 2u)];
        \\    let u_sw     = tile_u[(lid.y + 2u) * STRIDE + (lid.x    )];
        \\    let lap_u = 0.2 * (u_left + u_right + u_up + u_down)
        \\        + 0.05 * (u_ne + u_nw + u_se + u_sw)
        \\        - 1.0 * u_c;
        \\    let v_left   = tile_v[(lid.y + 1u) * STRIDE + (lid.x    )];
        \\    let v_right  = tile_v[(lid.y + 1u) * STRIDE + (lid.x + 2u)];
        \\    let v_up     = tile_v[(lid.y    ) * STRIDE + (lid.x + 1u)];
        \\    let v_down   = tile_v[(lid.y + 2u) * STRIDE + (lid.x + 1u)];
        \\    let v_ne     = tile_v[(lid.y    ) * STRIDE + (lid.x + 2u)];
        \\    let v_nw     = tile_v[(lid.y    ) * STRIDE + (lid.x    )];
        \\    let v_se     = tile_v[(lid.y + 2u) * STRIDE + (lid.x + 2u)];
        \\    let v_sw     = tile_v[(lid.y + 2u) * STRIDE + (lid.x    )];
        \\    let lap_v = 0.2 * (v_left + v_right + v_up + v_down)
        \\        + 0.05 * (v_ne + v_nw + v_se + v_sw)
        \\        - 1.0 * v_c;
        \\    let uvv = u_c * v_c * v_c;
        \\    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
        \\    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);
        \\    let out_idx = y * WIDTH + x;
        \\    u_out[out_idx] = clamp(u_next, 0.0, 1.0);
        \\    v_out[out_idx] = clamp(v_next, 0.0, 1.0);
        \\}}
    , .{ w, h, tile_x, tile_y, stride, tile_n, tile_n, tile_x, tile_y });
}

pub fn generateWgslPearson(buf: []u8, w: u32, h: u32, tile_x: u32, tile_y: u32) ![]const u8 {
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