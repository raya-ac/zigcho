# release checks do not take the server down anymore

the map-media deploy exposed a bad order in the release script. it stopped zigcho before taking the full PostgreSQL backup and doing the disposable restore, which left kai.ovh down while 1.8 GB moved around. the backup was safe. the downtime was not acceptable.

backup, restore verification, and candidate preflight now run while the current release keeps answering. zigcho is stopped only for the final symlink switch and restart. backup jobs also share one lock now, so a timed backup and a deploy cannot compress the same database at once. rollback still has the same verified dump and previous release, but a slow backup can no longer turn into a slow outage.

I brought `285bfb8` back while the map-media restore finished, then did one controlled restart into `a81ab57`. the running executable, schema 19, public health, real cover, real Ogg preview, media metrics, and warning logs all checked clean after the switch.
