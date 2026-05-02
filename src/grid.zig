const std = @import("std");

/// Gray-Scott Grid using Structure of Arrays (SoA) layout for optimal cache
/// efficiency and SIMD vectorization.
pub const GrayScottGrid = struct {
    u: []f32, // Chemical A (activator) concentrations
    v: []f32, // Chemical B (inhibitor) concentrations
    width: usize,
    height: usize,
    allocator: std.mem.Allocator,

    /// Initialize a new grid with given dimensions
    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !GrayScottGrid {
        const size = width * height;
        return .{
            .u = try allocator.alloc(f32, size),
            .v = try allocator.alloc(f32, size),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    /// Free all allocated memory
    pub fn deinit(self: *GrayScottGrid) void {
        self.allocator.free(self.u);
        self.allocator.free(self.v);
    }

    /// Calculate flat index from 2D coordinates
    pub fn idx(self: GrayScottGrid, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    /// Get value of chemical A at position
    pub fn getU(self: GrayScottGrid, x: usize, y: usize) f32 {
        return self.u[self.idx(x, y)];
    }

    /// Get value of chemical B at position
    pub fn getV(self: GrayScottGrid, x: usize, y: usize) f32 {
        return self.v[self.idx(x, y)];
    }

    /// Set value of chemical A at position
    pub fn setU(self: *GrayScottGrid, x: usize, y: usize, value: f32) void {
        self.u[self.idx(x, y)] = value;
    }

    /// Set value of chemical B at position
    pub fn setV(self: *GrayScottGrid, x: usize, y: usize, value: f32) void {
        self.v[self.idx(x, y)] = value;
    }

    /// Fill the grid with initial conditions
    pub fn fill(self: *GrayScottGrid, u_val: f32, v_val: f32) void {
        @memset(self.u, u_val);
        @memset(self.v, v_val);
    }

    /// Seed a square region at an arbitrary position
    pub fn seedSquareAt(self: *GrayScottGrid, center_x: usize, center_y: usize, size: usize, u_val: f32, v_val: f32) void {
        const half = size / 2;

        var y: usize = if (center_y > half) center_y - half else 0;
        const end_y = @min(center_y + half, self.height);
        while (y < end_y) : (y += 1) {
            var x: usize = if (center_x > half) center_x - half else 0;
            const end_x = @min(center_x + half, self.width);
            while (x < end_x) : (x += 1) {
                self.u[self.idx(x, y)] = u_val;
                self.v[self.idx(x, y)] = v_val;
            }
        }
    }

    /// Seed a square region in the center with specified values
    pub fn seedSquare(self: *GrayScottGrid, size: usize, u_val: f32, v_val: f32) void {
        const center_x = self.width / 2;
        const center_y = self.height / 2;
        const half = size / 2;

        var y: usize = if (center_y > half) center_y - half else 0;
        const end_y = @min(center_y + half, self.height);
        while (y < end_y) : (y += 1) {
            var x: usize = if (center_x > half) center_x - half else 0;
            const end_x = @min(center_x + half, self.width);
            while (x < end_x) : (x += 1) {
                self.u[self.idx(x, y)] = u_val;
                self.v[self.idx(x, y)] = v_val;
            }
        }
    }

    /// Swap this grid with another (ping-pong buffer swap)
    pub fn swap(self: *GrayScottGrid, other: *GrayScottGrid) void {
        std.mem.swap([]f32, &self.u, &other.u);
        std.mem.swap([]f32, &self.v, &other.v);
    }

    /// Copy data from another grid
    pub fn copyFrom(self: *GrayScottGrid, other: *const GrayScottGrid) void {
        @memcpy(self.u[0..], other.u[0..]);
        @memcpy(self.v[0..], other.v[0..]);
    }
};
