# multiplayer

`../lazer_multiplayer.zig` keeps the public entry points and the manager's owned state. the implementation lives here, grouped by what it does.

- `rooms/`: joining, leaving, settings, gameplay, playlist edits and room state.
- `ranked/`: pools, queues, duels, cards, countdowns and rating settlement.
- `archive/`: checkpoints, restoration, completed rooms and late score updates.
- `scores/`: score tokens, submissions, ranking queries and score-detail output.
- `transport/`: websocket ownership, invocation dispatch and outgoing events.
- `wire/`: JSON and MessagePack parsing and serialization.
- `lifecycle.zig`: enable/disable, mutation gates, shutdown and teardown.

the existing tests sit with those domains. `model.zig`, `fixed.zig`, `paths.zig`, `scoring.zig` and `signalr.zig` keep the shared protocol pieces.

moving a function here does not move its lock boundary. keep the mutation gate, connection ownership and archive retry rules intact. a function ending in `Locked` still expects the caller to own the manager lock. database settlement and network sends must keep their existing outside-lock boundaries. internal functions are public to sibling modules; that does not make them routes or permissions.
