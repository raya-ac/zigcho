const d = @import("../deps.zig");
const domain = d.domain;
const bss = d.bss;

pub const Context = struct {
    target: []const u8,
    raw_path: []const u8,
    path: []const u8,
    trusted_proxy: bool,
    auth_owned: ?[]const u8,
    osu_token_owned: ?[]const u8,
    score_token_owned: ?[]const u8,
    content_type_owned: ?[]const u8,
    country_owned: ?[]const u8,
    host_owned: ?[]const u8,
    cookie_owned: ?[]const u8,
    csrf_owned: ?[]const u8,
    origin_owned: ?[]const u8,
    client_ip_owned: ?[]const u8,
    bss_path: ?bss.Path = null,
    bss_user: ?domain.User = null,
    body: []const u8 = &.{},
};
