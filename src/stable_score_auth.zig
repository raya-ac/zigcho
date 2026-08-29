const sessions_mod = @import("sessions.zig");
const stable_client = @import("stable_client.zig");
const storage = @import("runtime_storage.zig");

pub const grace_lifetime_seconds: i64 = 5 * 60;

pub const Decision = enum {
    exact,
    grace,
    missing,
    foreign,
    offline,
    unknown,
    expired,
    consumed,
    revoked,
    current_not_grace,
    client_version_mismatch,
    client_hardware_mismatch,
    missing_login_client_binding,
    invalid_client_binding,
};

pub fn authorize(store: *storage.Store, sessions: *sessions_mod.Sessions, token: ?[]const u8, user_id: i32, submitted_binding: ?stable_client.Binding, submission_checksum: []const u8, now: i64) !Decision {
    return switch (sessions.authorizeScoreToken(token, user_id, submitted_binding)) {
        .exact => .exact,
        .missing => .missing,
        .foreign_live => .foreign,
        .offline => .offline,
        .client_version_mismatch => .client_version_mismatch,
        .client_hardware_mismatch => .client_hardware_mismatch,
        .missing_login_client_binding => .missing_login_client_binding,
        .invalid_client_binding => .invalid_client_binding,
        .grace_candidate => grace: {
            if (comptime !storage.is_postgres) break :grace .unknown;
            const present_token = token orelse break :grace .missing;
            const binding = submitted_binding orelse break :grace .invalid_client_binding;
            break :grace switch (try store.consumeStableScoreGrace(present_token, user_id, binding, submission_checksum, now)) {
                .accepted => .grace,
                .unknown => .unknown,
                .foreign => .foreign,
                .version_mismatch => .client_version_mismatch,
                .hardware_mismatch => .client_hardware_mismatch,
                .current_not_grace => .current_not_grace,
                .expired => .expired,
                .consumed => .consumed,
                .revoked => .revoked,
            };
        },
    };
}
