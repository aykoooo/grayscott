// Gray-Scott 9-point stencil compute shader
// IDENTICAL equations to src/simulation.zig stepDeterministic.
// This is the NAIVE baseline — one dispatch = one timestep.
// All subsequent optimizations build from this file.

struct Params {
    da: f32,
    db: f32,
    dt: f32,
    feed: f32,
    kill: f32,
}

@group(0) @binding(0) var<storage, read> u_in: array<f32>;
@group(0) @binding(1) var<storage, read> v_in: array<f32>;
@group(0) @binding(2) var<storage, read_write> u_out: array<f32>;
@group(0) @binding(3) var<storage, read_write> v_out: array<f32>;
@group(0) @binding(4) var<uniform> params: Params;

const WIDTH: u32 = 256u;
const HEIGHT: u32 = 256u;

fn laplacian(x: u32, y: u32, field: ptr<storage, array<f32>, read>) -> f32 {
    let idx = y * WIDTH + x;

    let x_l = select(x - 1u, WIDTH - 1u, x == 0u);
    let x_r = select(x + 1u, 0u, x + 1u >= WIDTH);
    let y_t = select(y - 1u, HEIGHT - 1u, y == 0u);
    let y_b = select(y + 1u, 0u, y + 1u >= HEIGHT);

    let center = (*field)[idx];
    let left   = (*field)[y * WIDTH + x_l];
    let right  = (*field)[y * WIDTH + x_r];
    let up     = (*field)[y_t * WIDTH + x];
    let down   = (*field)[y_b * WIDTH + x];
    let ne     = (*field)[y_t * WIDTH + x_r];
    let nw     = (*field)[y_t * WIDTH + x_l];
    let se     = (*field)[y_b * WIDTH + x_r];
    let sw     = (*field)[y_b * WIDTH + x_l];

    return 0.2 * (left + right + up + down)
         + 0.05 * (ne + nw + se + sw)
         - 1.0 * center;
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let x = id.x;
    let y = id.y;
    if (x >= WIDTH || y >= HEIGHT) { return; }

    let idx = y * WIDTH + x;
    let u_c = u_in[idx];
    let v_c = v_in[idx];

    let lap_u = laplacian(x, y, &u_in);
    let lap_v = laplacian(x, y, &v_in);

    let uvv = u_c * v_c * v_c;

    let u_next = u_c + params.dt * (params.da * lap_u - uvv + params.feed * (1.0 - u_c));
    let v_next = v_c + params.dt * (params.db * lap_v + uvv - (params.feed + params.kill) * v_c);

    u_out[idx] = clamp(u_next, 0.0, 1.0);
    v_out[idx] = clamp(v_next, 0.0, 1.0);
}