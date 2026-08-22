BEGIN;

CREATE TABLE IF NOT EXISTS lazer_comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    commentable_type TEXT NOT NULL CHECK(commentable_type IN ('beatmapset','build','news_post')),
    commentable_id INTEGER NOT NULL CHECK(commentable_id > 0),
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    parent_id INTEGER REFERENCES lazer_comments(id) ON DELETE CASCADE,
    message TEXT NOT NULL CHECK(length(message) BETWEEN 0 AND 1000),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    deleted_at INTEGER,
    CHECK(parent_id IS NULL OR parent_id != id)
);
CREATE INDEX IF NOT EXISTS lazer_comments_target ON lazer_comments(commentable_type,commentable_id,parent_id,created_at,id);
CREATE TABLE IF NOT EXISTS lazer_comment_votes (
    comment_id INTEGER NOT NULL REFERENCES lazer_comments(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(comment_id,user_id)
);
CREATE TABLE IF NOT EXISTS lazer_comment_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    comment_id INTEGER NOT NULL REFERENCES lazer_comments(id) ON DELETE CASCADE,
    reporter_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 64),
    comments TEXT NOT NULL CHECK(length(comments) <= 1000),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE UNIQUE INDEX IF NOT EXISTS lazer_comment_reports_once ON lazer_comment_reports(comment_id,reporter_id);

PRAGMA user_version=32;
COMMIT;
