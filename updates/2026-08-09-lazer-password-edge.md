**zigcho update — the live lazer check caught one password edge**

The first registration request against the deployed build used a generated 32-character password. Zigcho saw the length, assumed it was stable's MD5 credential, then rejected it because the characters were not hex.

That detector now checks the contents too. A 32-character all-hex value is stable's credential. A 32-character lazer password is still a raw password and gets normalized like every other valid lazer password. There is a regression test for the exact case that failed live.

This does not change the readiness estimate. We are still about 38% of the way to an invite-only alpha, and I am staying on the same registration, token, `/me`, and real-client login proof until the whole slice is green.
