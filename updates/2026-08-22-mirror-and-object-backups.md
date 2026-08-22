# the beatmap mirror has somewhere real to grow now

`beatmaps.kai.ovh` is the actual mirror instead of another name pointed at the generic status file. opening a missing set fetches the whole archive, checks every difficulty against the set metadata, stores the full set in PostgreSQL and puts the verified `.osz` in Contabo. known sets are also filled quietly in the background, so it is building a library before somebody asks for each one.

the mirror page shows how many sets are stored, their real object size, the known queue, traffic and failures against the 1.5 TB store. the rest of the osu-facing hosts have their own small service pages now too, while kai.ovh stays the actual player site.

database backups no longer sit on the VPS forever. each dump is still restore-tested first, then uploaded to the private Contabo bucket and downloaded again for a sha check. the local copy is only removed after that passes. the same path is used during releases and by the daily backup timer, and the old verified dumps are moved over during this release as well.
