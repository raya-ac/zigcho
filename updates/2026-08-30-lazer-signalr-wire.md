# the lazer signalr wire layer is separate

the SignalR and MessagePack framing now lives in `lazer_multiplayer/signalr.zig` instead of being buried inside the multiplayer manager.

the 60 KiB frame limit, five-byte prefix limit, nesting limit, handshake, completion packets and event envelopes are unchanged. the old multiplayer module still exposes the same public surface, so this does not change what the client receives.

this gets the wire format out of the way before the room lifecycle and locking code is split. those parts are staying put until their ownership can move without changing behaviour.
