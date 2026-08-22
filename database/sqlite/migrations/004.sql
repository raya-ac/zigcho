ALTER TABLE scores ADD COLUMN rank_namespace TEXT NOT NULL DEFAULT 'vanilla';
ALTER TABLE scores ADD COLUMN best INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS scores_stable_board ON scores(map_md5,mode,rank_namespace,best,score DESC);
PRAGMA user_version=4;
