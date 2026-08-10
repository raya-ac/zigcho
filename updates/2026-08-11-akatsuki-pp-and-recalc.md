**zigcho update — akatsuki-pp for real relax/autopilot pp, plus full recalc**

the pp calculator was wrong for relax and autopilot. vanilla rosu-pp doesn't know what those mods are, so it was calculating pp as if you played without them — which gave nonsense values for autopilot especially. akatsuki's fork handles the relax and autopilot calculations properly because that's literally what they built it for.

swapped `rosu-pp` 4.0.1 for `akatsuki-pp` (akatsuki-pp-rs on github) in the rust FFI crate. the api is almost identical but older — no `checked_calculate`, no `check_suspicion`, no `legacy_total_score` or `osu_small_tick_hits` in the score state. stripped those out. the zig side didn't change at all because the C struct boundary is the same.

pp values on relax and autopilot leaderboards now display as truncated integers. 18.81pp shows as 18, not 1881. the `writeBoardRow` function already had `@intFromFloat` for this but the deployed binary was stale.

added a `recalc` subcommand: `zigcho recalc <db>`. it walks every passed score, fetches the stored `.osu` file, recalculates pp with the new library, writes it back, then rebuilds weighted stats per user/mode/namespace. ran it against all 27 existing scores — vanilla, relax, and autopilot values all shifted to match akatsuki's formula. stats now correctly separate vanilla (mode 0), relax (mode 4), and autopilot (mode 8) weighted pp instead of lumping them together.

the pinned test fixture updated from 26.80pp/1.7931 stars to 26.90pp/1.8065 stars. same synthetic map, different formula, slightly different result.
