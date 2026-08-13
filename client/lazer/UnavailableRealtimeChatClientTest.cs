// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using NUnit.Framework;
using osu.Game.Online.Chat;

namespace osu.Game.Online.Tests
{
    [TestFixture]
    public class UnavailableRealtimeChatClientTest
    {
        [Test]
        public void TestPresenceInitialisesWithoutNetwork()
        {
            using var client = new UnavailableRealtimeChatClient();
            int received = 0;
            client.PresenceReceived += () => received++;

            client.RequestPresence();

            Assert.That(received, Is.EqualTo(1));
        }
    }
}
