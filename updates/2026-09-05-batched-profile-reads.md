# stop asking the same rank question thousands of times

this candidate batches the stats used in Stable login packets. ranks are calculated once per batch instead of once for every player already online, and the login path no longer fetches profile-only grades and replay views. packet values, mode selection and rank ties stay the same.

profile first-place queries now sort the score keys they need, then load the display fields and replay information for the selected results. opponents still participate in ranking, source and pp tie rules are unchanged, and the total first-place count still comes from the full result before the page limit.

the hosted gate compares the new queries against the original results, including restrictions, ties, missing stats, mixed sources and namespaces. there is no pool-size change, new cache, scoring change or deployment in this pass. measured before/after results follow from the same isolated workload.
