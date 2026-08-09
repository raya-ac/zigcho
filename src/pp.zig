const std = @import("std");

pub const Input = extern struct {
    mode: u8,
    lazer: u8,
    padding: [2]u8 = .{ 0, 0 },
    mods: u32,
    max_combo: u32,
    large_tick_hits: u32 = 0,
    small_tick_hits: u32 = 0,
    slider_end_hits: u32 = 0,
    n_geki: u32,
    n_katu: u32,
    n300: u32,
    n100: u32,
    n50: u32,
    misses: u32,
    legacy_total_score: u32,
};

pub const Output = extern struct {
    pp: f64 = 0,
    stars: f64 = 0,
    max_combo: u32 = 0,
};

extern fn zigcho_pp_calculate(map_ptr: [*]const u8, map_len: usize, input: *const Input, output: *Output) c_int;

pub fn calculate(map: []const u8, input: Input) !Output {
    if (map.len == 0) return error.InvalidBeatmap;
    var output: Output = .{};
    if (zigcho_pp_calculate(map.ptr, map.len, &input, &output) != 0) return error.PerformanceCalculationFailed;
    if (!std.math.isFinite(output.pp) or !std.math.isFinite(output.stars)) return error.PerformanceCalculationFailed;
    return output;
}
