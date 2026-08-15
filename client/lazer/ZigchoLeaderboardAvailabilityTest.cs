// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using NUnit.Framework;
using osu.Game.Beatmaps;

namespace osu.Game.Online.Leaderboards.Tests
{
    [TestFixture]
    public class ZigchoLeaderboardAvailabilityTest
    {
        [TestCase(75, BeatmapOnlineStatus.None, true)]
        [TestCase(75, BeatmapOnlineStatus.Pending, true)]
        [TestCase(75, BeatmapOnlineStatus.Ranked, true)]
        [TestCase(-1, BeatmapOnlineStatus.Ranked, false)]
        [TestCase(0, BeatmapOnlineStatus.Loved, false)]
        public void TestOnlineIdOwnsAvailability(int onlineId, BeatmapOnlineStatus status, bool expected)
        {
            var beatmap = new BeatmapInfo
            {
                OnlineID = onlineId,
                Status = status,
            };

            Assert.That(ZigchoLeaderboardAvailability.IsAvailable(beatmap), Is.EqualTo(expected));
        }

        [Test]
        public void TestNullBeatmapIsUnavailable()
        {
            Assert.That(ZigchoLeaderboardAvailability.IsAvailable(null), Is.False);
        }
    }
}
