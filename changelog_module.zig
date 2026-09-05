const history = @import("src/changelog.zig");
const feed = @import("src/changelog_feed.zig");
const options = @import("changelog_options");

pub const checked_in_manifest = @embedFile("updates/changelog.json");

pub const latest_version = history.latest_version;
pub const indexJson = history.indexJson;
pub const buildJson = history.buildJson;
pub const historyEntryCount = history.historyEntryCount;
pub const historyManifest = history.historyManifest;
pub const newsSlugKnown = history.newsSlugKnown;
pub const newsJson = history.newsJson;
pub const Feed = feed.Feed;
pub const Fetcher = feed.Fetcher;
pub const refresh_seconds = feed.refresh_seconds;
pub const expected_update_count = options.update_count;
pub const expected_update_manifest = options.update_manifest;

test {
    _ = history;
    _ = feed;
}
