# stable account creation was registering too early

stable does not create an account with one request. it sends the form with `check=1` first, then sends it again with `check=0` after validation passes.

zigcho ignored that field. the first request created the account, so the real create request came back with `409 conflict`. that is why the screen looked like registration failed even though a row had already appeared in the database.

the two stages are separate now. checking the form does not write anything. creating it returns the plain `ok` response stable expects, and bad fields come back in its `form_error` shape so the screen can put the error in the right place. lazer's one-request registration still returns its existing `201` JSON.

the real HTTP sequence passes against a fresh database: check leaves zero users, create leaves one, the new password logs in, duplicate checks show the username and email errors, and lazer registration still works beside it.
