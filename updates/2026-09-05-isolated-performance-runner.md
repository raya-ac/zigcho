# a workload we can actually repeat

the performance runner now lives in stable-conformance. it uses 1,000 synthetic Stable players, a seeded PostgreSQL database and a local HTTPS object store. polls, chat, spectators, multiplayer score frames, real encrypted score submissions, website reads and replay downloads run together.

the hosted workflow takes an already-passed release artifact and checks its exact executable hash. it runs a cold-gameplay pass and a warm pass, keeps the latency and resource reports, and verifies acknowledged scores, replay storage and packet delivery. nothing points at production.

this is the first short baseline, not an hour-long capacity claim. lazer, Relax/AP, the public proxy path and real remote-storage latency need their own measurements.
