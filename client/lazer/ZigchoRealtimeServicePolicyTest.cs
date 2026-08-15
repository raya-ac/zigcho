// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

using NUnit.Framework;
using osu.Game.Online.API;

namespace osu.Game.Online.Tests
{
    [TestFixture]
    public class ZigchoRealtimeServicePolicyTest
    {
        private static EndpointConfiguration createEndpoints() => new EndpointConfiguration
        {
            RealtimeServicesAvailable = false,
            MultiplayerServicesAvailable = true,
            MultiplayerUrl = "https://spectator.kai.ovh/multiplayer",
            SpectatorUrl = "https://spectator.kai.ovh/spectator",
            MetadataUrl = "https://spectator.kai.ovh/metadata",
        };

        [Test]
        public void TestOnlyMultiplayerHubIsEnabled()
        {
            var endpoints = createEndpoints();
            Assert.That(ZigchoRealtimeServicePolicy.AllowsHub(endpoints, endpoints.MultiplayerUrl), Is.True);
            Assert.That(ZigchoRealtimeServicePolicy.AllowsHub(endpoints, endpoints.SpectatorUrl), Is.False);
            Assert.That(ZigchoRealtimeServicePolicy.AllowsHub(endpoints, endpoints.MetadataUrl), Is.False);
        }

        [Test]
        public void TestFullRealtimeStillEnablesEveryHub()
        {
            var endpoints = createEndpoints();
            endpoints.RealtimeServicesAvailable = true;
            Assert.That(ZigchoRealtimeServicePolicy.AllowsHub(endpoints, endpoints.SpectatorUrl), Is.True);
        }
    }
}
