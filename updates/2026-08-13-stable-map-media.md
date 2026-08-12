# maps have their art and previews now

the empty map pages are gone. known mapsets now have covers, thumbnails, and song previews under our own hosts, and the website actually uses them. Stable's old `/thumb` and `/preview` paths work from the same cache too.

I did not make this an open proxy. the server only fetches media for a mapset already in our database, only asks the fixed osu asset hosts, checks the bytes instead of trusting the file extension, and caps upstream work at four fetches at once. the files live in PostgreSQL with a 512 MiB default ceiling, LRU pruning, and local metrics for misses, failures, size, and evictions.

schema 19 and the importer carry the cached bytes properly. Debug and ReleaseSafe pass, all 115 tests pass against fresh real PostgreSQL databases, the 18 to 19 upgrade passes, and the 23-table importer matched every count and stored byte before refusing a repeat import. I also pulled a real preview through the HTTP route, got Ogg audio back from the `.mp3` Stable path, then proved the second request was a database hit.

this closes the missing map-media part of Stable. I am still keeping the rest of the Stable gate honest: the final installed-client run and the production restart, restore, rollback, load, and soak checks are separate work, not hidden behind this update.
