// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using osu.Game.Beatmaps;

namespace osu.Game.Online.Leaderboards
{
    public static class ZigchoLeaderboardAvailability
    {
        public static bool IsAvailable(IBeatmapInfo? beatmap) => beatmap?.OnlineID > 0;
    }
}
