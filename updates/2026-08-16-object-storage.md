# object storage

beatmap archives, covers, previews and custom avatars can live in the new private S3 bucket now. new files are written there immediately and normal reads prefer the object copy, but PostgreSQL still keeps the full old copy for this release. that means the current rollback is still real instead of us saving space by making the last working build unable to read its own maps.

the migration is resumable and verifies every upload by downloading it again before counting it as moved. it also keeps the old Cloudflare avatar copy for now. nothing gets deleted from PostgreSQL or the old avatar bucket in this phase; shrinking the database comes after this build has spent time live and become the rollback target itself.
