pub const Update = struct {
    name: []const u8,
    created_at: []const u8,
    commit: []const u8,
    markdown: []const u8,
};

pub const Build = struct {
    id: i64,
    version: []const u8,
    display_version: ?[]const u8 = null,
    created_at: []const u8,
    updates: []const Update,
};
