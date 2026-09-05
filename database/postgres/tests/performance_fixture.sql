-- Only used in the dedicated disposable performance-parity test database.
BEGIN;
INSERT INTO zigcho.users(id,name,safe_name,password_hash,password_salt,country,restricted)
SELECT 810000+n,'perf '||n,'perf_'||n,decode('00','hex'),decode('00','hex'),
       CASE WHEN n=2 THEN 'CA' ELSE 'AU' END,n=3
FROM generate_series(1,4) n;
INSERT INTO zigcho.stats(user_id,mode,ranked_score,total_score,pp,plays,accuracy)
SELECT 810000+n,m,1234567890123,2345678901234,
       CASE WHEN n=3 THEN 900000 ELSE 500000 END+m,
       CASE WHEN n=4 THEN 0 ELSE 10 END,0.9375
FROM generate_series(1,4) n CROSS JOIN unnest(ARRAY[0,1,2,3,4,5,6,8]) m;
UPDATE zigcho.stats SET pp=1000000,plays=2 WHERE user_id=3;
INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,star_rating)
SELECT 880000+n,880000+n,md5('perf-map-'||n),'artist','title','version','mapper',
       CASE WHEN n=48 THEN 2 WHEN n=47 THEN 4 ELSE 3 END,3.5
FROM generate_series(0,48) n;
INSERT INTO zigcho.scores(id,user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,best,rank_namespace,submitted_at,replay,star_rating)
SELECT 5000000+k*10000+n*10+u,810000+least(u,4),md5('perf-map-'||n),0,8,
       CASE u WHEN 1 THEN 1000 WHEN 2 THEN CASE WHEN n%7=0 THEN 1000 ELSE 900 END WHEN 5 THEN 6000 ELSE 5000 END,
       CASE u WHEN 1 THEN 100 ELSE 150 END,0.95,10,10,0,0,0,0,0,false,u!=4,u<4,
       ns,1000+n%2,CASE WHEN n%2=1 THEN decode('00','hex') END,0
FROM generate_series(0,48) n CROSS JOIN generate_series(1,5) u
CROSS JOIN (VALUES(0,'vanilla'),(1,'relax'),(2,'autopilot'),(3,'scorev2')) namespaces(k,ns);
INSERT INTO zigcho.lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,pp,best,rank_namespace,submitted_at)
SELECT 5000001+k*10000+n*10,810001,880000+n,0,
       CASE WHEN n%3=0 THEN 800 ELSE 5000 END,700,
       CASE WHEN n%4=0 THEN NULL ELSE 123 END,0.97,11,true,'S',
       '[{"acronym":"HD"}]'::jsonb,'{}'::jsonb,
       CASE n%3 WHEN 0 THEN 200 WHEN 1 THEN 100 ELSE 50 END,true,ns,1000+n%2
FROM generate_series(0,48) n
CROSS JOIN (VALUES(0,'vanilla'),(1,'relax'),(2,'autopilot'),(3,'scorev2')) namespaces(k,ns);
INSERT INTO zigcho.replay_objects(source,score_id,object_key,etag,object_bytes)
VALUES('stable',5000001,'fixture-stable-replay',repeat('c',64),7),
      ('lazer',5000001,'fixture-lazer-replay',repeat('d',64),7);
INSERT INTO zigcho.lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,pp,best,rank_namespace,submitted_at)
SELECT 5000000+k*10000+n*10,810002,880000+n,0,1000,750,456,0.96,12,true,'S',
       '[{"acronym":"DT","settings":{"speed_change":1.2}}]'::jsonb,'{}'::jsonb,300,true,ns,1000+n%2
FROM generate_series(0,48) n
CROSS JOIN (VALUES(0,'vanilla'),(1,'relax'),(2,'autopilot'),(3,'scorev2')) namespaces(k,ns)
WHERE n%3=1;
COMMIT;
