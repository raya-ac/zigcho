// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the official osu! source tree for full licence text.

namespace osu.Game.Online
{
    public class DevelopmentEndpointConfiguration : EndpointConfiguration
    {
        public DevelopmentEndpointConfiguration()
        {
            RealtimeServicesAvailable = false;
            WebsiteUrl = @"https://kai.ovh";
            APIUrl = @"http://127.0.0.1:18095";
            APIClientSecret = @"zigcho-lazer";
            APIClientID = "5";
            SpectatorUrl = @"https://spectator.kai.ovh/spectator";
            MultiplayerUrl = @"https://spectator.kai.ovh/multiplayer";
            MetadataUrl = @"https://spectator.kai.ovh/metadata";
            BeatmapSubmissionServiceUrl = @"https://bss.kai.ovh";
        }
    }
}
