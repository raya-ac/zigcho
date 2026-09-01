# the client and Stable harness have their own repos now

the server repo was trying to be the server, the patched lazer client, five-platform packaging and a protocol lab at the same time. it worked, but it made every part harder to find and every checkout heavier than it needed to be.

the pinned client patch and its GitHub runner builds now live in [`zigcho/zigcho-lazer`](https://github.com/zigcho/zigcho-lazer). the Stable protocol and legacy web harness now lives in [`zigcho/stable-conformance`](https://github.com/zigcho/stable-conformance). both kept their real Git history instead of starting again as empty code dumps.

the server still runs the Stable harness from its own CI through the harness repo's reusable workflow. player downloads stay on the existing server release page until the next client release is published, so this split does not break the current builds.

this is only an ownership and repository boundary. the server, client patch and conformance behaviour are unchanged.
