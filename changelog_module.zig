const history = @import("src/changelog.zig");
const options = @import("changelog_options");

pub const latest_version = history.latest_version;
pub const indexJson = history.indexJson;
pub const buildJson = history.buildJson;
pub const historyEntryCount = history.historyEntryCount;
pub const historyManifest = history.historyManifest;
pub const expected_update_count = options.update_count;
pub const expected_update_manifest = options.update_manifest;

test {
    _ = history;
}
