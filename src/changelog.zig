const std = @import("std");

pub const latest_version = "2026.831.0";
pub const max_updates: usize = 256;
pub const max_build_id: i64 = @divFloor(std.math.maxInt(i64) - @as(i64, max_updates - 1), 100);

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

pub const fallback_builds = [_]Build{
    .{ .id = 46, .version = "2026.831.0", .display_version = "zigcho release 2.0", .created_at = "2026-08-31T00:45:07+09:30", .updates = &.{
        .{ .name = "2026-08-31-anticheat-review-and-replay-signals.md", .created_at = "2026-08-31T00:45:07+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-31-anticheat-review-and-replay-signals.md") },
    } },
    .{ .id = 45, .version = "2026.830.2", .display_version = "zigcho release 1.9", .created_at = "2026-08-30T18:13:18+09:30", .updates = &.{
        .{ .name = "2026-08-30-lazer-multiplayer-leaves.md", .created_at = "2026-08-30T18:13:18+09:30", .commit = "3088e91fa830c0f7291792ad0af4e98fdcd211f7", .markdown = @embedFile("../updates/2026-08-30-lazer-multiplayer-leaves.md") },
        .{ .name = "2026-08-30-lazer-signalr-wire.md", .created_at = "2026-08-30T18:12:07+09:30", .commit = "00bc1569ffa40024ede50e18a6dbf3f91eb0ec93", .markdown = @embedFile("../updates/2026-08-30-lazer-signalr-wire.md") },
        .{ .name = "2026-08-30-lazer-multiplayer-paths-and-scoring.md", .created_at = "2026-08-30T18:11:31+09:30", .commit = "43f06c4bbfed746b2ad7a8cf72254e26b4641608", .markdown = @embedFile("../updates/2026-08-30-lazer-multiplayer-paths-and-scoring.md") },
        .{ .name = "2026-08-30-lazer-multiplayer-models.md", .created_at = "2026-08-30T18:11:06+09:30", .commit = "81257eb1bdca2a76e27ed2f5dd5689f12cd55bf5", .markdown = @embedFile("../updates/2026-08-30-lazer-multiplayer-models.md") },
    } },
    .{ .id = 44, .version = "2026.830.1", .display_version = "zigcho release 1.8", .created_at = "2026-08-30T17:32:56+09:30", .updates = &.{
        .{ .name = "2026-08-30-stable-conformance.md", .created_at = "2026-08-30T17:32:56+09:30", .commit = "44eba5ac03be05747d339f3a984e175e72191816", .markdown = @embedFile("../updates/2026-08-30-stable-conformance.md") },
    } },
    .{ .id = 43, .version = "2026.830.0", .display_version = "zigcho release 1.7", .created_at = "2026-08-30T13:49:43+09:30", .updates = &.{
        .{ .name = "2026-08-30-server-file-split.md", .created_at = "2026-08-30T13:49:43+09:30", .commit = "c4fa1f5dab17ee7969dfa40f8f747acac761988a", .markdown = @embedFile("../updates/2026-08-30-server-file-split.md") },
    } },
    .{ .id = 42, .version = "2026.829.1", .display_version = "zigcho release 1.6", .created_at = "2026-08-29T15:21:02+09:30", .updates = &.{
        .{ .name = "2026-08-29-stable-and-score-hardening.md", .created_at = "2026-08-29T15:21:02+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-29-stable-and-score-hardening.md") },
    } },
    .{ .id = 41, .version = "2026.829.0", .display_version = "zigcho release 1.5", .created_at = "2026-08-29T12:50:00+09:30", .updates = &.{
        .{ .name = "2026-08-29-fast-hotfixes.md", .created_at = "2026-08-29T12:50:00+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-29-fast-hotfixes.md") },
    } },
    .{ .id = 40, .version = "2026.828.0", .display_version = "zigcho release 1.4", .created_at = "2026-08-28T14:06:17+09:30", .updates = &.{
        .{ .name = "2026-08-28-lazer-pauses-and-map-downloads.md", .created_at = "2026-08-28T14:06:17+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-28-lazer-pauses-and-map-downloads.md") },
    } },
    .{ .id = 39, .version = "2026.826.1", .display_version = "zigcho release 1.3", .created_at = "2026-08-26T06:56:11+09:30", .updates = &.{
        .{ .name = "2026-08-26-anticheat-roles-and-name-history.md", .created_at = "2026-08-26T06:56:11+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-26-anticheat-roles-and-name-history.md") },
    } },
    .{ .id = 38, .version = "2026.826.0", .display_version = "zigcho release 1.2", .created_at = "2026-08-26T04:10:50+09:30", .updates = &.{
        .{ .name = "2026-08-26-controls-results-and-local-maps.md", .created_at = "2026-08-26T04:10:50+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-26-controls-results-and-local-maps.md") },
    } },
    .{ .id = 37, .version = "2026.825.1", .display_version = "zigcho release 1.1.1", .created_at = "2026-08-25T01:18:00+09:30", .updates = &.{
        .{ .name = "2026-08-25-classic-score-and-profile-graphs.md", .created_at = "2026-08-25T01:18:00+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-25-classic-score-and-profile-graphs.md") },
    } },
    .{ .id = 36, .version = "2026.825.0", .display_version = "zigcho release 1.1", .created_at = "2026-08-25T00:19:25+09:30", .updates = &.{
        .{ .name = "2026-08-25-shared-profiles-and-score-state.md", .created_at = "2026-08-25T00:19:25+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-25-shared-profiles-and-score-state.md") },
    } },
    .{ .id = 35, .version = "2026.824.0", .display_version = "zigcho release 1", .created_at = "2026-08-24T18:18:10+09:30", .updates = &.{
        .{ .name = "2026-08-24-lazer-multiplayer-profiles-and-routes.md", .created_at = "2026-08-24T18:18:10+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-24-lazer-multiplayer-profiles-and-routes.md") },
    } },
    .{ .id = 34, .version = "2026.823.0", .created_at = "2026-08-23T02:15:00+09:30", .updates = &.{
        .{ .name = "2026-08-23-maps-rooms-and-presence.md", .created_at = "2026-08-23T18:09:51+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-23-maps-rooms-and-presence.md") },
        .{ .name = "2026-08-23-bss-local-mappers.md", .created_at = "2026-08-23T15:03:08+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-23-bss-local-mappers.md") },
        .{ .name = "2026-08-23-lazer-profiles-and-sessions.md", .created_at = "2026-08-23T02:15:00+09:30", .commit = "", .markdown = @embedFile("../updates/2026-08-23-lazer-profiles-and-sessions.md") },
    } },
    .{ .id = 33, .version = "2026.822.0", .created_at = "2026-08-22T20:24:54+09:30", .updates = &.{
        .{ .name = "2026-08-22-mirror-and-object-backups.md", .created_at = "2026-08-22T20:24:54+09:30", .commit = "a419d2970a194db5b274deb80d1672188f56d729", .markdown = @embedFile("../updates/2026-08-22-mirror-and-object-backups.md") },
        .{ .name = "2026-08-22-achievements-presence-and-controls.md", .created_at = "2026-08-22T20:24:49+09:30", .commit = "d6fc4e35fc858d8fbe3f59a5c19418bc7cc8dc21", .markdown = @embedFile("../updates/2026-08-22-achievements-presence-and-controls.md") },
        .{ .name = "2026-08-22-stable-lazer-identity-and-rates.md", .created_at = "2026-08-22T19:39:40+09:30", .commit = "ec82b77f5a1c621a8f6fccbadb3f668be61b727f", .markdown = @embedFile("../updates/2026-08-22-stable-lazer-identity-and-rates.md") },
        .{ .name = "2026-08-22-lazer-pp-and-shared-boards.md", .created_at = "2026-08-22T16:01:06+09:30", .commit = "a9683ac42f03899862d8a2e890c4af933e91df51", .markdown = @embedFile("../updates/2026-08-22-lazer-pp-and-shared-boards.md") },
    } },
    .{ .id = 27, .version = "2026.816.0", .created_at = "2026-08-16T23:33:56+09:30", .updates = &.{
        .{ .name = "2026-08-16-object-storage-cutover.md", .created_at = "2026-08-16T23:33:56+09:30", .commit = "6561e503a8629204ff3be5191c5ca1ff64a6bb93", .markdown = @embedFile("../updates/2026-08-16-object-storage-cutover.md") },
        .{ .name = "2026-08-16-lazer-pp-bests.md", .created_at = "2026-08-16T21:39:35+09:30", .commit = "b4325cedee38904facf133e1ce57d17c6ee66b91", .markdown = @embedFile("../updates/2026-08-16-lazer-pp-bests.md") },
        .{ .name = "2026-08-16-object-storage.md", .created_at = "2026-08-16T21:24:29+09:30", .commit = "a9592bd8b3e13a01c98735610592999312bff59d", .markdown = @embedFile("../updates/2026-08-16-object-storage.md") },
        .{ .name = "2026-08-16-lazer-profiles-and-results.md", .created_at = "2026-08-16T19:28:30+09:30", .commit = "ff488dbb81a66bb72eeb7080597c382438bfff6a", .markdown = @embedFile("../updates/2026-08-16-lazer-profiles-and-results.md") },
        .{ .name = "2026-08-16-lazer-ranked-play.md", .created_at = "2026-08-16T16:02:59+09:30", .commit = "fd597ac7d24a75760038b1ea52949a3744a2b992", .markdown = @embedFile("../updates/2026-08-16-lazer-ranked-play.md") },
        .{ .name = "2026-08-16-lazer-quick-play.md", .created_at = "2026-08-16T14:09:37+09:30", .commit = "3a739e2c1cd7a49b29b531663c1fdaf57c13d46b", .markdown = @embedFile("../updates/2026-08-16-lazer-quick-play.md") },
        .{ .name = "2026-08-16-lazer-alpha-seven.md", .created_at = "2026-08-16T12:58:35+09:30", .commit = "d419cf608c2adafb3d3fc17637f0c1ec3a6a74a5", .markdown = @embedFile("../updates/2026-08-16-lazer-alpha-seven.md") },
        .{ .name = "2026-08-16-lazer-alpha-six.md", .created_at = "2026-08-16T11:31:25+09:30", .commit = "124e04d4253f12a291fe8accc9aa4df30ad9e13a", .markdown = @embedFile("../updates/2026-08-16-lazer-alpha-six.md") },
        .{ .name = "2026-08-16-lazer-alpha-five.md", .created_at = "2026-08-16T09:05:43+09:30", .commit = "60f44aeb49b0a2b6719399dfed12d2a08dabfa40", .markdown = @embedFile("../updates/2026-08-16-lazer-alpha-five.md") },
        .{ .name = "2026-08-16-lazer-alpha-four.md", .created_at = "2026-08-16T08:24:08+09:30", .commit = "3774e4d2ac4a642fdc88465195cb5446b6182cda", .markdown = @embedFile("../updates/2026-08-16-lazer-alpha-four.md") },
    } },
    .{ .id = 26, .version = "2026.815.0", .created_at = "2026-08-15T23:18:38+09:30", .updates = &.{
        .{ .name = "2026-08-15-lazer-leaderboards.md", .created_at = "2026-08-15T23:18:38+09:30", .commit = "e681eef6ae0574fe2278c456fa3f1862423178aa", .markdown = @embedFile("../updates/2026-08-15-lazer-leaderboards.md") },
        .{ .name = "2026-08-15-lazer-alpha-two.md", .created_at = "2026-08-15T22:03:26+09:30", .commit = "d5c2808915bc25fd2a417342e910effa0b0f8e9d", .markdown = @embedFile("../updates/2026-08-15-lazer-alpha-two.md") },
        .{ .name = "2026-08-15-lazer-maps-and-chat.md", .created_at = "2026-08-15T19:05:00+09:30", .commit = "b7c819ca3faf914721665bee9a7dd30225238ae8", .markdown = @embedFile("../updates/2026-08-15-lazer-maps-and-chat.md") },
    } },
    .{ .id = 25, .version = "2026.814.0", .created_at = "2026-08-14T16:58:32+09:30", .updates = &.{
        .{ .name = "2026-08-14-profile-score-details.md", .created_at = "2026-08-14T16:58:32+09:30", .commit = "a9b869c96619a59b62c5ac87eaffe571d15b4b45", .markdown = @embedFile("../updates/2026-08-14-profile-score-details.md") },
        .{ .name = "2026-08-14-player-pages-and-replays.md", .created_at = "2026-08-14T14:38:13+09:30", .commit = "d5f7f8819b6a8613adcd7f24de309cea43c7c22d", .markdown = @embedFile("../updates/2026-08-14-player-pages-and-replays.md") },
        .{ .name = "2026-08-14-web-accounts-and-avatars.md", .created_at = "2026-08-14T13:36:55+09:30", .commit = "628eb9778e3520853703d5ddb7652e2bec335a6c", .markdown = @embedFile("../updates/2026-08-14-web-accounts-and-avatars.md") },
    } },
    .{ .id = 24, .version = "2026.813.0", .created_at = "2026-08-13T15:45:58+09:30", .updates = &.{
        .{ .name = "2026-08-13-lazer-windows-alpha.md", .created_at = "2026-08-13T15:45:58+09:30", .commit = "ed546ce0186447971ef4e29a21782f4b515e5acc", .markdown = @embedFile("../updates/2026-08-13-lazer-windows-alpha.md") },
        .{ .name = "2026-08-13-lazer-ranked-stats.md", .created_at = "2026-08-13T14:50:04+09:30", .commit = "3da613ae97f7036b734e21cd82200b3e9e772740", .markdown = @embedFile("../updates/2026-08-13-lazer-ranked-stats.md") },
        .{ .name = "2026-08-13-stable-is-finished.md", .created_at = "2026-08-13T07:29:04+09:30", .commit = "d0db0e9f5759ade535209a1f2d3f5eaaeb201f6e", .markdown = @embedFile("../updates/2026-08-13-stable-is-finished.md") },
        .{ .name = "2026-08-13-stable-is-live.md", .created_at = "2026-08-13T05:39:25+09:30", .commit = "70564d1c7c7a14a7442ccd55293176bc5500fbf7", .markdown = @embedFile("../updates/2026-08-13-stable-is-live.md") },
        .{ .name = "2026-08-13-bounded-map-hydration.md", .created_at = "2026-08-13T04:46:02+09:30", .commit = "c499748f4f86bcfcf4cffd3874c1c6ab5559de3b", .markdown = @embedFile("../updates/2026-08-13-bounded-map-hydration.md") },
        .{ .name = "2026-08-13-online-release-preflight.md", .created_at = "2026-08-13T04:33:36+09:30", .commit = "c5f8ab82a261dc240c800513d8cefa2b1c8e7d87", .markdown = @embedFile("../updates/2026-08-13-online-release-preflight.md") },
        .{ .name = "2026-08-13-stable-map-media.md", .created_at = "2026-08-13T04:16:36+09:30", .commit = "a81ab57df435b16e593aeeec7e2da1e1cd867e5d", .markdown = @embedFile("../updates/2026-08-13-stable-map-media.md") },
        .{ .name = "2026-08-13-stable-screenshots.md", .created_at = "2026-08-13T03:36:56+09:30", .commit = "285bfb8ca3211a7e20264ffb728f6f7836bf0e75", .markdown = @embedFile("../updates/2026-08-13-stable-screenshots.md") },
        .{ .name = "2026-08-13-stable-social-state.md", .created_at = "2026-08-13T01:58:29+09:30", .commit = "76dbe6bbecd5daafe5d523bc4aca5fb24dd9a7fa", .markdown = @embedFile("../updates/2026-08-13-stable-social-state.md") },
        .{ .name = "2026-08-13-stable-scoring-and-bn-status.md", .created_at = "2026-08-13T00:55:59+09:30", .commit = "372c3217bf7a2fd891156109147fbf88f58239bd", .markdown = @embedFile("../updates/2026-08-13-stable-scoring-and-bn-status.md") },
        .{ .name = "2026-08-13-stable-backups-and-map-cache.md", .created_at = "2026-08-13T00:17:24+09:30", .commit = "2ad0991afb0ec0211a12e662a54035adc343c4c1", .markdown = @embedFile("../updates/2026-08-13-stable-backups-and-map-cache.md") },
    } },
    .{ .id = 23, .version = "2026.812.0", .created_at = "2026-08-12T23:48:02+09:30", .updates = &.{
        .{ .name = "2026-08-12-weighted-plays-and-mods.md", .created_at = "2026-08-12T23:48:02+09:30", .commit = "4a1fb9eda0127fa6a9d96fbbc57db70c224db305", .markdown = @embedFile("../updates/2026-08-12-weighted-plays-and-mods.md") },
        .{ .name = "2026-08-12-slash-np-and-profile-plays.md", .created_at = "2026-08-12T23:22:40+09:30", .commit = "106dcb4120f754092fa5fdc32dcc50dd07ee34c5", .markdown = @embedFile("../updates/2026-08-12-slash-np-and-profile-plays.md") },
    } },
    .{ .id = 22, .version = "2026.811.0", .created_at = "2026-08-11T19:36:33+09:30", .updates = &.{
        .{ .name = "2026-08-11-stable-staff-and-operations.md", .created_at = "2026-08-11T19:36:33+09:30", .commit = "bcc7aeb12439ffacc7e425a44e6c449df0dcf38d", .markdown = @embedFile("../updates/2026-08-11-stable-staff-and-operations.md") },
        .{ .name = "2026-08-11-split-score-pages.md", .created_at = "2026-08-11T18:01:01+09:30", .commit = "831af913b5d05b540340c9c2913c85bd8a5d75cf", .markdown = @embedFile("../updates/2026-08-11-split-score-pages.md") },
        .{ .name = "2026-08-11-connected-player-pages.md", .created_at = "2026-08-11T16:44:24+09:30", .commit = "db2c6830595694cbc9612005585a9025cfc48117", .markdown = @embedFile("../updates/2026-08-11-connected-player-pages.md") },
        .{ .name = "2026-08-11-stable-map-ranking.md", .created_at = "2026-08-11T16:15:35+09:30", .commit = "64c5c9b571642f3d919aaeddeef9d7c759e38183", .markdown = @embedFile("../updates/2026-08-11-stable-map-ranking.md") },
        .{ .name = "2026-08-11-stable-chat-and-moderation.md", .created_at = "2026-08-11T15:26:08+09:30", .commit = "a532f1d30bc033e81501d1e37ce2311921827b16", .markdown = @embedFile("../updates/2026-08-11-stable-chat-and-moderation.md") },
        .{ .name = "2026-08-11-postgres-runtime-cutover.md", .created_at = "2026-08-11T14:47:37+09:30", .commit = "c309a9e3b2d8928dab87a8b3455be6df60c89f91", .markdown = @embedFile("../updates/2026-08-11-postgres-runtime-cutover.md") },
        .{ .name = "2026-08-11-postgres-migration-foundation.md", .created_at = "2026-08-11T14:09:01+09:30", .commit = "088c5d7338d0a16805d758db953b70316108964c", .markdown = @embedFile("../updates/2026-08-11-postgres-migration-foundation.md") },
        .{ .name = "2026-08-11-stable-hwid-and-kai-colour.md", .created_at = "2026-08-11T13:30:49+09:30", .commit = "9597244b6b3f36ae99ae4529909d8ae75dc458c5", .markdown = @embedFile("../updates/2026-08-11-stable-hwid-and-kai-colour.md") },
        .{ .name = "2026-08-11-stable-lobby-channels.md", .created_at = "2026-08-11T12:49:52+09:30", .commit = "75af8e7568e3cb6ec5a695e1da108d96b3cacb40", .markdown = @embedFile("../updates/2026-08-11-stable-lobby-channels.md") },
        .{ .name = "2026-08-11-stable-spectating.md", .created_at = "2026-08-11T12:24:40+09:30", .commit = "43c69196eecca0af5ed981457a316afc68c18e26", .markdown = @embedFile("../updates/2026-08-11-stable-spectating.md") },
        .{ .name = "2026-08-11-stable-referees-and-abort.md", .created_at = "2026-08-11T11:59:19+09:30", .commit = "27bf6ed9913768b9b3a8d8952f9b63243d7aa06f", .markdown = @embedFile("../updates/2026-08-11-stable-referees-and-abort.md") },
        .{ .name = "2026-08-11-stable-invites-and-tourney.md", .created_at = "2026-08-11T11:43:19+09:30", .commit = "7093a8611885467b4159e1d1685548bff50eb403", .markdown = @embedFile("../updates/2026-08-11-stable-invites-and-tourney.md") },
        .{ .name = "2026-08-11-stable-match-play.md", .created_at = "2026-08-11T11:26:17+09:30", .commit = "2afe0d68c99bd041fef19d3773132d255960054b", .markdown = @embedFile("../updates/2026-08-11-stable-match-play.md") },
        .{ .name = "2026-08-11-stable-registration-check.md", .created_at = "2026-08-11T11:03:22+09:30", .commit = "36ae6042c551bf8aa3f9508686d769b2eb5152fa", .markdown = @embedFile("../updates/2026-08-11-stable-registration-check.md") },
        .{ .name = "2026-08-11-stable-multiplayer-rooms.md", .created_at = "2026-08-11T10:51:20+09:30", .commit = "2fba854fc1e1d3de9f0c7fbedcf7c379596f81d4", .markdown = @embedFile("../updates/2026-08-11-stable-multiplayer-rooms.md") },
        .{ .name = "2026-08-11-hostile-score-input.md", .created_at = "2026-08-11T10:25:03+09:30", .commit = "2237d5426f38c73abda52bf8ab8a88b91658b5b9", .markdown = @embedFile("../updates/2026-08-11-hostile-score-input.md") },
        .{ .name = "2026-08-11-auth-locks-and-score-tokens.md", .created_at = "2026-08-11T10:05:55+09:30", .commit = "469461b82da22261239dff07c14d18f06a0e460f", .markdown = @embedFile("../updates/2026-08-11-auth-locks-and-score-tokens.md") },
        .{ .name = "2026-08-11-session-cleanup.md", .created_at = "2026-08-11T09:39:27+09:30", .commit = "e7c2382deb8bc713090e881706af9fad7204bdd1", .markdown = @embedFile("../updates/2026-08-11-session-cleanup.md") },
        .{ .name = "2026-08-11-p0-lifetime-fixes.md", .created_at = "2026-08-11T09:26:32+09:30", .commit = "14583014581fb9ed4103b24a81d61c66f9ceeeee", .markdown = @embedFile("../updates/2026-08-11-p0-lifetime-fixes.md") },
        .{ .name = "2026-08-11-old-map-hydration.md", .created_at = "2026-08-11T06:57:18+09:30", .commit = "6b9d07ca2a6a28f837920615b347ead3f16d177f", .markdown = @embedFile("../updates/2026-08-11-old-map-hydration.md") },
        .{ .name = "2026-08-11-akatsuki-pp-and-recalc.md", .created_at = "2026-08-11T00:03:24+09:30", .commit = "931907e50a33204ab566be4e6e5fd8c9d6dfa39e", .markdown = @embedFile("../updates/2026-08-11-akatsuki-pp-and-recalc.md") },
    } },
    .{ .id = 21, .version = "2026.810.0", .created_at = "2026-08-10T06:33:02+09:30", .updates = &.{
        .{ .name = "2026-08-10-relax-autopilot-pp-leaderboard.md", .created_at = "2026-08-10T06:33:02+09:30", .commit = "ce944ce389c0f017ca674195a90cd887d4c93562", .markdown = @embedFile("../updates/2026-08-10-relax-autopilot-pp-leaderboard.md") },
        .{ .name = "2026-08-10-async-score-submit.md", .created_at = "2026-08-10T05:45:49+09:30", .commit = "c4e7f47619643678746a6541255afdd0a9ecbe6e", .markdown = @embedFile("../updates/2026-08-10-async-score-submit.md") },
        .{ .name = "2026-08-10-instant-maps.md", .created_at = "2026-08-10T03:50:57+09:30", .commit = "4ef5c1d666806649ee5d914fdac7984655796655", .markdown = @embedFile("../updates/2026-08-10-instant-maps.md") },
        .{ .name = "2026-08-10-mirror-and-webhook-fixes.md", .created_at = "2026-08-10T03:39:58+09:30", .commit = "96a3566a3496820e8193a31299f26d86db550c81", .markdown = @embedFile("../updates/2026-08-10-mirror-and-webhook-fixes.md") },
        .{ .name = "2026-08-10-bot-commands.md", .created_at = "2026-08-10T03:39:58+09:30", .commit = "96a3566a3496820e8193a31299f26d86db550c81", .markdown = @embedFile("../updates/2026-08-10-bot-commands.md") },
        .{ .name = "2026-08-10-async-hydration.md", .created_at = "2026-08-10T03:39:58+09:30", .commit = "96a3566a3496820e8193a31299f26d86db550c81", .markdown = @embedFile("../updates/2026-08-10-async-hydration.md") },
    } },
    .{ .id = 20, .version = "2026.809.0", .created_at = "2026-08-09T20:16:04+09:30", .updates = &.{
        .{ .name = "2026-08-09-webhook-details.md", .created_at = "2026-08-09T20:16:04+09:30", .commit = "44102190c65ea83a120d78613c23c90980b1b5e3", .markdown = @embedFile("../updates/2026-08-09-webhook-details.md") },
        .{ .name = "2026-08-09-mirror-swap.md", .created_at = "2026-08-09T19:25:46+09:30", .commit = "dbc319cb359bf9d0d3b2b77f8d3651a9a24ee1f6", .markdown = @embedFile("../updates/2026-08-09-mirror-swap.md") },
        .{ .name = "2026-08-09-score-checksum-username.md", .created_at = "2026-08-09T18:02:28+09:30", .commit = "d25d303c57fcbe71daac94d4f98f39d271a517b6", .markdown = @embedFile("../updates/2026-08-09-score-checksum-username.md") },
        .{ .name = "2026-08-09-leaderboard-timestamp.md", .created_at = "2026-08-09T18:02:28+09:30", .commit = "d25d303c57fcbe71daac94d4f98f39d271a517b6", .markdown = @embedFile("../updates/2026-08-09-leaderboard-timestamp.md") },
        .{ .name = "2026-08-09-default-anime-avatars.md", .created_at = "2026-08-09T14:06:51+09:30", .commit = "8d325d478e8f6b43d64b793085e6fcbe2b6aaecb", .markdown = @embedFile("../updates/2026-08-09-default-anime-avatars.md") },
        .{ .name = "2026-08-09-chat-countries-and-kai.md", .created_at = "2026-08-09T13:50:56+09:30", .commit = "9b3abdb68ccbb1febc4abc6d75e4060ea020d6f9", .markdown = @embedFile("../updates/2026-08-09-chat-countries-and-kai.md") },
        .{ .name = "2026-08-09-remove-stale-handoff.md", .created_at = "2026-08-09T12:47:47+09:30", .commit = "df469e7ca1ad4c20f69598ef9beffe0ce42452d5", .markdown = @embedFile("../updates/2026-08-09-remove-stale-handoff.md") },
        .{ .name = "2026-08-09-empty-failed-replays.md", .created_at = "2026-08-09T12:46:16+09:30", .commit = "d3f69b68bc5f609486c198365b681ac77d154bc1", .markdown = @embedFile("../updates/2026-08-09-empty-failed-replays.md") },
        .{ .name = "2026-08-09-score-rejection-logs.md", .created_at = "2026-08-09T12:04:54+09:30", .commit = "7643094627be3fc029ce0986ddfcd9cbdbe65d9d", .markdown = @embedFile("../updates/2026-08-09-score-rejection-logs.md") },
        .{ .name = "2026-08-09-clean-pause.md", .created_at = "2026-08-09T11:59:51+09:30", .commit = "8c1653c51c0d47b8981d477b4d22dd2b2801d213", .markdown = @embedFile("../updates/2026-08-09-clean-pause.md") },
        .{ .name = "2026-08-09-stable-maps-and-chat.md", .created_at = "2026-08-09T11:56:33+09:30", .commit = "49ab8d9fd05ac0dabc7381cbde8dd2b26bf0af9b", .markdown = @embedFile("../updates/2026-08-09-stable-maps-and-chat.md") },
        .{ .name = "2026-08-09-real-client-registration.md", .created_at = "2026-08-09T11:26:44+09:30", .commit = "301ec6fc70cf920d0811522c9ef42e32f8034fde", .markdown = @embedFile("../updates/2026-08-09-real-client-registration.md") },
        .{ .name = "2026-08-09-real-lazer-multipart.md", .created_at = "2026-08-09T11:17:56+09:30", .commit = "47646c888c70fb1c144013c79431cd70237bbb19", .markdown = @embedFile("../updates/2026-08-09-real-lazer-multipart.md") },
        .{ .name = "2026-08-09-lazer-password-edge.md", .created_at = "2026-08-09T11:07:05+09:30", .commit = "00394bf94df1438906da7942ba8ee7500c92fd99", .markdown = @embedFile("../updates/2026-08-09-lazer-password-edge.md") },
        .{ .name = "2026-08-09-real-lazer-account-contract.md", .created_at = "2026-08-09T10:53:29+09:30", .commit = "0f0fe142ab72c90ef6e698ee69057c0f0c619e43", .markdown = @embedFile("../updates/2026-08-09-real-lazer-account-contract.md") },
        .{ .name = "2026-08-09-discovery-downloads-and-hosts.md", .created_at = "2026-08-09T10:14:45+09:30", .commit = "793809dcfc7fba500abbd27f3a73277652fe1531", .markdown = @embedFile("../updates/2026-08-09-discovery-downloads-and-hosts.md") },
        .{ .name = "2026-08-09-linux-release-build.md", .created_at = "2026-08-09T09:43:12+09:30", .commit = "662c1f9664a1904f04e1bd3d012b4888108332f5", .markdown = @embedFile("../updates/2026-08-09-linux-release-build.md") },
        .{ .name = "2026-08-09-beatmaps-and-pp.md", .created_at = "2026-08-09T09:32:46+09:30", .commit = "f882d06dfda02bb72706a221c149914f51b49245", .markdown = @embedFile("../updates/2026-08-09-beatmaps-and-pp.md") },
    } },
};

pub fn historyEntryCount() usize {
    var count: usize = 0;
    for (fallback_builds) |build| count += build.updates.len;
    return count;
}

pub fn historyManifest() u64 {
    var manifest: u64 = 0;
    for (fallback_builds) |build| for (build.updates) |update| {
        manifest ^= std.hash.Wyhash.hash(0, update.name);
    };
    return manifest;
}

fn contains(value: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, value, needle) != null;
}

fn title(markdown: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, markdown, '\n') orelse markdown.len;
    return std.mem.trim(u8, markdown[0..line_end], "#* \t\r");
}

fn message(markdown: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, markdown, '\n') orelse return "";
    return std.mem.trim(u8, markdown[line_end + 1 ..], " \t\r\n");
}

fn preview(markdown: []const u8) []const u8 {
    const body = message(markdown);
    const paragraph_end = std.mem.indexOf(u8, body, "\n\n") orelse body.len;
    return std.mem.trim(u8, body[0..paragraph_end], " \t\r\n");
}

fn slug(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".md")) name[0 .. name.len - 3] else name;
}

fn updateYear(update: Update) u16 {
    if (update.created_at.len < 4) return 0;
    return std.fmt.parseInt(u16, update.created_at[0..4], 10) catch 0;
}

fn buildYear(build: Build) u16 {
    if (build.created_at.len < 4) return 0;
    return std.fmt.parseInt(u16, build.created_at[0..4], 10) catch 0;
}

fn category(name: []const u8) []const u8 {
    if (contains(name, "lazer")) return "lazer";
    if (contains(name, "stable")) return "stable";
    if (contains(name, "beatmap") or contains(name, "map-") or contains(name, "mirror")) return "beatmaps";
    if (contains(name, "score") or contains(name, "pp") or contains(name, "replay")) return "scores";
    if (contains(name, "chat") or contains(name, "bot")) return "chat";
    if (contains(name, "account") or contains(name, "avatar") or contains(name, "profile") or contains(name, "player-page")) return "profiles";
    if (contains(name, "auth") or contains(name, "session") or contains(name, "postgres")) return "server";
    return "zigcho";
}

fn kind(name: []const u8) []const u8 {
    if (contains(name, "fix") or contains(name, "rejection") or contains(name, "empty") or contains(name, "cleanup") or contains(name, "bounded") or contains(name, "remove")) return "fix";
    return "add";
}

fn major(name: []const u8) bool {
    return contains(name, "is-live") or contains(name, "is-finished") or contains(name, "cutover") or contains(name, "windows-alpha") or contains(name, "postgres-runtime");
}

fn entryId(build_id: i64, index: usize) !i64 {
    if (build_id <= 0 or build_id > max_build_id or index >= max_updates) return error.InvalidChangelogEntryId;
    const scaled = std.math.mul(i64, build_id, 100) catch return error.InvalidChangelogEntryId;
    return std.math.add(i64, scaled, @intCast(index)) catch return error.InvalidChangelogEntryId;
}

fn writeStream(writer: *std.Io.Writer, catalog: []const Build, include_latest: bool) anyerror!void {
    try writer.writeAll("{\"id\":5,\"name\":\"lazer\",\"is_featured\":true,\"display_name\":\"zigcho!lazer\",\"user_count\":0,\"latest_build\":");
    if (include_latest) try writeBuild(writer, catalog, 0, false, false) else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn writeEntry(writer: *std.Io.Writer, build: Build, update: Update, index: usize) anyerror!void {
    var commit_url_buf: [128]u8 = undefined;
    const commit_url = if (update.commit.len == 0) "https://github.com/raya-ac/zigcho" else try std.fmt.bufPrint(&commit_url_buf, "https://github.com/raya-ac/zigcho/commit/{s}", .{update.commit});
    try writer.print("{{\"id\":{d},\"repository\":\"raya-ac/zigcho\",\"github_pull_request_id\":null,\"github_url\":null,\"url\":", .{try entryId(build.id, index)});
    try std.json.Stringify.value(commit_url, .{}, writer);
    try writer.writeAll(",\"type\":");
    try std.json.Stringify.value(kind(update.name), .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(category(update.name), .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title(update.markdown), .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message(update.markdown), .{}, writer);
    try writer.writeAll(",\"message_html\":");
    try std.json.Stringify.value(message(update.markdown), .{}, writer);
    try writer.print(",\"major\":{},\"created_at\":", .{major(update.name)});
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"github_user\":null}");
}

fn writeBuild(writer: *std.Io.Writer, catalog: []const Build, index: usize, detailed: bool, navigation: bool) anyerror!void {
    const build = catalog[index];
    try writer.print("{{\"id\":{d},\"version\":", .{build.id});
    try std.json.Stringify.value(build.version, .{}, writer);
    try writer.writeAll(",\"display_version\":");
    if (build.display_version) |display_version|
        try std.json.Stringify.value(display_version, .{}, writer)
    else
        try writer.print("\"zigcho!lazer {s}\"", .{build.version});
    try writer.writeAll(",\"users\":0,\"created_at\":");
    try std.json.Stringify.value(build.created_at, .{}, writer);
    try writer.writeAll(",\"update_stream\":");
    try writeStream(writer, catalog, false);
    try writer.writeAll(",\"changelog_entries\":[");
    if (detailed) for (build.updates, 0..) |update, update_index| {
        if (update_index != 0) try writer.writeByte(',');
        try writeEntry(writer, build, update, update_index);
    };
    try writer.writeAll("],\"versions\":");
    if (!navigation) {
        try writer.writeAll("null}");
        return;
    }
    try writer.writeAll("{\"next\":");
    if (index > 0) try writeBuild(writer, catalog, index - 1, false, false) else try writer.writeAll("null");
    try writer.writeAll(",\"previous\":");
    if (index + 1 < catalog.len) try writeBuild(writer, catalog, index + 1, false, false) else try writer.writeAll("null");
    try writer.writeAll("}}");
}

pub fn indexJsonFor(allocator: std.mem.Allocator, catalog: []const Build) ![]u8 {
    if (catalog.len == 0) return error.EmptyChangelog;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"streams\":[");
    try writeStream(&output.writer, catalog, true);
    try output.writer.writeAll("],\"builds\":[");
    for (catalog, 0..) |_, index| {
        if (index != 0) try output.writer.writeByte(',');
        try writeBuild(&output.writer, catalog, index, true, false);
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn indexJson(allocator: std.mem.Allocator) ![]u8 {
    return indexJsonFor(allocator, &fallback_builds);
}

pub fn buildJsonFor(allocator: std.mem.Allocator, catalog: []const Build, stream: []const u8, version: []const u8) !?[]u8 {
    if (!std.mem.eql(u8, stream, "lazer") and !std.mem.eql(u8, stream, "zigcho")) return null;
    for (catalog, 0..) |build, index| if (std.mem.eql(u8, build.version, version) or (index == 0 and std.mem.eql(u8, version, "latest"))) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try writeBuild(&output.writer, catalog, index, true, true);
        return @as(?[]u8, try output.toOwnedSlice());
    };
    return null;
}

pub fn buildJson(allocator: std.mem.Allocator, stream: []const u8, version: []const u8) !?[]u8 {
    return buildJsonFor(allocator, &fallback_builds, stream, version);
}

fn writeNewsPost(writer: *std.Io.Writer, build: Build, update: Update, index: usize) !void {
    var edit_url_buf: [128]u8 = undefined;
    const edit_url = if (update.commit.len == 0) "https://github.com/raya-ac/zigcho" else try std.fmt.bufPrint(&edit_url_buf, "https://github.com/raya-ac/zigcho/commit/{s}", .{update.commit});
    try writer.print("{{\"id\":{d},\"author\":\"ari\",\"edit_url\":", .{try entryId(build.id, index)});
    try std.json.Stringify.value(edit_url, .{}, writer);
    try writer.writeAll(",\"first_image\":\"\",\"published_at\":");
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(update.created_at, .{}, writer);
    try writer.writeAll(",\"slug\":");
    try std.json.Stringify.value(slug(update.name), .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title(update.markdown), .{}, writer);
    try writer.writeAll(",\"preview\":");
    try std.json.Stringify.value(preview(update.markdown), .{}, writer);
    try writer.writeByte('}');
}

pub fn newsSlugKnownFor(catalog: []const Build, value: []const u8) bool {
    for (catalog) |build| for (build.updates) |update| {
        if (std.mem.eql(u8, slug(update.name), value)) return true;
    };
    return false;
}

pub fn newsSlugKnown(value: []const u8) bool {
    return newsSlugKnownFor(&fallback_builds, value);
}

pub fn newsJsonFor(allocator: std.mem.Allocator, catalog: []const Build, selected_year: ?u16) ![]u8 {
    if (catalog.len == 0) return error.EmptyChangelog;
    var years: std.ArrayList(u16) = .empty;
    defer years.deinit(allocator);
    for (catalog) |build| {
        const candidate = buildYear(build);
        if (candidate == 0) continue;
        var known = false;
        for (years.items) |existing| if (existing == candidate) {
            known = true;
            break;
        };
        if (!known) try years.append(allocator, candidate);
    }
    std.mem.sort(u16, years.items, {}, struct {
        fn before(_: void, left: u16, right: u16) bool {
            return left > right;
        }
    }.before);
    if (years.items.len == 0) return error.InvalidChangelogTimestamp;
    const year = selected_year orelse buildYear(catalog[0]);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"news_posts\":[");
    var written: usize = 0;
    outer: for (catalog) |build| for (build.updates, 0..) |update, index| {
        if (updateYear(update) != year) continue;
        if (written == 12) break :outer;
        if (written != 0) try output.writer.writeByte(',');
        try writeNewsPost(&output.writer, build, update, index);
        written += 1;
    };
    try output.writer.print("],\"news_sidebar\":{{\"current_year\":{d},\"news_posts\":[", .{year});
    written = 0;
    sidebar: for (catalog) |build| for (build.updates, 0..) |update, index| {
        if (written == 5) break :sidebar;
        if (written != 0) try output.writer.writeByte(',');
        try writeNewsPost(&output.writer, build, update, index);
        written += 1;
    };
    try output.writer.writeAll("],\"years\":[");
    for (years.items, 0..) |available, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{available});
    }
    try output.writer.writeAll("]},\"cursor\":null}");
    return output.toOwnedSlice();
}

pub fn newsJson(allocator: std.mem.Allocator, selected_year: ?u16) ![]u8 {
    return newsJsonFor(allocator, &fallback_builds, selected_year);
}

test "changelog exposes the complete checked in release history" {
    const json = try indexJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("zigcho!lazer", object.get("streams").?.array.items[0].object.get("display_name").?.string);
    try std.testing.expectEqualStrings(latest_version, object.get("builds").?.array.items[0].object.get("version").?.string);
    try std.testing.expectEqual(@as(usize, 21), object.get("builds").?.array.items.len);
    var entries: usize = 0;
    for (object.get("builds").?.array.items) |build| entries += build.object.get("changelog_entries").?.array.items.len;
    try std.testing.expectEqual(historyEntryCount(), entries);
    try std.testing.expectEqualStrings("zigcho release 1.9", object.get("builds").?.array.items[0].object.get("changelog_entries").?.array.items[0].object.get("title").?.string);

    const latest = (try buildJson(std.testing.allocator, "lazer", "latest")).?;
    defer std.testing.allocator.free(latest);
    const parsed_latest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, latest, .{});
    defer parsed_latest.deinit();
    try std.testing.expectEqualStrings("2026.830.1", parsed_latest.value.object.get("versions").?.object.get("previous").?.object.get("version").?.string);

    const oldest = (try buildJson(std.testing.allocator, "zigcho", "2026.809.0")).?;
    defer std.testing.allocator.free(oldest);
    const parsed_oldest = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, oldest, .{});
    defer parsed_oldest.deinit();
    try std.testing.expectEqual(@as(usize, 18), parsed_oldest.value.object.get("changelog_entries").?.array.items.len);
    try std.testing.expectEqualStrings("2026.810.0", parsed_oldest.value.object.get("versions").?.object.get("next").?.object.get("version").?.string);
    try std.testing.expect(parsed_oldest.value.object.get("versions").?.object.get("previous").? == .null);
    try std.testing.expect((try buildJson(std.testing.allocator, "stable", latest_version)) == null);
}

test "news is backed by the checked in zigcho updates" {
    const json = try newsJson(std.testing.allocator, null);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const posts = parsed.value.object.get("news_posts").?.array.items;
    try std.testing.expectEqual(@as(usize, 12), posts.len);
    try std.testing.expectEqualStrings("ari", posts[0].object.get("author").?.string);
    try std.testing.expect(posts[0].object.get("title").?.string.len > 0);
    try std.testing.expect(posts[0].object.get("preview").?.string.len > 0);
    try std.testing.expect(newsSlugKnown(posts[0].object.get("slug").?.string));
    try std.testing.expectEqual(@as(i64, 2026), parsed.value.object.get("news_sidebar").?.object.get("current_year").?.integer);
    try std.testing.expectEqual(@as(i64, 2026), parsed.value.object.get("news_sidebar").?.object.get("years").?.array.items[0].integer);

    const old = try newsJson(std.testing.allocator, 2025);
    defer std.testing.allocator.free(old);
    const parsed_old = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, old, .{});
    defer parsed_old.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_old.value.object.get("news_posts").?.array.items.len);
}
