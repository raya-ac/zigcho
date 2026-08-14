BEGIN IMMEDIATE;

ALTER TABLE users ADD COLUMN profile_title TEXT NOT NULL DEFAULT '' CHECK(length(profile_title) <= 40);
ALTER TABLE users ADD COLUMN profile_pronouns TEXT NOT NULL DEFAULT '' CHECK(length(profile_pronouns) <= 32);
ALTER TABLE users ADD COLUMN profile_location TEXT NOT NULL DEFAULT '' CHECK(length(profile_location) <= 60);
ALTER TABLE users ADD COLUMN profile_website TEXT NOT NULL DEFAULT '' CHECK(length(profile_website) <= 200);
ALTER TABLE users ADD COLUMN profile_accent TEXT NOT NULL DEFAULT 'pink' CHECK(profile_accent IN ('pink','violet','blue','mint','gold','red'));
ALTER TABLE users ADD COLUMN show_country INTEGER NOT NULL DEFAULT 1 CHECK(show_country IN (0,1));
ALTER TABLE users ADD COLUMN show_profile_stats INTEGER NOT NULL DEFAULT 1 CHECK(show_profile_stats IN (0,1));
ALTER TABLE users ADD COLUMN show_recent_scores INTEGER NOT NULL DEFAULT 1 CHECK(show_recent_scores IN (0,1));

COMMIT;
PRAGMA user_version=24;
