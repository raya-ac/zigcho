**zigcho update — registration works in the actual client**

The custom lazer client registered `zigcho_lazer_qa2` through the public API. This is the first account created by the real app instead of curl. The token request also passed, then the client immediately found the next mismatch: it asks for `/api/v2/me/`, while zigcho only matched `/api/v2/me`.

API paths now treat one trailing slash as the same route. The root page still stays `/`, and there is a regression check for both cases.

We are about 39% of the way to an invite-only alpha now. Real-client registration and token issue are proven. I still need the deployed `/me` response to deserialize, then the next authenticated startup requests, gameplay submission, rooms, realtime multiplayer and spectating, moderation, backups, and a properly signed client release.
