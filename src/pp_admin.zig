const std = @import("std");
const exact = @import("exact_pp.zig");

// Zigcho owns this policy boundary. The pinned projects below it still own the
// difficulty and performance formulae until a candidate is proven against real
// scores. A policy bump therefore says what Zigcho changed without pretending
// an upstream dependency is first-party math.
pub const policy_version = "zigcho-pp-policy-1";
pub const upstream_engine_version = exact.engine_version;

pub const max_map_bytes: usize = 64 * 1024 * 1024;
pub const max_mods_json_bytes: usize = 64 * 1024;
pub const max_mod_entries: usize = 64;
pub const max_preview_items: usize = 32;
pub const max_recalculation_items: usize = 256;
pub const max_batch_map_bytes: usize = 128 * 1024 * 1024;

const relax: u32 = 1 << 7;
const double_time: u32 = 1 << 6;
const nightcore: u32 = 1 << 9;
const sudden_death: u32 = 1 << 5;
const perfect: u32 = 1 << 14;
const half_time: u32 = 1 << 8;
const autopilot: u32 = 1 << 13;
const score_v2: u32 = 1 << 29;

pub const Source = enum {
    stable,
    lazer,
};

pub const Namespace = enum {
    vanilla,
    relax,
    autopilot,
    scorev2,
};

pub const RateMod = enum {
    none,
    half_time,
    double_time,
    nightcore,
};

pub const Request = struct {
    source: Source,
    namespace: Namespace,
    input: exact.Input,
    // This remains the exact client JSON. Re-encoding it would discard lazer
    // settings such as DT/NC speed_change and difficulty adjustments.
    mods_json: []const u8 = "",
};

pub const Rate = struct {
    mod: RateMod = .none,
    multiplier: f64 = 1,
};

pub const NormalizedRequest = struct {
    source: Source,
    namespace: Namespace,
    input: exact.Input,
    mods_json: []const u8,
    rate: Rate,
};

pub const Delta = struct {
    pp: f64,
    stars: f64,
    max_combo: i64,
    pp_percent: ?f64,
};

pub const Comparison = struct {
    source: Source,
    namespace: Namespace,
    policy: []const u8 = policy_version,
    upstream_engine: []const u8 = upstream_engine_version,
    submitted_mods: u32,
    candidate_mods: u32,
    rate: Rate,
    current: exact.Output,
    candidate: exact.Output,
    delta: Delta,
    changed: bool,
};

pub const PreviewItem = struct {
    map: []const u8,
    request: Request,
};

pub const PreviewBatch = struct {
    items: []Comparison,

    pub fn deinit(self: *PreviewBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const RecalculationRecord = struct {
    score_id: i64,
    map: []const u8,
    request: Request,
};

pub const CandidateUpdate = struct {
    score_id: i64,
    current: exact.Output,
    candidate: exact.Output,
    delta: Delta,
};

pub const RecalculationPlan = struct {
    inspected: usize,
    unchanged: usize,
    // Only the visible prefix contains updates. Storage is kept separately so
    // deallocation always receives the exact slice returned by the allocator.
    updates: []const CandidateUpdate,
    storage: []CandidateUpdate,

    pub fn deinit(self: *RecalculationPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn versionAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ policy_version, upstream_engine_version });
}

fn stableNamespace(mods: u32) Namespace {
    // This matches the server's explicit malformed-input priority. Never let
    // integer bit order silently choose which stat namespace receives a play.
    if (mods & autopilot != 0) return .autopilot;
    if (mods & relax != 0) return .relax;
    if (mods & score_v2 != 0) return .scorev2;
    return .vanilla;
}

fn lazerNamespace(mods: u32) Namespace {
    if (mods & autopilot != 0) return .autopilot;
    if (mods & relax != 0) return .relax;
    return .vanilla;
}

fn stableRate(mods: u32) Rate {
    if (mods & nightcore != 0) return .{ .mod = .nightcore, .multiplier = 1.5 };
    if (mods & double_time != 0) return .{ .mod = .double_time, .multiplier = 1.5 };
    if (mods & half_time != 0) return .{ .mod = .half_time, .multiplier = 0.75 };
    return .{};
}

fn number(value: std.json.Value) ?f64 {
    const result: f64 = switch (value) {
        .integer => |item| @floatFromInt(item),
        .float => |item| item,
        else => return null,
    };
    if (!std.math.isFinite(result) or result <= 0) return null;
    return result;
}

fn lazerRate(allocator: std.mem.Allocator, mods_json: []const u8) !Rate {
    if (mods_json.len == 0 or mods_json.len > max_mods_json_bytes) return error.InvalidModsJson;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, mods_json, .{}) catch return error.InvalidModsJson;
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidModsJson,
    };
    if (items.len > max_mod_entries) return error.TooManyMods;

    var rate: Rate = .{};
    for (items) |item| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidModsJson,
        };
        const acronym = switch (object.get("acronym") orelse return error.InvalidModsJson) {
            .string => |value| value,
            else => return error.InvalidModsJson,
        };
        const kind: RateMod = if (std.mem.eql(u8, acronym, "NC"))
            .nightcore
        else if (std.mem.eql(u8, acronym, "DT"))
            .double_time
        else if (std.mem.eql(u8, acronym, "HT"))
            .half_time
        else
            continue;
        const default_multiplier: f64 = if (kind == .half_time) 0.75 else 1.5;
        var multiplier = default_multiplier;
        if (object.get("settings")) |settings_value| {
            const settings = switch (settings_value) {
                .object => |value| value,
                else => return error.InvalidModsJson,
            };
            if (settings.get("speed_change")) |speed| multiplier = number(speed) orelse return error.InvalidModsJson;
        }
        // NC is the visible form when both canonical NC and DT are present.
        if (rate.mod != .nightcore or kind == .nightcore) rate = .{ .mod = kind, .multiplier = multiplier };
    }
    return rate;
}

fn validMode(namespace: Namespace, mode: u8) bool {
    return switch (namespace) {
        .relax => mode != 3,
        .autopilot => mode == 0,
        .vanilla, .scorev2 => mode <= 3,
    };
}

pub fn normalize(allocator: std.mem.Allocator, request: Request) !NormalizedRequest {
    if (request.input.mode > 3 or !validMode(request.namespace, request.input.mode)) return error.UnsupportedModMode;

    var input = request.input;
    const rate = switch (request.source) {
        .stable => block: {
            if (input.lazer != 0 or request.mods_json.len != 0) return error.SourceMismatch;
            if (stableNamespace(input.mods) != request.namespace) return error.NamespaceMismatch;
            // Canonical implications are policy, not new formulae. Keep RX/AP
            // byte-for-byte on their pinned Akatsuki path as requested.
            if (request.namespace == .vanilla or request.namespace == .scorev2) {
                if (input.mods & nightcore != 0) input.mods |= double_time;
                if (input.mods & perfect != 0) input.mods |= sudden_death;
            }
            break :block stableRate(input.mods);
        },
        .lazer => block: {
            if (input.lazer == 0 or request.namespace == .scorev2) return error.SourceMismatch;
            if (lazerNamespace(input.mods) != request.namespace) return error.NamespaceMismatch;
            break :block try lazerRate(allocator, request.mods_json);
        },
    };
    return .{
        .source = request.source,
        .namespace = request.namespace,
        .input = input,
        .mods_json = request.mods_json,
        .rate = rate,
    };
}

fn calculateCurrent(map: []const u8, request: Request) !exact.Output {
    return switch (request.source) {
        .stable => exact.calculate(map, request.input),
        .lazer => if (request.namespace == .vanilla)
            exact.calculateLazer(map, request.mods_json, request.input)
        else
            exact.calculate(map, request.input),
    };
}

fn calculateNormalized(map: []const u8, request: NormalizedRequest) !exact.Output {
    return switch (request.source) {
        .stable => exact.calculate(map, request.input),
        .lazer => if (request.namespace == .vanilla)
            exact.calculateLazer(map, request.mods_json, request.input)
        else
            // Relax/AP stay on their existing pinned path. The candidate layer
            // records them, but does not change their formula or input.
            exact.calculate(map, request.input),
    };
}

// This is the single-calculation entry point for live callers once they move
// behind the policy boundary. Comparison deliberately remains separate because
// it evaluates the old and candidate paths side by side.
pub fn calculate(allocator: std.mem.Allocator, map: []const u8, request: Request) !exact.Output {
    if (map.len == 0) return error.EmptyBeatmap;
    if (map.len > max_map_bytes) return error.BeatmapTooLarge;
    return calculateNormalized(map, try normalize(allocator, request));
}

fn outputDelta(current: exact.Output, candidate: exact.Output) Delta {
    return .{
        .pp = candidate.pp - current.pp,
        .stars = candidate.stars - current.stars,
        .max_combo = @as(i64, candidate.max_combo) - @as(i64, current.max_combo),
        .pp_percent = if (current.pp == 0) null else (candidate.pp - current.pp) / current.pp * 100,
    };
}

fn materiallyChanged(delta: Delta) bool {
    return @abs(delta.pp) > 0.0000001 or @abs(delta.stars) > 0.000000001 or delta.max_combo != 0;
}

pub fn compare(allocator: std.mem.Allocator, map: []const u8, request: Request) !Comparison {
    if (map.len == 0) return error.EmptyBeatmap;
    if (map.len > max_map_bytes) return error.BeatmapTooLarge;
    const normalized = try normalize(allocator, request);
    const current = try calculateCurrent(map, request);
    const candidate = try calculateNormalized(map, normalized);
    const delta = outputDelta(current, candidate);
    return .{
        .source = request.source,
        .namespace = request.namespace,
        .submitted_mods = request.input.mods,
        .candidate_mods = normalized.input.mods,
        .rate = normalized.rate,
        .current = current,
        .candidate = candidate,
        .delta = delta,
        .changed = materiallyChanged(delta),
    };
}

fn batchBytes(items: []const PreviewItem) !usize {
    var total: usize = 0;
    for (items) |item| total = std.math.add(usize, total, item.map.len) catch return error.PreviewPayloadTooLarge;
    if (total > max_batch_map_bytes) return error.PreviewPayloadTooLarge;
    return total;
}

pub fn preview(allocator: std.mem.Allocator, items: []const PreviewItem) !PreviewBatch {
    if (items.len == 0) return error.EmptyPreview;
    if (items.len > max_preview_items) return error.TooManyPreviewItems;
    _ = try batchBytes(items);
    const comparisons = try allocator.alloc(Comparison, items.len);
    errdefer allocator.free(comparisons);
    for (items, 0..) |item, index| comparisons[index] = try compare(allocator, item.map, item.request);
    return .{ .items = comparisons };
}

pub fn planRecalculation(allocator: std.mem.Allocator, records: []const RecalculationRecord) !RecalculationPlan {
    if (records.len == 0) return error.EmptyRecalculation;
    if (records.len > max_recalculation_items) return error.TooManyRecalculationItems;
    var total: usize = 0;
    for (records) |record| {
        if (record.score_id <= 0) return error.InvalidScoreId;
        total = std.math.add(usize, total, record.map.len) catch return error.RecalculationPayloadTooLarge;
    }
    if (total > max_batch_map_bytes) return error.RecalculationPayloadTooLarge;

    const storage = try allocator.alloc(CandidateUpdate, records.len);
    errdefer allocator.free(storage);
    var changed: usize = 0;
    for (records) |record| {
        const result = try compare(allocator, record.map, record.request);
        if (!result.changed) continue;
        storage[changed] = .{
            .score_id = record.score_id,
            .current = result.current,
            .candidate = result.candidate,
            .delta = result.delta,
        };
        changed += 1;
    }
    return .{
        .inspected = records.len,
        .unchanged = records.len - changed,
        .updates = storage[0..changed],
        .storage = storage,
    };
}

fn stableFixture(mods: u32) Request {
    return .{
        .source = .stable,
        .namespace = stableNamespace(mods),
        .input = .{
            .mode = 0,
            .lazer = 0,
            .mods = mods,
            .max_combo = 10,
            .n_geki = 0,
            .n_katu = 0,
            .n300 = 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 1_000_000,
        },
    };
}

test "pp policy exposes its owned version and stable baseline" {
    const version = try versionAlloc(std.testing.allocator);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("zigcho-pp-policy-1/stable-rosu-4.0.1-lazer-2026.730.0-1129a7e-akatsuki-591de0d.1", version);

    const map = @embedFile("testdata/synthetic-standard.osu");
    const comparison = try compare(std.testing.allocator, map, stableFixture(double_time | nightcore));
    try std.testing.expectEqual(Source.stable, comparison.source);
    try std.testing.expectEqual(Namespace.vanilla, comparison.namespace);
    try std.testing.expectEqual(RateMod.nightcore, comparison.rate.mod);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), comparison.rate.multiplier, 0.0000001);
    try std.testing.expect(!comparison.changed);
    try std.testing.expectApproxEqAbs(comparison.current.pp, comparison.candidate.pp, 0.0000001);

    const normalized = try normalize(std.testing.allocator, stableFixture(nightcore));
    try std.testing.expect(normalized.input.mods & double_time != 0);
}

test "pp policy keeps exact lazer rates in the comparison" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const comparison = try compare(std.testing.allocator, map, .{
        .source = .lazer,
        .namespace = .vanilla,
        .mods_json = "[{\"acronym\":\"DT\",\"settings\":{\"speed_change\":1.25}}]",
        .input = .{
            .mode = 0,
            .lazer = 1,
            .mods = double_time,
            .max_combo = 10,
            .n_geki = 0,
            .n_katu = 0,
            .n300 = 10,
            .n100 = 0,
            .n50 = 0,
            .misses = 0,
            .legacy_total_score = 0,
        },
    });
    try std.testing.expectEqual(RateMod.double_time, comparison.rate.mod);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), comparison.rate.multiplier, 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 39.036597621743), comparison.candidate.pp, 0.0000001);
    try std.testing.expect(!comparison.changed);
}

test "pp policy previews and recalculation plans stay bounded without changing relax or autopilot" {
    const map = @embedFile("testdata/synthetic-standard.osu");
    const requests = [_]Request{ stableFixture(relax), stableFixture(autopilot) };
    const preview_items = [_]PreviewItem{
        .{ .map = map, .request = requests[0] },
        .{ .map = map, .request = requests[1] },
    };
    var result = try preview(std.testing.allocator, &preview_items);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expect(!result.items[0].changed and !result.items[1].changed);

    const records = [_]RecalculationRecord{
        .{ .score_id = 1, .map = map, .request = requests[0] },
        .{ .score_id = 2, .map = map, .request = requests[1] },
    };
    var plan = try planRecalculation(std.testing.allocator, &records);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.inspected);
    try std.testing.expectEqual(@as(usize, 2), plan.unchanged);
    try std.testing.expectEqual(@as(usize, 0), plan.updates.len);

    const oversized = [_]PreviewItem{preview_items[0]} ** (max_preview_items + 1);
    try std.testing.expectError(error.TooManyPreviewItems, preview(std.testing.allocator, &oversized));
}
