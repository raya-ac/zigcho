# third party notices

zigcho's original work is covered by the Zigcho Public Use License in `LICENSE`.
the public `client/lazer/zigcho-client.patch` records Zigcho-licensed changes
to the official client; the upstream client code around those changes remains
ppy copyright and MIT-licensed. everything listed below keeps its own copyright
and license. this file does not grant rights to the osu! or ppy names, game
resources, beatmaps, music, user uploads or other third-party art.

the separate `zigcho/zigcho-anticheat-private` module is not covered by the
Zigcho Public Use License. it is proprietary under the Zigcho Anticheat Access
License and may only be accessed or used by people and systems given explicit
permission by raya. repository or binary access on its own is not a licence to
use, copy, modify, distribute, deploy or share it.

## zigcho!lazer

zigcho!lazer is built by applying our patch to the official [`ppy/osu`](https://github.com/ppy/osu)
source at commit `12df2e4ff254975f4b66ae9efda808837ee9beea`.

the upstream client code is MIT-licensed:

- Copyright (c) 2025 ppy Pty Ltd <contact@ppy.sh>
- license: [MIT](https://github.com/ppy/osu/blob/12df2e4ff254975f4b66ae9efda808837ee9beea/LICENCE)

every desktop release package includes the original `ppy/osu` license beside
zigcho's license. ppy's MIT license covers the client code, not the osu!/ppy
branding or game resources.

## PP bridge

the local Rust bridge in `pp/` links these direct dependencies:

| component | pinned version | license | upstream |
| --- | --- | --- | --- |
| `rosu-pp` for Stable | `4.0.1` | MIT, Copyright (c) 2021 Max | [MaxOhn/rosu-pp](https://github.com/MaxOhn/rosu-pp) |
| `rosu-pp` for lazer parity | `5.0.0` at `1129a7e79d689fc705bf93fb2f2a6411825ba545` | MIT, Copyright (c) 2021 Max | [kaibi-dev/rosu-pp](https://github.com/kaibi-dev/rosu-pp) |
| `akatsuki-pp` | `1.1.2` at `591de0db4948f2c504ca6e2ca3db442f09103ef1` | MIT, Copyright (c) 2021 Max | [osuAkatsuki/akatsuki-pp-rs](https://github.com/osuAkatsuki/akatsuki-pp-rs) |
| `rosu-map` | `0.2.1` | MIT, Copyright (c) 2024 MaxOhn | [MaxOhn/rosu-map](https://github.com/MaxOhn/rosu-map) |
| `rosu-mods` | `0.2.1` and `0.4.1` | MIT, Copyright (c) 2024 Badewanne3 | [MaxOhn/rosu-mods](https://github.com/MaxOhn/rosu-mods) |
| `serde_json` | `1.0.149` | MIT or Apache-2.0; Zigcho uses the MIT option | [serde-rs/json](https://github.com/serde-rs/json) |

`pp/Cargo.lock` is the exact inventory for the bridge's transitive Rust
dependencies. those crates remain under the license files published with each
crate; Zigcho does not relicense them.

## protocol references

Stable protocol and achievement compatibility reference the MIT-licensed
[`osuAkatsuki/bancho.py`](https://github.com/osuAkatsuki/bancho.py) project —
Copyright (c) 2019 cmyui. bancho.py is not bundled or linked into Zigcho.

## system libraries

Zigcho links against libraries supplied by the target system:

- [SQLite](https://www.sqlite.org/copyright.html), which its authors have
  dedicated to the public domain.
- PostgreSQL `libpq`, distributed under the
  [PostgreSQL License](https://www.postgresql.org/about/licence/). Portions
  Copyright (c) 1996-2026, The PostgreSQL Global Development Group, and
  Copyright (c) 1994, The Regents of the University of California.

## assets and hosted content

achievement, flag, beatmap and profile media may be loaded from ppy-operated
hosts or supplied by players. they are not covered by the Zigcho Public Use
License.
copyright in `src/assets/avatars/default-1.gif` and
`src/assets/avatars/default-2.jpg` remains with the respective artists; their
inclusion does not place that artwork under the Zigcho Public Use License.

## MIT license text

the MIT-licensed components above are supplied under this license:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
