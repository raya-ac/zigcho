BEGIN IMMEDIATE;

ALTER TABLE users ADD COLUMN username_changes INTEGER NOT NULL DEFAULT 0 CHECK(username_changes>=0);
ALTER TABLE users ADD COLUMN username_changed_at INTEGER;

CREATE TABLE user_name_changes(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    old_name TEXT NOT NULL,
    new_name TEXT NOT NULL,
    changed_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX user_name_changes_user_time ON user_name_changes(user_id,changed_at DESC,id DESC);

CREATE TABLE user_banners(
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL UNIQUE CHECK(length(object_key) BETWEEN 1 AND 200),
    content_type TEXT NOT NULL CHECK(content_type IN('image/png','image/jpeg','image/gif')),
    etag TEXT NOT NULL CHECK(length(etag)=64),
    width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 2000),
    height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 500),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE teams(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 40),
    short_name TEXT NOT NULL CHECK(length(short_name) BETWEEN 1 AND 4),
    url TEXT NOT NULL DEFAULT '' CHECK(length(url)<=255),
    description TEXT NOT NULL DEFAULT '' CHECK(length(description)<=64000),
    is_open INTEGER NOT NULL DEFAULT 1 CHECK(is_open IN(0,1)),
    default_ruleset_id INTEGER NOT NULL DEFAULT 0 CHECK(default_ruleset_id BETWEEN 0 AND 3),
    leader_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE UNIQUE INDEX teams_name_unique ON teams(lower(name));
CREATE UNIQUE INDEX teams_short_name_unique ON teams(lower(short_name));

CREATE TABLE team_members(
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    joined_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX team_members_team_time ON team_members(team_id,joined_at,user_id);

CREATE TABLE team_applications(
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX team_applications_team_time ON team_applications(team_id,created_at,user_id);

CREATE TABLE team_assets(
    team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN('flag','header')),
    object_key TEXT NOT NULL UNIQUE CHECK(length(object_key) BETWEEN 1 AND 200),
    content_type TEXT NOT NULL CHECK(content_type IN('image/png','image/jpeg','image/gif')),
    etag TEXT NOT NULL CHECK(length(etag)=64),
    width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 2000),
    height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 500),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(team_id,kind)
);

CREATE TABLE lazer_presence(
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT '' CHECK(length(status)<=80),
    detail TEXT NOT NULL DEFAULT '' CHECK(length(detail)<=200),
    beatmap_id INTEGER,
    ruleset_id INTEGER CHECK(ruleset_id IS NULL OR ruleset_id BETWEEN 0 AND 3),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE replay_objects(
    source TEXT NOT NULL CHECK(source IN('stable','lazer')),
    score_id INTEGER NOT NULL CHECK(score_id>0),
    object_key TEXT NOT NULL UNIQUE CHECK(length(object_key) BETWEEN 1 AND 200),
    etag TEXT NOT NULL CHECK(length(etag)=64),
    object_bytes INTEGER NOT NULL CHECK(object_bytes>0),
    stored_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(source,score_id)
);

CREATE TABLE lazer_reports(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reporter_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reportable_type TEXT NOT NULL CHECK(reportable_type IN('user','message','comment')),
    reportable_id INTEGER NOT NULL CHECK(reportable_id>0),
    reason TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 64),
    comments TEXT NOT NULL DEFAULT '' CHECK(length(comments)<=1000),
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','resolved','dismissed')),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    resolved_at INTEGER,
    resolver_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    UNIQUE(reporter_id,reportable_type,reportable_id)
);
CREATE INDEX lazer_reports_status_time ON lazer_reports(status,created_at,id);

CREATE TABLE beatmap_tag_votes(
    beatmap_id INTEGER NOT NULL REFERENCES beatmaps(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL CHECK(tag_id BETWEEN 1 AND 16),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(beatmap_id,user_id,tag_id)
);
CREATE INDEX beatmap_tag_votes_map_tag ON beatmap_tag_votes(beatmap_id,tag_id,created_at);

CREATE TABLE profile_score_pins(
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source TEXT NOT NULL CHECK(source IN('stable','lazer')),
    score_id INTEGER NOT NULL CHECK(score_id>0),
    mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 3),
    rank_namespace TEXT NOT NULL CHECK(rank_namespace IN('vanilla','relax','autopilot','scorev2','custom')),
    pinned_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id,source,score_id),
    UNIQUE(source,score_id)
);
CREATE INDEX profile_score_pins_user_mode ON profile_score_pins(user_id,mode,rank_namespace,pinned_at DESC,score_id DESC);
INSERT INTO profile_score_pins(user_id,source,score_id,mode,rank_namespace,pinned_at)
SELECT p.user_id,'stable',p.score_id,s.mode,s.rank_namespace,p.pinned_at FROM score_pins p JOIN scores s ON s.id=p.score_id;

PRAGMA user_version=33;
COMMIT;
