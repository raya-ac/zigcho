# object storage cutover

the whole live map cache is in the private Contabo bucket now: 215 archives, 308 covers/previews and the custom avatar, all 2,179,986,414 bytes checked again after upload. nothing is public in the bucket and the normal kai hosts still own every download.

this is the second object-aware release, so `dbefa9b` can stay as a rollback that still understands those copies. that finally makes it safe for schema 30 to stop carrying another 2.18 GB inside PostgreSQL without turning rollback into a lie.
