**zigcho update — we found the real lazer form body**

The custom client reached `/oauth/token`, but zigcho returned `invalid_request`. The field names were right. The body format was not.

The official osu! framework sends `AddParameter()` as multipart form data for POST requests. My earlier curl check used URL-encoded data, so it proved the field contract but not the client's wire format. Zigcho now accepts both formats for registration, token issue, and token revocation.

The tests use the same fixed multipart boundary as the official framework. A fresh local database also passed multipart registration, raw-password login, bearer token issue, and `/api/v2/me` as one flow.

We are still about 38% of the way to an invite-only alpha. I am not moving that number for parser work. The next check is the same account logging in through the deployed custom client and showing its username in the toolbar, then following the authenticated request failures from there.
